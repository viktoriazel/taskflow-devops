#!/usr/bin/env bash
#
# configure-jenkins.sh - reconcile a running Jenkins with this repository.
#
# install-jenkins.sh creates the installation. This script only updates an
# existing one: the controller and agent RBAC, the JCasC files and the release.
#
# It refuses to create a missing Helm release - that is install-jenkins.sh's job.
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

Reapplies this repository's Jenkins configuration to an existing release: the
controller and agent RBAC, the JCasC files, and a helm upgrade from the pinned
chart with jenkins/values.yaml.

Options:
  --dry-run   Run every check and render the upgrade without changing the
              cluster. Nothing is applied.
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  HELM_TIMEOUT           How long to wait for the rollout. Default: 10m

Exit codes: 0 ok, 1 error, 2 usage.

Note on plugins: values.yaml sets overwritePlugins: false, so the plugin
directory on the volume is never cleared. A newer pinned version still replaces
the installed one when the controller restarts, but moving a pin backwards is
not applied here and needs its own procedure.
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
require_repo_files "$VALUES_FILE" "$RBAC_MANIFEST" "${AGENT_RBAC_MANIFESTS[@]}"
jcasc_set_file_args

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
# The external Secrets are checked before the upgrade, so the controller is not
# restarted without working credentials. If values.yaml mounts a Secret the
# namespace does not have, the new Pod cannot start and the old one is gone.
# --------------------------------------------------------------------------

step "External Secrets"

require_admin_secret "$JENKINS_NAMESPACE"
require_webhook_secret "$JENKINS_NAMESPACE"

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
# Agent identities and permissions
#
# Reapplied on every run, so changes to an agent ServiceAccount or to the CD
# Role reach the cluster through this script and not by hand.
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
#
# Downloaded and SHA256-verified on every run, before Helm is given it.
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
    "${JCASC_SET_FILE_ARGS[@]}"
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
