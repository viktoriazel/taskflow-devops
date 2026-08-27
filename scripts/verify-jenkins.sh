#!/usr/bin/env bash
#
# verify-jenkins.sh - check that the running Jenkins matches this repository.
#
# Read-only: every check is a query, and nothing is created or changed. Exits
# non-zero if any check fails, so it can gate a pipeline or a manual install.
#
# No secret value is ever printed. Secrets are checked only for the presence of
# their required keys.
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

# kubectl query for an object that may legitimately be absent; the caller
# decides what an empty result means.
#
# Never use it for a check that passes on empty output: kq drops the exit
# status, so a query that could not run would look like a clean result.
kq() { kubectl "$@" 2>/dev/null || true; }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

step "Preflight"

require_commands kubectl helm
load_chart_env
require_repo_files "$VALUES_FILE"
require_expected_cluster

# Read from the repository, so this script cannot drift from what is installed.
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

    # No image in the Pod may use a mutable tag. Not kq: a failed query must be
    # reported, not read as "no ':latest' found".
    if ! pod_images="$(kubectl get pod "$POD" -n "$JENKINS_NAMESPACE" -o jsonpath='{..image}' 2>/dev/null)"; then
        bad "could not read the container images of Pod '${POD}' - ':latest' was not verified"
    elif [[ "$pod_images" == *:latest* ]]; then
        bad "a container image in the controller Pod uses the 'latest' tag"
    else
        ok "no ':latest' image in the controller Pod"
    fi

    # The Pod must run on the dedicated Jenkins node.
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
# ClusterIP on purpose: the UI is reached with port-forward, not published.
# A LoadBalancer or NodePort here would mean the boundary moved.
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

# The controller must have no cluster-scoped permissions. The template checks
# every subject and matches on kind, namespace and name, so a same-named User,
# Group or account from another namespace is not mistaken for it. Not kq: a
# failed listing must fail the check.
#
# Single-quoted so $name stays in the Go template.
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
# Keys only, never values. Run in a subshell so a missing Secret fails the check
# instead of ending the script.
# --------------------------------------------------------------------------

step "Admin credentials"

if ( require_admin_secret "$JENKINS_NAMESPACE" ); then
    ok "Secret '${ADMIN_SECRET_NAME}' present with both required keys"
else
    bad "Secret '${ADMIN_SECRET_NAME}' is missing or incomplete"
fi

# --------------------------------------------------------------------------
# Plugin pinning and load state
#
# The pinned list is read from the ConfigMap the chart rendered, so it is what
# the controller was told to install. The checks after it confirm the controller
# is really running that set.
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

# A plugin can be on the volume and still not be loaded: Jenkins skips one with
# unmet dependencies and keeps serving, so the feature is gone while everything
# else looks fine. The three checks below catch that.

installed_plugins="$(kq exec "$POD" -n "$JENKINS_NAMESPACE" -c jenkins -- \
    sh -c 'ls /var/jenkins_home/plugins/*.jpi 2>/dev/null | sed "s|.*/||; s|[.]jpi$||"')"

if [[ -z "$installed_plugins" ]]; then
    bad "could not list the plugins installed on '${POD}'"
