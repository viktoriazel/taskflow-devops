#!/usr/bin/env bash
#
# jenkins-common.sh - helper library sourced by the Jenkins lifecycle scripts.
#
# Centralizes the shared validation and verification logic so install, configure
# and verify behave identically.

# Guard against being run directly - it would do nothing useful.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'ERROR: %s is a library and must be sourced, not executed.\n' "$(basename "${BASH_SOURCE[0]}")" >&2
    exit 2
fi

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

info()  { printf '  %s\n' "$*"; }
step()  { printf '\n==> %s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }
fail()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 3; }

# --------------------------------------------------------------------------
# Repository layout and pinned chart coordinates
# --------------------------------------------------------------------------

JENKINS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${JENKINS_SCRIPT_DIR}/.." && pwd)"

JENKINS_DIR="${REPO_ROOT}/jenkins"
CHART_ENV="${JENKINS_DIR}/chart.env"
VALUES_FILE="${JENKINS_DIR}/values.yaml"
# Consumed by the scripts that source this file, not here.
# shellcheck disable=SC2034
NAMESPACE_MANIFEST="${JENKINS_DIR}/namespace.yaml"
# shellcheck disable=SC2034
RBAC_MANIFEST="${JENKINS_DIR}/rbac/controller.yaml"

# The admin credentials are an external prerequisite: an operator creates this
# Secret from jenkins/examples/secret-jenkins-admin.example.yaml. No script here
# creates the Secret or invents a password, and no credential value is ever
# printed or persisted by these scripts.
ADMIN_SECRET_NAME="jenkins-admin"
ADMIN_SECRET_KEYS=(jenkins-admin-user jenkins-admin-password)

# Refuse to run against an unexpected cluster; overridable for another
# environment built from the same configuration.
EXPECTED_CLUSTER_NAME="${EXPECTED_CLUSTER_NAME:-taskflow-dev-eks}"

load_chart_env() {
    [[ -f "$CHART_ENV" ]] \
        || fail "pinned chart coordinates not found at ${CHART_ENV}. Run this from a full checkout of the repository."

    # shellcheck source=/dev/null
    source "$CHART_ENV"

    local var
    for var in JENKINS_CHART_REPO_URL JENKINS_CHART_NAME JENKINS_CHART_VERSION \
               JENKINS_CHART_SHA256 JENKINS_RELEASE_NAME JENKINS_NAMESPACE; do
        [[ -n "${!var:-}" ]] || fail "${var} is not set in ${CHART_ENV}."
    done

    [[ "$JENKINS_CHART_VERSION" != "latest" ]] \
        || fail "JENKINS_CHART_VERSION must be an exact version, never 'latest'."
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 \
            || fail "${cmd} not found in PATH."
    done

    if (( BASH_VERSINFO[0] < 4 )); then
        fail "bash 4 or newer is required (found ${BASH_VERSION})."
    fi
}

# Guard against the lifecycle scripts operating on an unexpected cluster.
require_expected_cluster() {
    local context cluster

    context="$(kubectl config current-context 2>/dev/null || true)"
    [[ -n "$context" ]] \
        || fail "no active kubectl context. Select one with 'kubectl config use-context <name>'."

    cluster="$(kubectl config view --minify --output jsonpath='{.clusters[0].name}' 2>/dev/null || true)"
    [[ -n "$cluster" ]] \
        || fail "could not determine the cluster for context '${context}'."

    info "context: ${context}"
    info "cluster: ${cluster}"

    # The expected cluster may appear as a bare name or as an ARN-style
    # reference ending in that name; nothing else is accepted.
    if [[ "$cluster" != "$EXPECTED_CLUSTER_NAME" && "$cluster" != */"$EXPECTED_CLUSTER_NAME" ]]; then
        fail "active cluster '${cluster}' is not '${EXPECTED_CLUSTER_NAME}'.
       Refusing to touch a cluster this repository does not describe.
       Switch context, or set EXPECTED_CLUSTER_NAME if this is intentional."
    fi
}

require_repo_files() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || fail "required file missing: ${f}"
    done
}

