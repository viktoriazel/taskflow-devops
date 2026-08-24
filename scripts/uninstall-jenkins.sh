#!/usr/bin/env bash
#
# uninstall-jenkins.sh - remove Jenkins from the cluster.
#
# Removing the Helm release destroys the Jenkins home volume, and this script
# will not do that unless it is told to in so many words.
#
# Why the release takes the data with it: the chart declares the Jenkins home
# PVC as an ordinary release resource, with no helm.sh/resource-policy
# annotation, so `helm uninstall` deletes it. Helm decides what to keep from
# the manifest stored in the release record, not from the live object, so
# annotating the PVC afterwards would not save it. The PVC is bound through
# taskflow-gp3, whose reclaimPolicy is Delete, so removing it also deletes the
# backing EBS volume and everything in JENKINS_HOME: job history, credentials
# store, installed plugins.
#
# Running with no arguments therefore explains what would be destroyed and
# refuses. The acknowledgement is a flag rather than a prompt so the script
# stays usable from automation.
#
# Ownership, which decides what each mode may touch:
#   Helm       StatefulSet, Services, ConfigMaps, the Jenkins home PVC
#   Repository namespace manifest, controller RBAC, agent identities and
#              permissions
#   Operator   the admin Secret - managed externally, never by this repository
#
# Dependencies: kubectl, helm.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/jenkins-common.sh
source "${SCRIPT_DIR}/jenkins-common.sh"

PURGE_DATA=false
PURGE_ALL=false
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--purge-data | --purge-all] [-h|--help]

Removes the Jenkins installation. Without a flag it destroys nothing: it
reports what removal would delete and exits.

Options:
  --purge-data  Delete the Helm release, including the Jenkins home PVC. With
                the expected reclaimPolicy Delete that also removes the EBS
                volume holding JENKINS_HOME, and the data cannot be recovered.
                Left in place: namespace, controller RBAC, agent identities,
                CD permissions in the application namespace, and the admin
                Secret.
  --purge-all   Everything --purge-data removes, plus the controller RBAC, the
                agent identities - including the CD Role and RoleBinding, which
                live in the application namespace - and the Jenkins namespace.
                Deleting that namespace also removes the admin Secret and
                anything else living in it.
  -h, --help    Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  HELM_TIMEOUT           How long to wait for release and PVC deletion.
                         Default: 5m

Exit codes: 0 ok, 1 error, 2 usage, 3 refused - no acknowledgement given.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge-data) PURGE_DATA=true ;;
        --purge-all)  PURGE_ALL=true; PURGE_DATA=true ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; printf '\nUnknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

step "Preflight"

require_commands kubectl helm
load_chart_env

info "repo root: ${REPO_ROOT}"
info "release:   ${JENKINS_RELEASE_NAME} (namespace ${JENKINS_NAMESPACE})"

require_expected_cluster

# --------------------------------------------------------------------------
# What is actually there
# --------------------------------------------------------------------------

step "Current state"

# Three states, not two. release_exists answers with a single boolean, and its
# `helm status` cannot tell "no such release" apart from "could not ask" - both
# are exit 1. Here that difference decides whether the release is skipped while
# its PVC is still deleted, so a failed query stops the run instead.
# `-a` is required: without it a release that is pending or uninstalling is not
# listed and would read as absent.
if ! release_list="$(helm list -n "$JENKINS_NAMESPACE" -a \
        --filter "^${JENKINS_RELEASE_NAME}\$" -q 2>/dev/null)"; then
    fail "could not determine the state of Helm release '${JENKINS_RELEASE_NAME}' in namespace '${JENKINS_NAMESPACE}'. Nothing was removed."
elif [[ -n "$release_list" ]]; then
    RELEASE_PRESENT=true
    info "Helm release present: ${JENKINS_RELEASE_NAME}"
else
    RELEASE_PRESENT=false
    info "Helm release not found - nothing for Helm to remove"
fi