else
    missing=()
    while read -r line; do
        [[ -n "$line" ]] || continue
        grep -qxF "${line%%:*}" <<< "$installed_plugins" || missing+=("${line%%:*}")
    done <<< "$plugins"

    if (( ${#missing[@]} == 0 )); then
        ok "every pinned plugin is installed on the controller"
    else
        bad "pinned but not installed: ${missing[*]}"
    fi

    # Listed by name because most of these arrive as dependencies, and a job
    # that misses the suite finishes green without running a single stage.
    missing=()
    for plugin in workflow-aggregator pipeline-model-definition \
                  pipeline-model-extensions pipeline-model-api \
                  workflow-job pipeline-stage-step; do
        grep -qxF "$plugin" <<< "$installed_plugins" || missing+=("$plugin")
    done

    if (( ${#missing[@]} == 0 )); then
        ok "Pipeline suite installed"
    else
        bad "Pipeline plugins not installed: ${missing[*]}"
    fi
fi

# Jenkins logs one line per plugin it could not load. Any match means the
# installed set is inconsistent, whichever files are present.
if ! controller_logs="$(kubectl logs "$POD" -n "$JENKINS_NAMESPACE" -c jenkins 2>/dev/null)"; then
    bad "could not read the controller logs - plugin load failures were not verified"
else
    failed_plugins="$(sed -n 's/.*Failed Loading plugin .*(\([A-Za-z0-9_.-]*\)).*/\1/p' <<< "$controller_logs" | sort -u)"

    if [[ -z "$failed_plugins" ]]; then
        ok "no plugin failed to load on the running controller"
    else
        bad "plugins failed to load: $(tr '\n' ' ' <<< "$failed_plugins")"
    fi
fi

# --------------------------------------------------------------------------
# Agent identities
# --------------------------------------------------------------------------

step "Agent identities"

expect_eq "ServiceAccount jenkins-ci-agent automountServiceAccountToken" "false" \
    "$(kq get serviceaccount jenkins-ci-agent -n "$JENKINS_NAMESPACE" -o jsonpath='{.automountServiceAccountToken}')"
# Neither agent gets an API token by default. CD still reaches the API: its Pod
# template mounts the token into the kubectl container explicitly.
expect_eq "ServiceAccount jenkins-cd-agent automountServiceAccountToken" "false" \
    "$(kq get serviceaccount jenkins-cd-agent -n "$JENKINS_NAMESPACE" -o jsonpath='{.automountServiceAccountToken}')"

# Lists the bindings that grant something to an agent ServiceAccount. The
# template matches on kind, namespace and name, so an unrelated field that only
# contains the name cannot match.
#
# Single-quoted so the $ variables stay in the Go template.
# shellcheck disable=SC2016
binding_subjects_template() {
    printf '%s' '{{range .items}}{{$name := .metadata.name}}{{$ns := .metadata.namespace}}{{range .subjects}}{{if eq .kind "ServiceAccount"}}{{if eq .namespace "'"$JENKINS_NAMESPACE"'"}}{{if eq .name "'"$1"'"}}{{$ns}}/{{$name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}{{end}}'
}

# Fails if any binding of this kind grants something to the ServiceAccount.
# Not kq: a query that could not run must fail the check.
assert_no_binding() {
    local sa="$1" kind="$2" found
    if ! found="$(kubectl get "$kind" --all-namespaces \
            -o go-template="$(binding_subjects_template "$sa")" 2>/dev/null)"; then
        bad "could not list ${kind}s - grants to ${sa} were not verified"
    elif [[ -n "$found" ]]; then
        bad "${kind}(s) grant permissions to ${sa}: ${found}"
    else
        ok "no ${kind} grants anything to ${sa}"
    fi
}

# The CI agent must have no Kubernetes permissions at all, of either kind.
for kind in rolebinding clusterrolebinding; do
    assert_no_binding jenkins-ci-agent "$kind"
done

# --------------------------------------------------------------------------
# CD permissions
#
# The Role and its RoleBinding are read from the cluster, not the repository,
# so this reports what is actually in force.
# --------------------------------------------------------------------------

step "CD agent permissions"

if cd_rules="$(kubectl get role jenkins-cd-agent-release -n "$APP_NAMESPACE" -o json 2>/dev/null)"; then
    ok "Role exists: jenkins-cd-agent-release in ${APP_NAMESPACE}"

    for forbidden in secrets '"\*"'; do
        if printf '%s' "$cd_rules" | grep -q "$forbidden"; then
            bad "CD Role references a forbidden resource or wildcard: ${forbidden}"
        else
            ok "CD Role contains no ${forbidden}"
        fi
    done

    for verb in create update delete deletecollection; do
        if printf '%s' "$cd_rules" | grep -q "\"${verb}\""; then
            bad "CD Role grants '${verb}'"
        else
            ok "CD Role does not grant '${verb}'"
        fi
    done

    # Checks the write surface itself, not a list of verbs that must be absent.
    # Every rule granting more than get/list/watch is collected: exactly one is
    # expected, the patch on the three named Deployments. Names and verbs are
    # sorted, so the order they were written in does not matter.
    # shellcheck disable=SC2016
    rule_tpl='{{range .rules}}{{range $i, $g := .apiGroups}}{{if $i}},{{end}}{{if eq $g ""}}core{{else}}{{$g}}{{end}}{{end}};{{range $i, $r := .resources}}{{if $i}},{{end}}{{$r}}{{end}};{{range $i, $n := .resourceNames}}{{if $i}},{{end}}{{$n}}{{end}};{{range $i, $v := .verbs}}{{if $i}},{{end}}{{$v}}{{end}}{{"\n"}}{{end}}'

    sorted_csv() {
        local joined
        joined="$(tr ',' '\n' <<< "$1" | sort | tr '\n' ',')"
        printf '%s' "${joined%,}"
    }

    if ! cd_rule_lines="$(kubectl get role jenkins-cd-agent-release -n "$APP_NAMESPACE" \
            -o go-template="$rule_tpl" 2>/dev/null)"; then
        bad "could not read the rules of the CD Role - its write surface was not verified"
    else
        write_rules=()
        while IFS=';' read -r groups resources names verbs; do
            [[ -n "$verbs" ]] || continue
            IFS=',' read -ra rule_verbs <<< "$verbs"
            for verb in "${rule_verbs[@]}"; do
                case "$verb" in
                    get|list|watch) ;;
                    *) write_rules+=("${groups};${resources};$(sorted_csv "$names");$(sorted_csv "$verbs")")
                       break ;;
                esac
            done
        done <<< "$cd_rule_lines"

        if (( ${#write_rules[@]} == 1 )); then
            expect_eq "CD Role write surface" \
                "apps;deployments;backend,frontend,worker;get,patch" "${write_rules[0]}"
        else
            bad "CD Role has ${#write_rules[@]} rules granting a write verb, expected exactly 1: ${write_rules[*]}"
        fi
    fi
else
    bad "Role 'jenkins-cd-agent-release' not found in namespace '${APP_NAMESPACE}'"
fi

# The Role matters only if it is bound to the CD identity and nothing else, so
# the roleRef and the full subject list are read back too.
if ! cd_binding="$(kubectl get rolebinding jenkins-cd-agent-release -n "$APP_NAMESPACE" \
        -o go-template='{{.roleRef.kind}}/{{.roleRef.name}}{{"\n"}}{{range .subjects}}{{.kind}}/{{.namespace}}/{{.name}}{{"\n"}}{{end}}' 2>/dev/null)"; then
    bad "RoleBinding 'jenkins-cd-agent-release' in '${APP_NAMESPACE}' is missing or could not be read"
else
    ok "RoleBinding exists: jenkins-cd-agent-release in ${APP_NAMESPACE}"
    expect_eq "CD RoleBinding roleRef" "Role/jenkins-cd-agent-release" \
        "$(head -n 1 <<< "$cd_binding")"
    # Compared as a whole list, so an extra subject fails the check.
    expect_eq "CD RoleBinding subjects" \
        "ServiceAccount/${JENKINS_NAMESPACE}/jenkins-cd-agent" \
        "$(tail -n +2 <<< "$cd_binding" | grep -v '^$' || true)"
fi

assert_no_binding jenkins-cd-agent clusterrolebinding

# --------------------------------------------------------------------------
# Configuration as Code
#
# Read from the ConfigMaps the chart rendered, so this is the configuration the
# controller was actually given.
# --------------------------------------------------------------------------

step "JCasC"

casc="$(kq get configmap -n "$JENKINS_NAMESPACE" \
    -l "${JENKINS_RELEASE_NAME}-jenkins-config=true" -o jsonpath='{range .items[*]}{.data}{end}')"

if [[ -z "$casc" ]]; then
    bad "no JCasC ConfigMap found in namespace '${JENKINS_NAMESPACE}'"
else
    ok "JCasC ConfigMaps present"

    # numExecutors: 0 is what keeps build work off the controller.
    if printf '%s' "$casc" | grep -q 'numExecutors: 0'; then
        ok "controller numExecutors: 0"
    else
        bad "controller numExecutors is not 0 - builds could run on the controller"
    fi

    for needed in 'securityRealm' 'authorizationStrategy' 'kubernetes:' 'taskflow-ci' 'taskflow-cd'; do
        if printf '%s' "$casc" | grep -q "$needed"; then
            ok "JCasC defines ${needed}"
        else
            bad "JCasC does not define ${needed}"
        fi
    done

    # Agent images must be pinned by digest: a tag can be repointed, a digest
    # cannot.
    if printf '%s' "$casc" | grep -q ':latest'; then
        bad "an agent image in JCasC uses the 'latest' tag"
    else
        ok "no ':latest' image in the agent templates"
    fi

    tagged="$(printf '%s' "$casc" | grep -oE 'image: [^ ]+' | grep -cv '@sha256:' || true)"
    if (( tagged == 0 )); then
        ok "every agent image is pinned by digest"
    else
        bad "${tagged} agent image reference(s) are not pinned by digest"
    fi
fi

# --------------------------------------------------------------------------
# Webhook authentication
#
# The webhook endpoint is the only part of Jenkins reachable from the internet,
# and the shared secret is what authenticates a delivery. Everything below is
# read back from the running controller.
#
# No secret value is read: only the key of the Secret, the id of the credential
# and the id the plugin points at.
# --------------------------------------------------------------------------

step "Webhook authentication"

if ( require_webhook_secret "$JENKINS_NAMESPACE" ); then
    ok "Secret '${WEBHOOK_SECRET_NAME}' present with its required key"
else
    bad "Secret '${WEBHOOK_SECRET_NAME}' is missing or incomplete"
fi

# Not kq: a file that cannot be read must fail its check. For the CD check
# below, an absence would otherwise look like a pass.
read_controller_file() {
    kubectl exec "$POD" -n "$JENKINS_NAMESPACE" -c jenkins -- cat "$1" 2>/dev/null
}

if [[ -n "$POD" ]]; then
    if creds="$(read_controller_file /var/jenkins_home/credentials.xml)"; then
        if grep -qF '<id>github-webhook-secret</id>' <<< "$creds"; then
            ok "credential exists: github-webhook-secret"
        else
            bad "no credential with id 'github-webhook-secret' in the credentials store"
        fi

        if grep -qF 'StringCredentialsImpl' <<< "$creds"; then
            ok "credential type: String Credential"
        else
            bad "the webhook credential is not a String Credential"
        fi
    else
        bad "could not read the credentials store - the webhook credential was not verified"
    fi

    if ghconf="$(read_controller_file /var/jenkins_home/github-plugin-configuration.xml)"; then
        if grep -qF '<credentialsId>github-webhook-secret</credentialsId>' <<< "$ghconf"; then
            ok "GitHub plugin hook secret: github-webhook-secret"
        else
            bad "the GitHub plugin does not reference credential 'github-webhook-secret'"
        fi

        if grep -qF '<signatureAlgorithm>SHA256</signatureAlgorithm>' <<< "$ghconf"; then
            ok "webhook signature algorithm: SHA256"
        else
            bad "the GitHub plugin is not set to validate SHA256 signatures"
        fi

        # An empty server list is what keeps this installation free of a GitHub
        # API token.
        if grep -qF '<configs/>' <<< "$ghconf"; then
            ok "no GitHub server configuration, so no API token is required"
        else
            bad "the GitHub plugin carries a server configuration this repository does not define"
        fi
    else
        bad "could not read the GitHub plugin configuration - the hook secret was not verified"
    fi

    # A push must start CI and only CI. Deployment is a separate job, started
    # on purpose from an image CI has already published.
    if ci_job="$(read_controller_file /var/jenkins_home/jobs/ci-application/config.xml)"; then
        if grep -qF 'GitHubPushTrigger' <<< "$ci_job"; then
            ok "ci-application has a GitHub push trigger"
        else
            bad "ci-application has no GitHub push trigger - a push would build nothing"
        fi
    else
        bad "could not read the ci-application job configuration"
    fi

    if cd_job="$(read_controller_file /var/jenkins_home/jobs/application-cd/config.xml)"; then
        if grep -qF 'GitHubPushTrigger' <<< "$cd_job"; then
            bad "application-cd has a GitHub push trigger - a push would deploy directly"
        else
            ok "application-cd has no GitHub push trigger"
        fi
    else
        bad "could not read the application-cd job configuration - its trigger was not verified"
    fi
else
    bad "no controller Pod - webhook authentication was not verified"
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
