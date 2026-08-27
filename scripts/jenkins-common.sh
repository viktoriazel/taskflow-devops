#!/usr/bin/env bash
#
# jenkins-common.sh - shared library sourced by the Jenkins lifecycle scripts.
#
# Holds the validation and verification logic used by install, configure and
# verify, so all three behave the same way.

# This file is a library; running it directly does nothing useful.
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
# Used by the scripts that source this file.
# shellcheck disable=SC2034
NAMESPACE_MANIFEST="${JENKINS_DIR}/namespace.yaml"
# shellcheck disable=SC2034
RBAC_MANIFEST="${JENKINS_DIR}/rbac/controller.yaml"

# Identities and permissions for the dynamic agents, applied before the release
# so every agent Pod has its ServiceAccount. The CD Role is created in the
# application namespace, so that namespace has to exist first.
# shellcheck disable=SC2034
AGENT_RBAC_MANIFESTS=(
    "${JENKINS_DIR}/rbac/agent-serviceaccounts.yaml"
    "${JENKINS_DIR}/rbac/cd-agent-rbac.yaml"
)

# The namespace the CD Role is created in. Not overridable, because
# jenkins/rbac/cd-agent-rbac.yaml names this namespace directly.
APP_NAMESPACE="devops-app"

# --------------------------------------------------------------------------
# JCasC
#
# The Jenkins configuration lives in jenkins/jcasc/*.yaml instead of inside
# values.yaml, so it stays plain YAML. Helm passes each file with --set-file,
# which inserts its contents as a string. The files are listed once here, so
# install and configure cannot drift apart.
#
# Each key also becomes a file name on the controller, so keys use only
# lowercase letters, digits and dashes.
# --------------------------------------------------------------------------

JCASC_DIR="${JENKINS_DIR}/jcasc"

# key:filename
JCASC_FILES=(
    "taskflow-system:system.yaml"
    "taskflow-credentials:credentials.yaml"
    "taskflow-clouds:clouds.yaml"
    "taskflow-github:github.yaml"
    "taskflow-jobs:jobs.yaml"
)

# Named separately because create-jobs.sh also reads the SCM settings from it.
# shellcheck disable=SC2034
JOBS_FILE="${JCASC_DIR}/jobs.yaml"

# Builds the --set-file arguments for the JCasC files above. Fails if a file is
# missing, so Jenkins never starts with only part of its configuration.
JCASC_SET_FILE_ARGS=()

jcasc_set_file_args() {
    local entry key file path
    JCASC_SET_FILE_ARGS=()

    for entry in "${JCASC_FILES[@]}"; do
        key="${entry%%:*}"
        file="${entry#*:}"
        path="${JCASC_DIR}/${file}"
        [[ -f "$path" ]] \
            || fail "JCasC file missing: ${path}
       Jenkins would start without part of its configuration. Restore the file
       or remove its entry from JCASC_FILES in jenkins-common.sh."
        JCASC_SET_FILE_ARGS+=(--set-file "controller.JCasC.configScripts.${key}=${path}")
        info "JCasC: ${key} <- jenkins/jcasc/${file}"
    done
}

# The CD Role is namespaced, so the application namespace must exist first.
require_app_namespace() {
    kubectl get namespace "$APP_NAMESPACE" -o name >/dev/null 2>&1 \
        || fail "namespace '${APP_NAMESPACE}' does not exist.
       The CD agent's Role is created in it. Deploy the application first:
         ${JENKINS_SCRIPT_DIR}/bootstrap-app.sh"
}

# Both Secrets are external prerequisites, created from the templates in
# jenkins/examples/. No script here creates a Secret, and no secret value is
# ever printed.
ADMIN_SECRET_NAME="jenkins-admin"
ADMIN_SECRET_KEYS=(jenkins-admin-user jenkins-admin-password)

# The shared secret for GitHub webhook signatures. jenkins/values.yaml mounts it
# into the controller, so the controller does not start without it.
WEBHOOK_SECRET_NAME="jenkins-github-webhook"
WEBHOOK_SECRET_KEYS=(secret)

# Guard against running in the wrong cluster. Overridable for another
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

# Refuse to run if the current kubectl context points at another cluster.
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

    # The cluster may appear as a bare name or as an ARN ending in that name.
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
# External Secret preflight
#
# Checks that a Secret exists and that every required key is present and not
# empty. The Go template below returns only key names and value lengths, so no
# secret value is ever printed.
#
# Arguments: namespace, Secret name, template file under jenkins/examples/, then
# the required keys.
# --------------------------------------------------------------------------

require_external_secret() {
    local ns="$1" secret_name="$2" example="$3"
    shift 3
    local required_keys=("$@")
    local keys_and_lengths key found_key length found missing=()

    kubectl get secret "$secret_name" -n "$ns" -o name >/dev/null 2>&1 \
        || fail "Secret '${secret_name}' not found in namespace '${ns}'.
       It is created out of band, is deliberately not tracked in Git, and is not
       created by this script. Create it from the template:
         ${JENKINS_DIR}/examples/${example}"

    # Single-quoted so $k and $v stay in the Go template.
    # shellcheck disable=SC2016
    keys_and_lengths="$(kubectl get secret "$secret_name" -n "$ns" \
        -o go-template='{{range $k, $v := .data}}{{$k}} {{len $v}}{{"\n"}}{{end}}')"

    for key in "${required_keys[@]}"; do
        found=false
        while read -r found_key length; do
            [[ "$found_key" == "$key" ]] || continue
            found=true
            (( length > 0 )) || fail "Secret '${secret_name}' has key '${key}' but it is empty."
        done <<< "$keys_and_lengths"
        if [[ "$found" == true ]]; then
            info "key present and non-empty: ${key}"
        else
            missing+=("$key")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        fail "Secret '${secret_name}' is missing required key(s): ${missing[*]}
       The key names the release expects are set in ${VALUES_FILE}."
    fi
}

# Wrappers for the two required Secrets, so call sites read clearly.
require_admin_secret() {
    require_external_secret "$1" "$ADMIN_SECRET_NAME" \
        secret-jenkins-admin.example.yaml "${ADMIN_SECRET_KEYS[@]}"
}

require_webhook_secret() {
    require_external_secret "$1" "$WEBHOOK_SECRET_NAME" \
        secret-github-webhook.example.yaml "${WEBHOOK_SECRET_KEYS[@]}"
}

# --------------------------------------------------------------------------
# Chart artifact verification
#
# Downloads the pinned chart and checks its sha256 against jenkins/chart.env, so
# Helm installs exactly the verified file. --repo is used instead of
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
