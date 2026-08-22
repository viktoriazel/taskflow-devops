#!/usr/bin/env bash
#
# bootstrap-app.sh - safely bootstrap the full TaskFlow application.
#
# Applies k8s/base for initial environment setup. Routine releases use
# k8s/overlays/release instead. Runtime Secrets are provisioned separately and
# are only checked by name.
#
# Dependency: kubectl with built-in Kustomize.

set -euo pipefail

# --------------------------------------------------------------------------
# Constants and configuration
# --------------------------------------------------------------------------

# Resolve paths relative to the script so execution does not depend on CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_DIR="${REPO_ROOT}/k8s/base"
NAMESPACE_MANIFEST="${BASE_DIR}/00-namespace.yaml"

NAMESPACE="devops-app"
DEPLOYMENTS=(backend frontend worker)
REQUIRED_SECRETS=(taskflow-db-credentials taskflow-frontend-secret)

# Refuse to run against an unexpected cluster; the name can be overridden for
# another environment built from the same configuration.
EXPECTED_CLUSTER_NAME="${EXPECTED_CLUSTER_NAME:-taskflow-dev-eks}"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"

DRY_RUN=false
ALLOW_EXISTING=false

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

info()  { printf '  %s\n' "$*"; }
step()  { printf '\n==> %s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
fail()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--dry-run] [--allow-existing] [-h|--help]

Applies the TaskFlow bootstrap set (k8s/base) to the devops-app namespace and
verifies the result. Run once, by an operator, before the first release.

Options:
  --dry-run         Validate everything and run a server-side dry-run apply.
                    Nothing is created, changed or deleted.
  --allow-existing  Proceed even when the namespace looks like it has already
                    received a release. Read the refusal message first: doing
                    this can roll the running images back to the baseline
                    pinned in k8s/base and strip release traceability
                    annotations from the Pod templates.
  -h, --help        Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  ROLLOUT_TIMEOUT        Per-Deployment rollout timeout. Default: 180s

Exit codes: 0 ok, 1 error, 2 usage, 3 refused by the safety guard.

Prerequisites: the two application Secrets must already exist in the
namespace. They are never stored in Git; see k8s/examples/ for their shape.
EOF
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true ;;
        --allow-existing) ALLOW_EXISTING=true ;;
        -h|--help)        usage; exit 0 ;;
        *)                printf 'ERROR: unknown argument: %s\n\n' "$1" >&2
                          usage >&2
                          exit 2 ;;
    esac
    shift
done

if $DRY_RUN; then
    printf 'TaskFlow bootstrap - DRY RUN (nothing will be created or changed)\n'
else
    printf 'TaskFlow bootstrap\n'
fi

# --------------------------------------------------------------------------
# Preflight: tooling
# --------------------------------------------------------------------------

step "Checking tooling"

command -v kubectl >/dev/null 2>&1 \
    || fail "kubectl not found in PATH. Install kubectl and configure access to the cluster."

if (( BASH_VERSINFO[0] < 4 )); then
    fail "bash 4 or newer is required (found ${BASH_VERSION})."
fi

[[ -d "$BASE_DIR" ]] \
    || fail "bootstrap set not found at ${BASE_DIR}. Run this script from a full checkout of the repository."

info "kubectl:   $(kubectl version --client 2>/dev/null | head -n1)"
info "repo root: ${REPO_ROOT}"

# --------------------------------------------------------------------------
# Preflight: cluster identity
#
# Verify the active cluster before any Kubernetes mutation.
# --------------------------------------------------------------------------

step "Checking target cluster"

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CURRENT_CONTEXT" ]] \
    || fail "no active kubectl context. Select one with 'kubectl config use-context <name>'."

CURRENT_CLUSTER="$(kubectl config view --minify --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
[[ -n "$CURRENT_CLUSTER" ]] \
    || fail "could not determine the cluster for context '${CURRENT_CONTEXT}'."

info "context: ${CURRENT_CONTEXT}"
info "cluster: ${CURRENT_CLUSTER}"
info "expected cluster name: ${EXPECTED_CLUSTER_NAME}"

# The cluster entry may be a bare name or an ARN-style reference whose last
# path segment is the cluster name; both are accepted, nothing else is.
if [[ "$CURRENT_CLUSTER" != "$EXPECTED_CLUSTER_NAME" && "$CURRENT_CLUSTER" != */"$EXPECTED_CLUSTER_NAME" ]]; then
    fail "active cluster '${CURRENT_CLUSTER}' is not '${EXPECTED_CLUSTER_NAME}'.
       Refusing to touch a cluster this repository does not describe.
       Switch context, or set EXPECTED_CLUSTER_NAME if this is intentional."
