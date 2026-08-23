#!/usr/bin/env bash
#
# verify-jenkins.sh - check that the running Jenkins matches this repository.
#
# Read-only. Every check is a kubectl or helm query; nothing is created,
# changed or deleted. Exits non-zero if any check fails, so it can gate a
# pipeline or a manual install.
#
# No credential value is ever printed or exposed. The admin Secret is checked
# for the presence and non-emptiness of its required keys only.
#
# Dependencies: kubectl, helm.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/jenkins-common.sh
source "${SCRIPT_DIR}/jenkins-common.sh"

SHOW_EVIDENCE=false

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--evidence] [-h|--help]

Verifies the Jenkins installation: release, controller, storage, scheduling,
identity, permissions and hardening. Read-only.

Options:
  --evidence  Also print the standard inventory of the namespace
              (namespaces, pods, services/pvc, identity, helm list).
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to query.
                         Default: taskflow-dev-eks

Exit codes: 0 all checks passed, 1 at least one check failed, 2 usage.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --evidence) SHOW_EVIDENCE=true ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; printf '\nUnknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

FAILURES=0
ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }

expect_eq() {
    local what="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "${what}: ${actual}"
    else
        bad "${what}: expected '${expected}', got '${actual}'"
    fi
}

# kubectl query for an object that may legitimately be absent: the empty result
# is what the caller then reports as a failure or an absence.
#
# Never use it for a security assertion whose success condition is empty output.
# It discards the exit status, so a query that could not run at all would be
# indistinguishable from a clean result.
kq() { kubectl "$@" 2>/dev/null || true; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

step "Preflight"

require_commands kubectl helm
load_chart_env
require_repo_files "$VALUES_FILE"
require_expected_cluster

# The expected controller image is read from the repository rather than
# hardcoded here, so this script cannot drift away from what we install.
IMAGE_REGISTRY="$(awk '/^  image:/{f=1} f && /^    registry:/{print $2; exit}'   "$VALUES_FILE")"
IMAGE_REPOSITORY="$(awk '/^  image:/{f=1} f && /^    repository:/{print $2; exit}' "$VALUES_FILE")"
IMAGE_TAG="$(awk '/^  image:/{f=1} f && /^    tag:/{gsub(/"/, "", $2); print $2; exit}' "$VALUES_FILE")"

[[ -n "$IMAGE_REGISTRY" && -n "$IMAGE_REPOSITORY" && -n "$IMAGE_TAG" ]] \
    || fail "could not read the pinned controller image from ${VALUES_FILE}."

EXPECTED_IMAGE="${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}:${IMAGE_TAG}"
info "expected controller image: ${EXPECTED_IMAGE}"

# --------------------------------------------------------------------------
# Namespace and release
# --------------------------------------------------------------------------

step "Namespace and Helm release"

if [[ -n "$(kq get namespace "$JENKINS_NAMESPACE" -o name)" ]]; then
    ok "namespace exists: ${JENKINS_NAMESPACE}"
else
    bad "namespace '${JENKINS_NAMESPACE}' not found"
fi

if release_exists; then
    ok "Helm release exists: ${JENKINS_RELEASE_NAME}"
    # 'helm list' reports the chart as <name>-<version>.
    actual_chart="$(helm list -n "$JENKINS_NAMESPACE" --filter "^${JENKINS_RELEASE_NAME}\$" \
        -o json | sed -n 's/.*"chart":"\([^"]*\)".*/\1/p')"
    expect_eq "chart version" "${JENKINS_CHART_NAME}-${JENKINS_CHART_VERSION}" "$actual_chart"
else
    bad "no Helm release '${JENKINS_RELEASE_NAME}' in namespace '${JENKINS_NAMESPACE}'"
fi

# --------------------------------------------------------------------------
# Controller workload
# --------------------------------------------------------------------------

step "Controller"

STS="$(kq get statefulset "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o name)"
if [[ -n "$STS" ]]; then
    ok "StatefulSet exists: ${JENKINS_RELEASE_NAME}"
    ready="$(kq get statefulset "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.status.readyReplicas}')"
    expect_eq "ready replicas" "1" "${ready:-0}"
else
    bad "StatefulSet '${JENKINS_RELEASE_NAME}' not found"
fi

