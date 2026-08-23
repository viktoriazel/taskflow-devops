#!/usr/bin/env bash
#
# configure-jenkins.sh - reconcile a running Jenkins with this repository.
#
# The division of labour against install-jenkins.sh:
#   install    creates the initial Jenkins installation and its prerequisites.
#   configure  reconciles an existing release with jenkins/values.yaml and
#              jenkins/rbac/controller.yaml.
#
# Reconciliation refuses to create a missing Helm release: a first installation
# is install-jenkins.sh's job, never a silent side effect of this script.
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

Reapplies this repository's Jenkins configuration to an existing release:
the controller RBAC and a helm upgrade from the pinned chart with
jenkins/values.yaml.

Options:
  --dry-run   Run every check and render the upgrade without changing the
              cluster. Manifests are validated client-side and Helm runs with
              --dry-run, so nothing is applied.
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  HELM_TIMEOUT           How long to wait for the rollout. Default: 10m

Exit codes: 0 ok, 1 error, 2 usage.

Note on plugins: changing a pinned plugin version in jenkins/values.yaml
updates the desired configuration, but a plugin already written to the
persistent Jenkins home is not replaced by an upgrade - values.yaml sets
overwritePlugins: false, which is what keeps ordinary restarts stable.
Reconciling plugin pins on an existing volume is a destructive state change
and is not performed by this script.
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
require_repo_files "$VALUES_FILE" "$RBAC_MANIFEST"

info "repo root: ${REPO_ROOT}"
info "release:   ${JENKINS_RELEASE_NAME} (namespace ${JENKINS_NAMESPACE})"
[[ "$DRY_RUN" == true ]] && info "mode:      dry run - the cluster will not be changed"

require_expected_cluster

# --------------------------------------------------------------------------
# The release must already exist
# --------------------------------------------------------------------------

step "Existing release"

release_exists \
    || fail "no Helm release '${JENKINS_RELEASE_NAME}' in namespace '${JENKINS_NAMESPACE}'.
       This script updates an existing installation. To create one, run:
         ${SCRIPT_DIR}/install-jenkins.sh"

helm list -n "$JENKINS_NAMESPACE" --filter "^${JENKINS_RELEASE_NAME}\$"

# --------------------------------------------------------------------------
# Preconditions that an upgrade can silently break
#
# The externally owned admin Secret is checked before the upgrade, so the
# controller is not restarted with missing or broken credentials.
# --------------------------------------------------------------------------

step "Admin credentials"

require_admin_secret "$JENKINS_NAMESPACE"

# --------------------------------------------------------------------------
# Controller RBAC
# --------------------------------------------------------------------------

step "Controller RBAC"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$RBAC_MANIFEST"
else
    kubectl apply -f "$RBAC_MANIFEST"
fi

# --------------------------------------------------------------------------
# Chart artifact
#
# The pinned chart artifact is downloaded and SHA256-verified on every
# reconciliation, before Helm is given it.
# --------------------------------------------------------------------------

step "Pinned chart"

pull_and_verify_chart

# --------------------------------------------------------------------------
# Upgrade
# --------------------------------------------------------------------------

step "Helm upgrade"

helm_args=(
    upgrade "$JENKINS_RELEASE_NAME" "$JENKINS_CHART_TGZ"
    --namespace "$JENKINS_NAMESPACE"
    --values "$VALUES_FILE"
    --wait
    --timeout "$HELM_TIMEOUT"
)

if [[ "$DRY_RUN" == true ]]; then
    helm "${helm_args[@]}" --dry-run >/dev/null
    info "upgrade renders cleanly; nothing was applied"
    step "Dry run complete"
    exit 0
fi

helm "${helm_args[@]}"

step "Reconciled"

helm list -n "$JENKINS_NAMESPACE"
info "Check the result with ${SCRIPT_DIR}/verify-jenkins.sh"