# One accurate sentence about the backing volume, reused by the reports below.
VOLUME_NOTE=""

# --ignore-not-found keeps an absent PVC at exit 0 with empty output, so a
# non-zero exit means the query itself failed. That must not reach the
# acknowledgement below as "nothing to lose".
if ! PVC_NAME="$(kubectl get pvc "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" \
        --ignore-not-found -o jsonpath='{.metadata.name}' 2>/dev/null)"; then
    fail "could not query the Jenkins home PVC in namespace '${JENKINS_NAMESPACE}'. Nothing was removed."
fi

if [[ -n "$PVC_NAME" ]]; then
    # Descriptive only - none of these decides anything, so an unreadable field
    # is reported as '?' rather than stopping the run.
    pvc_size="$(kubectl get pvc "$PVC_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
    pvc_sc="$(kubectl get pvc "$PVC_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.storageClassName}' 2>/dev/null || true)"
    pv_name="$(kubectl get pvc "$PVC_NAME" -n "$JENKINS_NAMESPACE" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    pv_policy=""
    [[ -n "$pv_name" ]] && pv_policy="$(kubectl get pv "$pv_name" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)"

    info "Jenkins home PVC: ${PVC_NAME} (${pvc_size:-?}, storageClass ${pvc_sc:-?})"

    if [[ -n "$pv_name" ]]; then
        info "bound volume:     ${pv_name} (reclaimPolicy ${pv_policy:-?})"

        # Only reclaimPolicy Delete takes the EBS volume with the PVC, and the
        # CSI driver does that asynchronously. Anything else is reported and
        # never blocks: removing Jenkins stays the operator's decision.
        if [[ "$pv_policy" == "Delete" ]]; then
            VOLUME_NOTE="Backing EBS volume: deleted by the EBS CSI driver once the PVC is gone; this can complete asynchronously."
        elif [[ -n "$pv_policy" ]]; then
            warn "reclaimPolicy of ${pv_name} is ${pv_policy}, not Delete - the backing volume and its data are retained"
            VOLUME_NOTE="Backing EBS volume: RETAINED - ${pv_name} has reclaimPolicy ${pv_policy}, so the volume and its data still exist and need explicit cleanup."
        else
            warn "reclaimPolicy of ${pv_name} could not be read - deletion of the backing EBS volume cannot be confirmed"
            VOLUME_NOTE="Backing EBS volume: deletion could not be confirmed - the reclaimPolicy of ${pv_name} was unreadable."
        fi
    fi
else
    info "Jenkins home PVC: not present"
fi

# --------------------------------------------------------------------------
# The safety gate
# --------------------------------------------------------------------------

if [[ "$PURGE_DATA" != true ]]; then
    step "Nothing was removed"

    cat >&2 <<EOF
Removing the Helm release would delete, permanently:
  - the Jenkins controller and its Kubernetes objects
  - the Jenkins home PVC${PVC_NAME:+ (${PVC_NAME}${pvc_size:+, ${pvc_size}})}
  - the backing EBS volume, if its reclaimPolicy is Delete${pv_policy:+ (currently ${pv_policy})}, and with
    it every job history entry, stored credential and installed plugin

There is no supported way to remove the release and keep the data: the chart
does not mark the PVC to be kept, and Helm reads that decision from the stored
release manifest, so it cannot be added after the fact.

To proceed anyway:
  $(basename "${BASH_SOURCE[0]}") --purge-data   release and Jenkins home PVC; the backing
                        volume follows its reclaimPolicy
  $(basename "${BASH_SOURCE[0]}") --purge-all    the above, plus RBAC and the namespace
                        (which also removes the admin Secret)
EOF
    refuse "no acknowledgement given - JENKINS_HOME left untouched."
fi

# --------------------------------------------------------------------------
# Release
# --------------------------------------------------------------------------

step "Removing the Helm release"

