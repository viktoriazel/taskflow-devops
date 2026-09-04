#!/usr/bin/env bash
#
# configure-jenkins.sh - reconcile a running Jenkins with this repository.
#
# install-jenkins.sh creates the installation. This script only updates an
# existing one: RBAC, the webhook Ingress, JCasC and the Helm release.
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
controller and agent RBAC, the webhook Ingress, the JCasC files, and a helm
upgrade from the pinned chart with jenkins/values.yaml.

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
require_repo_files "$VALUES_FILE" "$RBAC_MANIFEST" "${AGENT_RBAC_MANIFESTS[@]}" \
    "$METRICS_SERVICE_MANIFEST" "$WEBHOOK_INGRESS_MANIFEST"
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
# Metrics Service
# --------------------------------------------------------------------------

step "Metrics Service"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$METRICS_SERVICE_MANIFEST"
else
    kubectl apply -f "$METRICS_SERVICE_MANIFEST"
fi

# --------------------------------------------------------------------------
# Webhook Ingress
#
# Reapplied on every run for the same reason as the RBAC above: a change to the
# manifest - notably the pinned GitHub source ranges that check-webhook-cidrs.sh
# reports on - reaches the cluster through this script and not by hand.
#
# The Service it routes to already exists, because this script refuses to run
# without the release. Reapplying an unchanged Ingress is a no-op and does not
# reprovision the load balancer, so the webhook endpoint and its DNS record are
# untouched by a routine reconcile.
# --------------------------------------------------------------------------

step "Webhook Ingress"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$WEBHOOK_INGRESS_MANIFEST"
else
    kubectl apply -f "$WEBHOOK_INGRESS_MANIFEST"
fi

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