# --------------------------------------------------------------------------
# Admin Secret preflight
#
# Confirms the Secret exists and that both required keys are present and
# non-empty. The Go template below emits only key names and value lengths into
# the shell, so the credential values themselves never reach stdout, stderr or
# a log.
# --------------------------------------------------------------------------

require_admin_secret() {
    local ns="$1"
    local keys_and_lengths key length found missing=()

    kubectl get secret "$ADMIN_SECRET_NAME" -n "$ns" -o name >/dev/null 2>&1 \
        || fail "Secret '${ADMIN_SECRET_NAME}' not found in namespace '${ns}'.
       It holds the Jenkins admin credentials, is deliberately not tracked in
       Git, and is not created by this script. Create it from the template:
         ${JENKINS_DIR}/examples/secret-jenkins-admin.example.yaml"

    # Single-quoted: $k and $v belong to the Go template, not to the shell.
    # shellcheck disable=SC2016
    keys_and_lengths="$(kubectl get secret "$ADMIN_SECRET_NAME" -n "$ns" \
        -o go-template='{{range $k, $v := .data}}{{$k}} {{len $v}}{{"\n"}}{{end}}')"

    for key in "${ADMIN_SECRET_KEYS[@]}"; do
        found=false
        while read -r name length; do
            [[ "$name" == "$key" ]] || continue
            found=true
            (( length > 0 )) || fail "Secret '${ADMIN_SECRET_NAME}' has key '${key}' but it is empty."
        done <<< "$keys_and_lengths"
        if [[ "$found" == true ]]; then
            info "key present and non-empty: ${key}"
        else
            missing+=("$key")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        fail "Secret '${ADMIN_SECRET_NAME}' is missing required key(s): ${missing[*]}
       Expected keys are set in ${VALUES_FILE} as controller.admin.userKey and
       controller.admin.passwordKey."
    fi
}

# --------------------------------------------------------------------------
# Chart artifact verification
#
# Downloads the pinned chart, verifies its sha256 against jenkins/chart.env and
# exports the path to that file, so Helm installs the exact verified artifact
# instead of resolving the chart again. --repo is used instead of
# 'helm repo add' to leave the operator's Helm configuration untouched.
# --------------------------------------------------------------------------

pull_and_verify_chart() {
    local tmpdir actual expected

    tmpdir="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand tmpdir now: it must survive the trap.
    trap "rm -rf '${tmpdir}'" EXIT

    info "chart:   ${JENKINS_CHART_NAME} ${JENKINS_CHART_VERSION}"
    info "source:  ${JENKINS_CHART_REPO_URL}"

    helm pull "$JENKINS_CHART_NAME" \
        --repo "$JENKINS_CHART_REPO_URL" \
        --version "$JENKINS_CHART_VERSION" \
        --destination "$tmpdir" >/dev/null \
        || fail "could not download chart ${JENKINS_CHART_NAME} ${JENKINS_CHART_VERSION} from ${JENKINS_CHART_REPO_URL}."

    JENKINS_CHART_TGZ="${tmpdir}/${JENKINS_CHART_NAME}-${JENKINS_CHART_VERSION}.tgz"
    [[ -f "$JENKINS_CHART_TGZ" ]] \
        || fail "expected chart archive not found after download: ${JENKINS_CHART_TGZ}"

    actual="$(sha256sum "$JENKINS_CHART_TGZ" | cut -d' ' -f1)"
    expected="$JENKINS_CHART_SHA256"

    if [[ "$actual" != "$expected" ]]; then
        fail "chart checksum mismatch - refusing to continue.
       expected: ${expected}
       actual:   ${actual}
       The pinned artifact is not what was published under this version.
       Do not work around this; establish why the artifact changed."
    fi

    info "sha256 verified: ${actual}"
    export JENKINS_CHART_TGZ
}

# Is the Helm release present in the namespace?
release_exists() {
    helm status "$JENKINS_RELEASE_NAME" -n "$JENKINS_NAMESPACE" >/dev/null 2>&1
}