if [[ "$RELEASE_PRESENT" == true ]]; then
    helm uninstall "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" --wait --timeout "$HELM_TIMEOUT"
    info "release removed, together with the Jenkins home PVC"
else
    info "skipped - no release to remove"
fi

# The PVC may survive if it was created outside the release, or if a previous
# run was interrupted. Remove it here so --purge-data means what it says.
#
# The recheck must not swallow a query error: a PVC that cannot be read is not a
# PVC that is gone. The delete then waits for finalizers, so the report below is
# only reached once the PVC has actually been removed - one still Terminating at
# the timeout ends the run instead of being reported as deleted.
if [[ -n "$PVC_NAME" ]]; then
    if ! remaining_pvc="$(kubectl get pvc "$PVC_NAME" -n "$JENKINS_NAMESPACE" \
            --ignore-not-found -o name 2>/dev/null)"; then
        fail "could not check whether PVC '${PVC_NAME}' survived the uninstall."
    fi

    if [[ -n "$remaining_pvc" ]]; then
        warn "PVC ${PVC_NAME} still exists after the uninstall; deleting it as requested"
        kubectl delete pvc "$PVC_NAME" -n "$JENKINS_NAMESPACE" --wait --timeout "$HELM_TIMEOUT" \
            || fail "PVC '${PVC_NAME}' had not disappeared within ${HELM_TIMEOUT} - it may be held by a finalizer or still in use. No further cleanup was attempted."
    fi
fi

if [[ "$PURGE_ALL" != true ]]; then
    step "Done"
    cat <<EOF
Removed:   Helm release, controller workload, and the Jenkins home PVC.
Kept:      namespace ${JENKINS_NAMESPACE}, controller RBAC, agent identities,
           CD permissions in ${APP_NAMESPACE}, and Secret ${ADMIN_SECRET_NAME}.
           Reinstalling with install-jenkins.sh reuses them.
EOF
    [[ -n "$VOLUME_NOTE" ]] && printf '%s\n' "$VOLUME_NOTE"
    exit 0
fi

# --------------------------------------------------------------------------
# Repository-owned objects and the namespace
#
# Order matters: RBAC first while the namespace still exists, so its removal is
# visible in the output rather than silently swallowed by the namespace going
# away underneath it.
# --------------------------------------------------------------------------

step "Removing controller RBAC"

if [[ -f "$RBAC_MANIFEST" ]]; then
    kubectl delete -f "$RBAC_MANIFEST" --ignore-not-found
else
    warn "RBAC manifest not found at ${RBAC_MANIFEST}; skipping"
fi

# The CD agent's Role and RoleBinding live in the application namespace, which
# this script never deletes. Without this step they would outlive the Jenkins
# installation and leave a standing grant on the application namespace bound to
# a ServiceAccount that no longer exists.
step "Removing agent RBAC"

for manifest in "${AGENT_RBAC_MANIFESTS[@]}"; do
    if [[ -f "$manifest" ]]; then
        kubectl delete -f "$manifest" --ignore-not-found
    else
        warn "agent RBAC manifest not found at ${manifest}; skipping"
    fi
done

step "Removing the namespace"

kubectl delete namespace "$JENKINS_NAMESPACE" --ignore-not-found --wait=false

step "Done"

cat <<EOF
Removed:   Helm release, controller workload, the Jenkins home PVC, the
           controller RBAC, and the agent identities including the CD Role and
           RoleBinding in namespace ${APP_NAMESPACE}.
Requested: deletion of namespace ${JENKINS_NAMESPACE}, which takes the admin
           Secret ${ADMIN_SECRET_NAME} with it.
Next:      recreate the Secret from
           jenkins/examples/secret-jenkins-admin.example.yaml before installing
           again.
EOF

[[ -n "$VOLUME_NOTE" ]] && printf '%s\n' "$VOLUME_NOTE"

cat <<EOF

Namespace deletion runs in the background; watch it with:
  kubectl get namespace ${JENKINS_NAMESPACE}
EOF
