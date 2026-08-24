#!/usr/bin/env bash
#
# install-jenkins.sh - install Jenkins into the cluster from this repository.
#
# Creates the namespace, the controller's RBAC and the agent identities and
# permissions, checks that the externally managed admin Secret is in place,
# verifies the pinned chart archive, and creates the Helm release from it.
#
# Safe to re-run: it is idempotent with respect to the Kubernetes and Helm
# resources it manages.
#
# Dependencies: kubectl, helm, sha256sum.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/jenkins-common.sh
source "${SCRIPT_DIR}/jenkins-common.sh"

DRY_RUN=false
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--dry-run] [-h|--help]

Installs Jenkins from the configuration in jenkins/: the namespace, the
controller ServiceAccount and RBAC, the CI and CD agent ServiceAccounts with
the CD agent's namespaced permissions, and the Helm release built from the
chart version pinned in jenkins/chart.env.

Options:
  --dry-run   Run every check and render the release without changing the
              cluster. Manifests are validated client-side and Helm runs with
              --dry-run, so nothing is created or updated.
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  HELM_TIMEOUT           How long to wait for the controller. Default: 10m

Exit codes: 0 ok, 1 error, 2 usage.

Prerequisites, neither of which this script creates:
  - The Secret holding the Jenkins admin credentials must already exist in the
    Jenkins namespace. It is never stored in Git; create it from
    jenkins/examples/secret-jenkins-admin.example.yaml.
  - The application namespace devops-app must already exist: the CD agent's
    Role and RoleBinding are created in it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; printf '\nUnknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

step "Preflight"

require_commands kubectl helm sha256sum
load_chart_env
require_repo_files "$VALUES_FILE" "$NAMESPACE_MANIFEST" "$RBAC_MANIFEST" "${AGENT_RBAC_MANIFESTS[@]}"
jcasc_set_file_args

info "repo root: ${REPO_ROOT}"
info "release:   ${JENKINS_RELEASE_NAME} (namespace ${JENKINS_NAMESPACE})"
[[ "$DRY_RUN" == true ]] && info "mode:      dry run - the cluster will not be changed"

require_expected_cluster

# --------------------------------------------------------------------------
# Namespace
#
# Managed from its manifest so its labels and lifecycle stay explicit and
# independent of Helm.
# --------------------------------------------------------------------------

step "Namespace"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$NAMESPACE_MANIFEST"
else
    kubectl apply -f "$NAMESPACE_MANIFEST"
    kubectl get namespace "$JENKINS_NAMESPACE" -o name >/dev/null \
        || fail "namespace '${JENKINS_NAMESPACE}' does not exist after applying ${NAMESPACE_MANIFEST}."
    info "namespace ready: ${JENKINS_NAMESPACE}"
fi

# --------------------------------------------------------------------------
# Admin credentials
#
# The externally managed Secret is validated before the release is installed.
# --------------------------------------------------------------------------

step "Admin credentials"

require_admin_secret "$JENKINS_NAMESPACE"

# --------------------------------------------------------------------------
# Controller RBAC
#
# Custom RBAC is applied here because chart-generated RBAC is disabled in
# values.yaml (rbac.create: false).
# --------------------------------------------------------------------------

step "Controller RBAC"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$RBAC_MANIFEST"
else
    kubectl apply -f "$RBAC_MANIFEST"
fi

# --------------------------------------------------------------------------
# Agent identities and permissions
#
# The agent ServiceAccounts must exist before a Pod template can reference one.
# The CD Role is created in the application namespace, so that namespace is a
# prerequisite rather than something this script creates.
# --------------------------------------------------------------------------

step "Agent RBAC"

require_app_namespace

for manifest in "${AGENT_RBAC_MANIFESTS[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
        kubectl apply --dry-run=client -f "$manifest"
    else
        kubectl apply -f "$manifest"
    fi
done

# --------------------------------------------------------------------------
# Chart artifact
# --------------------------------------------------------------------------

step "Pinned chart"

pull_and_verify_chart

# --------------------------------------------------------------------------
# Release
#
# --wait so the script's exit status reflects whether Jenkins actually came up.
#
# Deliberately not --atomic: on a failed first install its automatic rollback
# uninstalls the release, taking the freshly created PVC and its EBS-backed data
# with it (taskflow-gp3 reclaims on delete). A failed install is left in place
# to be inspected; removing it is an explicit call to uninstall-jenkins.sh.
# --------------------------------------------------------------------------

step "Helm release"

helm_args=(
    upgrade --install "$JENKINS_RELEASE_NAME" "$JENKINS_CHART_TGZ"
    --namespace "$JENKINS_NAMESPACE"
    --values "$VALUES_FILE"
    "${JCASC_SET_FILE_ARGS[@]}"
    --wait
    --timeout "$HELM_TIMEOUT"
)

if [[ "$DRY_RUN" == true ]]; then
    helm "${helm_args[@]}" --dry-run >/dev/null
    info "release renders cleanly; nothing was applied"
    step "Dry run complete"
    exit 0
fi

helm "${helm_args[@]}"

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

step "Installed"

helm list -n "$JENKINS_NAMESPACE"
kubectl get pods -n "$JENKINS_NAMESPACE" -o wide

cat <<EOF

Next steps:
  - Check the installation:  ${SCRIPT_DIR}/verify-jenkins.sh
  - Open the UI:             kubectl port-forward -n ${JENKINS_NAMESPACE} svc/${JENKINS_RELEASE_NAME} 8080:8080
                             then browse to http://localhost:8080
    The UI is not published outside the cluster by design.
EOF