fi

info "cluster matches - continuing"

# --------------------------------------------------------------------------
# Render the bootstrap set
# --------------------------------------------------------------------------

step "Rendering ${BASE_DIR#"${REPO_ROOT}/"}"

RENDER_FILE="$(mktemp)"
trap 'rm -f "${RENDER_FILE}"' EXIT

kubectl kustomize "$BASE_DIR" >"$RENDER_FILE" \
    || fail "kustomize build of ${BASE_DIR} failed. Fix the manifests before deploying."

RENDERED_OBJECTS="$(grep -c '^kind:' "$RENDER_FILE" || true)"
info "rendered ${RENDERED_OBJECTS} objects"

# --------------------------------------------------------------------------
# Image guard
#
# Require every rendered application image to be an exact digest reference.
# This catches unmatched image transforms, tags and sentinels before apply.
# --------------------------------------------------------------------------

step "Checking image references"

# Indent-agnostic, and tolerant of "image:" appearing as the first key of a
# container list item ("- image:") as well as on its own line.
mapfile -t RENDERED_IMAGES < <(
    sed -n 's/^[[:space:]]*-\{0,1\}[[:space:]]*image:[[:space:]]*//p' "$RENDER_FILE" \
        | sed 's/^"//; s/"$//; s/[[:space:]]*$//'
)

