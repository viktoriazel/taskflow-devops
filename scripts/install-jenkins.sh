#!/usr/bin/env bash
#
# install-jenkins.sh - install Jenkins into the cluster from this repository.
#
# Creates the namespace, the controller RBAC and the agent identities, checks
# that the external Secrets are in place, verifies the pinned chart archive and
# creates the Helm release from it.
#
# Safe to re-run, and supports --dry-run.
#
# Dependencies: kubectl, helm, sha256sum.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/jenkins-common.sh
source "${SCRIPT_DIR}/jenkins-common.sh"

DRY_RUN=false
HELM_TIMEOUT="${HELM_TIMEOUT:-10m}"

# Cluster-scoped, so it is not part of the namespaced manifests jenkins-common.sh
# carries, and only this script creates it: verify reads the class name back off
# the PVC, and uninstall leaves cluster-scoped storage alone.
STORAGECLASS_MANIFEST="${JENKINS_DIR}/storageclass-gp3.yaml"

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--dry-run] [-h|--help]

Installs Jenkins from the configuration in jenkins/: the namespace, the
StorageClass the controller's PersistentVolumeClaim binds through, the
controller and agent ServiceAccounts with their RBAC, the Helm release built
from the chart version pinned in jenkins/chart.env, and the webhook Ingress
that publishes the GitHub hook path.

Options:
  --dry-run   Run every check and render the release without changing the
              cluster. Nothing is created or updated.
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  HELM_TIMEOUT           How long to wait for the controller. Default: 10m

Exit codes: 0 ok, 1 error, 2 usage.

Prerequisites, none of which this script creates:
  - The Jenkins admin Secret, in the Jenkins namespace. It is never stored in
    Git; create it from jenkins/examples/secret-jenkins-admin.example.yaml.
  - The GitHub webhook Secret, in the same namespace, created the same way from
    jenkins/examples/secret-github-webhook.example.yaml. The controller mounts
    it and does not start without it.
  - The devops-app namespace, where the CD agent's Role is created.

Both Secrets live in the namespace this script creates from
jenkins/namespace.yaml. On an empty cluster, apply that manifest, create the two
Secrets in it, then run this script.
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
require_repo_files "$VALUES_FILE" "$NAMESPACE_MANIFEST" "$STORAGECLASS_MANIFEST" \
    "$RBAC_MANIFEST" "${AGENT_RBAC_MANIFESTS[@]}" "$METRICS_SERVICE_MANIFEST" \
    "$WEBHOOK_INGRESS_MANIFEST"
jcasc_set_file_args

info "repo root: ${REPO_ROOT}"
info "release:   ${JENKINS_RELEASE_NAME} (namespace ${JENKINS_NAMESPACE})"
[[ "$DRY_RUN" == true ]] && info "mode:      dry run - the cluster will not be changed"

require_expected_cluster

# --------------------------------------------------------------------------
# Namespace
#
# Managed from its manifest, so its labels and lifecycle stay outside Helm.
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
# StorageClass
#
# Applied before the release, because the chart's PersistentVolumeClaim
# references it by name (persistence.storageClass in jenkins/values.yaml). If it
# is missing, the PVC stays Pending and the install fails on the Helm timeout
# rather than on the thing that is actually absent.
#
# Cluster-scoped and idempotent: re-running this reapplies the same definition.
# --------------------------------------------------------------------------

step "StorageClass"

if [[ "$DRY_RUN" == true ]]; then
    kubectl apply --dry-run=client -f "$STORAGECLASS_MANIFEST"
else
    kubectl apply -f "$STORAGECLASS_MANIFEST"
fi

# --------------------------------------------------------------------------
# External Secrets
#
# Both Secrets are checked before the release is installed. The webhook Secret
# is checked here too, because values.yaml mounts it into the controller and the
# Pod does not start without it.
# --------------------------------------------------------------------------

step "External Secrets"

require_admin_secret "$JENKINS_NAMESPACE"
require_webhook_secret "$JENKINS_NAMESPACE"

# --------------------------------------------------------------------------
# Controller RBAC
#
# Applied here because the chart's own RBAC is disabled in values.yaml
# (rbac.create: false).
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
# The agent ServiceAccounts must exist before a Pod template can use one. The CD
# Role is created in the application namespace, which has to exist already.
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
# --wait so the exit status reflects whether Jenkins actually came up.
#
# Not --atomic on purpose: after a failed first install its rollback would
# uninstall the release and delete the new PVC with its data (taskflow-gp3
# reclaims on delete). A failed install is left in place to be inspected;
# removing it is a call to uninstall-jenkins.sh.
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

    # The real run applies these after the release, which a dry run never
    # reaches. Validated here instead, so --dry-run still covers every manifest
    # the script would apply.
    step "Metrics Service"
    kubectl apply --dry-run=client -f "$METRICS_SERVICE_MANIFEST"

    step "Webhook Ingress"
    kubectl apply --dry-run=client -f "$WEBHOOK_INGRESS_MANIFEST"

    step "Dry run complete"
    exit 0
fi

helm "${helm_args[@]}"

# --------------------------------------------------------------------------
# Metrics Service
# --------------------------------------------------------------------------

step "Metrics Service"

kubectl apply -f "$METRICS_SERVICE_MANIFEST"

# --------------------------------------------------------------------------
# Webhook Ingress
#
# Applied after the release, because it routes to the jenkins Service the chart
# creates. Not a Helm resource: helm uninstall leaves it alone, which is why
# uninstall-jenkins.sh --purge-data keeps the load balancer and its DNS record
# intact while --purge-all removes it along with the namespace.
#
# Idempotent: reapplying an unchanged Ingress is a no-op and does not
# reprovision the load balancer.
# --------------------------------------------------------------------------

step "Webhook Ingress"

kubectl apply -f "$WEBHOOK_INGRESS_MANIFEST"

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