POD="$(kq get pods -n "$JENKINS_NAMESPACE" \
    -l "app.kubernetes.io/component=jenkins-controller" \
    -o jsonpath='{.items[0].metadata.name}')"

if [[ -n "$POD" ]]; then
    ok "controller Pod: ${POD}"

    phase="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath='{.status.phase}')"
    expect_eq "Pod phase" "Running" "$phase"

    pod_ready="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
    expect_eq "Pod Ready condition" "True" "$pod_ready"

    actual_image="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" \
        -o jsonpath='{.spec.containers[?(@.name=="jenkins")].image}')"
    expect_eq "controller image" "$EXPECTED_IMAGE" "$actual_image"

    # No image anywhere in the Pod may float on a mutable tag. Queried without kq
    # so that a query that fails is reported as such, not as an absent ':latest'.
    if ! pod_images="$(kubectl get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath='{..image}' 2>/dev/null)"; then
        bad "could not read the container images of Pod '${POD}' - ':latest' was not verified"
    elif [[ "$pod_images" == *:latest* ]]; then
        bad "a container image in the controller Pod uses the 'latest' tag"
    else
        ok "no ':latest' image in the controller Pod"
    fi

    # Scheduling: the Pod must sit on the dedicated Jenkins node group.
    node="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.nodeName}')"
    if [[ -n "$node" ]]; then
        node_workload="$(kq get node "$node" -o jsonpath='{.metadata.labels.workload}')"
        expect_eq "node '${node}' label workload" "jenkins" "$node_workload"
    else
        bad "controller Pod is not scheduled to a node"
    fi

    # Hardening and limits, as configured in jenkins/values.yaml.
    ctr='{.spec.containers[?(@.name=="jenkins")]'
    expect_eq "runAsNonRoot"           "true"  "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.securityContext.runAsNonRoot}")"
    expect_eq "allowPrivilegeEscalation" "false" "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.securityContext.allowPrivilegeEscalation}")"
    expect_eq "readOnlyRootFilesystem" "true"  "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.securityContext.readOnlyRootFilesystem}")"
    expect_eq "dropped capabilities"   "ALL"   "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.securityContext.capabilities.drop[0]}")"
    expect_eq "seccomp profile"        "RuntimeDefault" "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.securityContext.seccompProfile.type}")"

    for field in requests.cpu requests.memory limits.cpu limits.memory; do
        value="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.resources.${field}}")"
        if [[ -n "$value" ]]; then ok "resources.${field}: ${value}"; else bad "resources.${field} is not set"; fi
    done

    for probe in startupProbe livenessProbe readinessProbe; do
        path="$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath="${ctr}.${probe}.httpGet.path}")"
        if [[ -n "$path" ]]; then ok "${probe}: ${path}"; else bad "${probe} is not configured"; fi
    done
else
    bad "no controller Pod found in namespace '${JENKINS_NAMESPACE}'"
fi

# --------------------------------------------------------------------------
# Storage
# --------------------------------------------------------------------------

step "Storage"

PVC="$(kq get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o name)"
if [[ -n "$PVC" ]]; then
    ok "PVC exists: ${JENKINS_RELEASE_NAME}"
    expect_eq "PVC phase" "Bound" "$(kq get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.status.phase}')"
    expect_eq "storageClassName" "taskflow-gp3" "$(kq get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.storageClassName}')"
    expect_eq "requested storage" "20Gi" "$(kq get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}')"
    expect_eq "access mode" "ReadWriteOnce" "$(kq get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.accessModes[0]}')"
else
    bad "PVC '${JENKINS_RELEASE_NAME}' not found"
fi

# --------------------------------------------------------------------------
# Service
#
# ClusterIP is the intended exposure: the UI is reached with port-forward, not
# published. A LoadBalancer or NodePort here would mean the boundary moved.
# --------------------------------------------------------------------------

step "Service"

SVC_TYPE="$(kq get service "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.type}')"
if [[ -n "$SVC_TYPE" ]]; then
    expect_eq "Service type" "ClusterIP" "$SVC_TYPE"
else
    bad "Service '${JENKINS_RELEASE_NAME}' not found"
fi

# --------------------------------------------------------------------------
# Identity and permissions
# --------------------------------------------------------------------------

step "Identity and permissions"

if [[ -n "$(kq get serviceaccount jenkins-controller -n "$JENKINS_NAMESPACE" -o name)" ]]; then
    ok "ServiceAccount exists: jenkins-controller"