DIGEST_RE='^[^[:space:]@:]+@sha256:[0-9a-f]{64}$'
EXPECTED_IMAGE_COUNT=${#DEPLOYMENTS[@]}

if (( ${#RENDERED_IMAGES[@]} != EXPECTED_IMAGE_COUNT )); then
    fail "expected ${EXPECTED_IMAGE_COUNT} image references in the render, found ${#RENDERED_IMAGES[@]}.
       The bootstrap set must deploy exactly one image per application service."
fi

for img in "${RENDERED_IMAGES[@]}"; do
    if [[ ! "$img" =~ $DIGEST_RE ]]; then
        fail "image reference is not digest-pinned: '${img}'
       Every rendered reference must be repository@sha256:<64 hex>.
       A bare repository, a tag, ':latest' or a leftover IMAGE-NOT-SET sentinel
       all mean the images transformer did not apply as intended."
    fi
    info "digest-pinned: ${img}"
done

info "all ${#RENDERED_IMAGES[@]} image references are digest-pinned"

# Build a Deployment-to-image map for state checks and post-rollout verification.
declare -A EXPECTED_IMAGE=()
while IFS=$'\t' read -r dep_name dep_image; do
    [[ -n "$dep_name" ]] && EXPECTED_IMAGE["$dep_name"]="$dep_image"
done < <(
    awk '
        function flush() {
            if (kind == "Deployment" && name != "" && img != "")
                printf "%s\t%s\n", name, img
            kind = ""; name = ""; img = ""
        }
        /^---[[:space:]]*$/                 { flush(); next }
        /^kind:[[:space:]]/                 { kind = $2; next }
        /^  name:[[:space:]]/ && name == "" { name = $2; next }
        {
            if (img == "" && match($0, /^[[:space:]]*-?[[:space:]]*image:[[:space:]]*/)) {
                img = substr($0, RSTART + RLENGTH)
                gsub(/^"|"$|[[:space:]]+$/, "", img)
            }
        }
        END { flush() }
    ' "$RENDER_FILE"
)

for dep in "${DEPLOYMENTS[@]}"; do
    [[ -n "${EXPECTED_IMAGE[$dep]:-}" ]] \
        || fail "the render does not describe a Deployment named '${dep}'."
done

# --------------------------------------------------------------------------
# Namespace
#
# Create the namespace first so externally managed Secrets can be provisioned
# before the Deployments that consume them.
# --------------------------------------------------------------------------

step "Checking namespace '${NAMESPACE}'"

NAMESPACE_EXISTS=false
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    NAMESPACE_EXISTS=true
    info "namespace exists"
elif $DRY_RUN; then
    info "namespace does not exist"
    info "a real run would create it from ${NAMESPACE_MANIFEST#"${REPO_ROOT}/"} before anything else"
else
    info "namespace does not exist - creating it from ${NAMESPACE_MANIFEST#"${REPO_ROOT}/"}"
    kubectl apply -f "$NAMESPACE_MANIFEST" \
        || fail "failed to create namespace '${NAMESPACE}'."
    NAMESPACE_EXISTS=true
fi

# --------------------------------------------------------------------------
# Bootstrap-vs-release safety guard
#
# Allow fresh bootstrap and safe repeats, but refuse to apply the bootstrap
# baseline over a released or drifted application state.
# --------------------------------------------------------------------------

step "Assessing existing application state"

STATE="fresh"
STATE_REASONS=()

if $NAMESPACE_EXISTS; then
    present=()
    missing=()
    for dep in "${DEPLOYMENTS[@]}"; do
        if kubectl get deployment "$dep" -n "$NAMESPACE" >/dev/null 2>&1; then
            present+=("$dep")
        else
            missing+=("$dep")
        fi
    done

    if (( ${#present[@]} == 0 )); then
        STATE="fresh"
        info "no application Deployments found - this is a fresh bootstrap"
    elif (( ${#missing[@]} > 0 )); then
        STATE="unsafe"
        STATE_REASONS+=("only ${#present[@]} of ${#DEPLOYMENTS[@]} Deployments exist (missing: ${missing[*]}) - the namespace is in a partial state")
    else
        STATE="safe-repeat"
        for dep in "${DEPLOYMENTS[@]}"; do
            live_image="$(kubectl get deployment "$dep" -n "$NAMESPACE" \
                -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
            if [[ "$live_image" != "${EXPECTED_IMAGE[$dep]}" ]]; then
                STATE="unsafe"
                STATE_REASONS+=("${dep}: running image differs from the bootstrap baseline")
                STATE_REASONS+=("    live:     ${live_image:-<unreadable>}")
                STATE_REASONS+=("    baseline: ${EXPECTED_IMAGE[$dep]}")
            fi

            # Any taskflow.io/* annotation indicates a prior release. Only the
            # keys are read; no values are printed.
            release_keys="$(kubectl get deployment "$dep" -n "$NAMESPACE" \
                -o go-template='{{range $k, $v := .spec.template.metadata.annotations}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null \
                | grep '^taskflow\.io/' || true)"
            if [[ -n "$release_keys" ]]; then
                STATE="unsafe"
                STATE_REASONS+=("${dep}: Pod template carries release traceability annotations: $(echo "$release_keys" | tr '\n' ' ')")
            fi
        done

        if [[ "$STATE" == "safe-repeat" ]]; then
            info "all ${#DEPLOYMENTS[@]} Deployments match the bootstrap baseline and carry no release annotations"
            info "re-running bootstrap over this state is safe"
        fi
    fi
else
    info "namespace absent - nothing deployed yet"
fi

GUARD_WOULD_REFUSE=false
if [[ "$STATE" == "unsafe" ]]; then
    GUARD_WOULD_REFUSE=true
    printf '\n'
    warn "this namespace does not look like a plain bootstrap:"
    for reason in "${STATE_REASONS[@]}"; do
        printf '         %s\n' "$reason" >&2
    done
    printf '\n' >&2
    printf '         Applying k8s/base here can roll the running images back to the\n' >&2
    printf '         baseline digests pinned in the bootstrap set, and can remove the\n' >&2
    printf '         release traceability annotations from the Pod templates. Both\n' >&2
    printf '         changes restart Pods.\n\n' >&2

    if $ALLOW_EXISTING; then
        warn "--allow-existing given - proceeding anyway"
    elif $DRY_RUN; then
        printf 'REFUSED: a real apply would be refused unless --allow-existing is given.\n' >&2
        printf '         Re-run as: %s --dry-run --allow-existing\n' "$(basename "${BASH_SOURCE[0]}")" >&2
        printf '         to continue the dry run past this guard.\n' >&2
        exit 3
    else
        printf 'REFUSED: refusing to apply the bootstrap set over this state.\n' >&2
        printf '         Deploy through k8s/overlays/release instead, or re-run with\n' >&2
        printf '         --allow-existing if rolling back to the baseline is intended.\n' >&2
        exit 3
    fi
fi

# --------------------------------------------------------------------------
# Secrets
#
# Check required Secrets by name only. Their values are external to this
# repository; this script never reads or creates them.
# --------------------------------------------------------------------------

step "Checking required Secrets"

if ! $NAMESPACE_EXISTS; then
    info "namespace '${NAMESPACE}' does not exist yet, so Secret presence cannot be checked"
    info "a real run creates the namespace first, then requires both Secrets to exist:"
    for secret in "${REQUIRED_SECRETS[@]}"; do
        info "  - ${secret}"
    done
else
    missing_secrets=()
    for secret in "${REQUIRED_SECRETS[@]}"; do
        if kubectl get secret "$secret" -n "$NAMESPACE" -o name >/dev/null 2>&1; then
            info "present: ${secret}"
        else
            missing_secrets+=("$secret")
        fi
    done

    if (( ${#missing_secrets[@]} > 0 )); then
        printf '\n' >&2
        printf 'ERROR: required Secret(s) missing from namespace %s: %s\n' "$NAMESPACE" "${missing_secrets[*]}" >&2
        printf '       These are external prerequisites. They hold real credentials, are\n' >&2
        printf '       deliberately not tracked in Git, and are not created by this script.\n' >&2
        printf '       Create them from your own AWS values - k8s/examples/ shows the\n' >&2
        printf '       required shape and keys - then run this script again.\n' >&2
        exit 1
    fi
fi

# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------

if $DRY_RUN; then
    step "Server-side validation (no changes are persisted)"

    kubectl apply -k "$BASE_DIR" --dry-run=server \
        || fail "server-side validation failed. The cluster rejected the rendered manifests."

    step "Dry run complete"
    info "nothing was created, changed or deleted"
    if $GUARD_WOULD_REFUSE; then
        info "note: a real apply would have been refused by the safety guard above"
        info "      (it continued here only because --allow-existing was given)"
    fi
    exit 0
fi

step "Applying the bootstrap set"

kubectl apply -k "$BASE_DIR" \
    || fail "apply failed. The cluster may be partially updated; inspect it before retrying."

# --------------------------------------------------------------------------
# Rollout
# --------------------------------------------------------------------------

step "Waiting for rollouts (timeout ${ROLLOUT_TIMEOUT} each)"

rollout_failed=false
for dep in "${DEPLOYMENTS[@]}"; do
    if kubectl rollout status "deployment/${dep}" -n "$NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"; then
        :
    else
        rollout_failed=true
        warn "rollout of deployment/${dep} did not complete within ${ROLLOUT_TIMEOUT}"
    fi
done

if $rollout_failed; then
    printf '\n' >&2
    printf 'ERROR: at least one rollout did not complete.\n' >&2
    printf '       Inspect with:\n' >&2
    printf '         kubectl get pods -n %s\n' "$NAMESPACE" >&2
    printf '         kubectl describe deployment/<name> -n %s\n' "$NAMESPACE" >&2
    printf '         kubectl get events -n %s --sort-by=.metadata.creationTimestamp\n' "$NAMESPACE" >&2
    exit 1
fi

# --------------------------------------------------------------------------
# Verification
#
# Verify that successful rollouts are running the exact expected images.
# --------------------------------------------------------------------------

step "Verifying deployed images"

verify_failed=false
for dep in "${DEPLOYMENTS[@]}"; do
    live_image="$(kubectl get deployment "$dep" -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"

    if [[ "$live_image" == "${EXPECTED_IMAGE[$dep]}" ]]; then
        info "${dep}: ${live_image}"
    else
        verify_failed=true
        warn "${dep}: deployed image does not match the bootstrap set"
        printf '         expected: %s\n' "${EXPECTED_IMAGE[$dep]}" >&2
        printf '         actual:   %s\n' "${live_image:-<unreadable>}" >&2
    fi
done

step "Verifying Services and Ingress"

for svc in "${DEPLOYMENTS[@]}"; do
    if kubectl get service "$svc" -n "$NAMESPACE" -o name >/dev/null 2>&1; then
        info "service/${svc} present"
    else
        verify_failed=true
        warn "service/${svc} is missing"
    fi
done

if kubectl get ingress frontend -n "$NAMESPACE" -o name >/dev/null 2>&1; then
    ingress_address="$(kubectl get ingress frontend -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    info "ingress/frontend present${ingress_address:+ - address: ${ingress_address}}"
    [[ -n "$ingress_address" ]] \
        || info "ingress has no address yet; the load balancer may still be provisioning"
else
    verify_failed=true
    warn "ingress/frontend is missing"
fi

step "Summary"
kubectl get deployments -n "$NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image' \
    || true

if $verify_failed; then
    printf '\n' >&2
    printf 'ERROR: bootstrap applied but verification failed - see the warnings above.\n' >&2
    exit 1
fi

printf '\nBootstrap complete. All %d Deployments are running the expected images.\n' "${#DEPLOYMENTS[@]}"
printf 'Releases from here on go through k8s/overlays/release, not this script.\n'