else
    bad "ServiceAccount 'jenkins-controller' not found"
fi

if [[ -n "$POD" ]]; then
    expect_eq "Pod ServiceAccount" "jenkins-controller" \
        "$(kq get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.serviceAccountName}')"
fi

for role in jenkins-controller-schedule-agents jenkins-controller-casc-reload; do
    if [[ -n "$(kq get role "$role" -n "$JENKINS_NAMESPACE" -o name)" ]]; then
        ok "Role exists: ${role}"
    else
        bad "Role '${role}' not found"
    fi
    if [[ -n "$(kq get rolebinding "$role" -n "$JENKINS_NAMESPACE" -o name)" ]]; then
        ok "RoleBinding exists: ${role}"
    else
        bad "RoleBinding '${role}' not found"
    fi
done

# The controller must hold no cluster-scoped rights. Anything binding this
# ServiceAccount at cluster level is a boundary violation, whoever created it.
#
# Every subject of every binding is examined and matched on kind, namespace and
# name, so a match is not missed because it is not the first subject and a
# same-named User, Group or foreign-namespace account is not mistaken for one.
# Run without kq: failing to list the bindings is a failed check, never a clean
# result.
#
# Single-quoted: $name belongs to the Go template, not to the shell.
# shellcheck disable=SC2016
crb_template='{{range .items}}{{$name := .metadata.name}}{{range .subjects}}{{if eq .kind "ServiceAccount"}}{{if eq .namespace "jenkins"}}{{if eq .name "jenkins-controller"}}{{$name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}'

if ! cluster_bindings="$(kubectl get clusterrolebinding -o go-template="$crb_template" 2>/dev/null)"; then
    bad "could not list ClusterRoleBindings - cluster-scoped grants to jenkins-controller were not verified"
elif [[ -n "$cluster_bindings" ]]; then
    bad "ClusterRoleBinding(s) bind jenkins-controller: ${cluster_bindings}"
else
    ok "no ClusterRoleBinding grants anything to jenkins-controller"
fi

# --------------------------------------------------------------------------
# Admin credentials
#
# Presence and non-emptiness only. Run in a subshell so a missing Secret is
# recorded as a failed check instead of ending the script.
# --------------------------------------------------------------------------

step "Admin credentials"

if ( require_admin_secret "$JENKINS_NAMESPACE" ); then
    ok "Secret '${ADMIN_SECRET_NAME}' present with both required keys"
else
    bad "Secret '${ADMIN_SECRET_NAME}' is missing or incomplete"
fi

# --------------------------------------------------------------------------
# Plugin pinning
#
# Read from the ConfigMap the chart renders, so this reflects what the
# controller was actually told to install.
# --------------------------------------------------------------------------

step "Plugins"

plugins="$(kq get configmap "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.data.plugins\.txt}')"
if [[ -n "$plugins" ]]; then
    total=0 unpinned=0
    while read -r line; do
        [[ -n "$line" ]] || continue
        total=$(( total + 1 ))
        [[ "$line" == *:* && "$line" != *:latest ]] || unpinned=$(( unpinned + 1 ))
    done <<< "$plugins"
    if (( unpinned == 0 )); then
        ok "all ${total} plugins carry an explicit version"
    else
        bad "${unpinned} of ${total} plugin entries are unpinned or use 'latest'"
    fi
else
    bad "plugin list not found in ConfigMap '${JENKINS_RELEASE_NAME}'"
fi

# --------------------------------------------------------------------------
# Optional inventory
# --------------------------------------------------------------------------

if [[ "$SHOW_EVIDENCE" == true ]]; then
    step "Namespaces"
    kubectl get namespace
    step "Pods"
    kubectl get pods -n "$JENKINS_NAMESPACE" -o wide
    step "Service, Ingress, PVC"
    kubectl get service,ingress,pvc -n "$JENKINS_NAMESPACE"
    step "ServiceAccount, Role, RoleBinding"
    kubectl get serviceaccount,role,rolebinding -n "$JENKINS_NAMESPACE"
    step "Helm releases"
    helm list -n "$JENKINS_NAMESPACE"
fi

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed.\n' "$FAILURES" >&2
    exit 1
fi

printf '\nAll checks passed.\n'
