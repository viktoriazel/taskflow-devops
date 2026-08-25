#!/usr/bin/env bash
#
# create-jobs.sh - create or update the two pipeline jobs from this repository.
#
# The definitions live in jenkins/jcasc/jobs.yaml and reach the controller
# through the reconciliation configure-jenkins.sh already performs, so there is
# one path into Jenkins rather than a second one that exists only for jobs.
# What this script adds around that path is the part specific to jobs:
#
#   - the pipeline files a job points at must be reachable in the remote branch,
#     because the job loads them from there and not from this working copy;
#   - the configuration reload has to have run before the jobs exist;
#   - the jobs are then read back from the controller and checked.
#
# Safe to re-run. The definitions are regenerated on every reload, so a second
# run updates the same two jobs instead of creating more.
#
# No Jenkins credential is used or created: the jobs are applied as
# configuration and read back from the controller's filesystem with kubectl.
#
# Dependencies: kubectl, helm, sha256sum, git.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/jenkins-common.sh
source "${SCRIPT_DIR}/jenkins-common.sh"

DRY_RUN=false
JOB_WAIT_SECONDS="${JOB_WAIT_SECONDS:-180}"

# The two canonical jobs, as jobname:pipelinefile. Both halves are checked
# against jenkins/jcasc/jobs.yaml before anything is applied and against the
# controller afterwards, so a rename on one side cannot pass unnoticed.
JOB_DEFINITIONS=(
    "ci-application:ci-Jenkinsfile"
    "application-cd:cd-Jenkinsfile"
)

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--dry-run] [-h|--help]

Applies the pipeline job definitions in jenkins/jcasc/jobs.yaml to the running
Jenkins and verifies that both jobs exist afterwards:

  ci-application   -> ci-Jenkinsfile
  application-cd   -> cd-Jenkinsfile

Options:
  --dry-run   Run every check and render the reconciliation without changing
              the cluster. No job is created or updated.
  -h, --help  Show this help.

Environment:
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to touch.
                         Default: taskflow-dev-eks
  JOB_WAIT_SECONDS       How long to wait for the configuration reload to
                         produce the jobs. Default: 180

Exit codes: 0 ok, 1 error, 2 usage.

The jobs read their pipeline from the remote branch named in
jenkins/jcasc/jobs.yaml, so both pipeline files must be committed and pushed to
that branch first. This script refuses to run otherwise, rather than creating a
job that cannot load.
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

require_commands kubectl helm sha256sum git
load_chart_env
require_repo_files "$VALUES_FILE" "$JOBS_FILE"

info "repo root: ${REPO_ROOT}"
info "release:   ${JENKINS_RELEASE_NAME} (namespace ${JENKINS_NAMESPACE})"
[[ "$DRY_RUN" == true ]] && info "mode:      dry run - the cluster will not be changed"

require_expected_cluster

# The reconciliation only ships the JCasC files listed in jenkins-common.sh.
# Without this entry the run below would succeed and change nothing, which is
# the one failure mode of this script that would otherwise look like success.
jobs_shipped=false
for entry in "${JCASC_FILES[@]}"; do
    [[ "${entry#*:}" == "$(basename "$JOBS_FILE")" ]] && jobs_shipped=true
done
[[ "$jobs_shipped" == true ]] \
    || fail "$(basename "$JOBS_FILE") is not listed in JCASC_FILES in jenkins-common.sh.
       The job definitions would not be sent to the controller. Add the entry
       there, or this script has nothing to apply."

# --------------------------------------------------------------------------
# Job definitions
#
# The SCM coordinates are read out of the definitions rather than repeated
# here, so this script cannot check one repository while Jenkins uses another.
# --------------------------------------------------------------------------

step "Job definitions"

SCM_URL="$(sed -n "s/^[[:space:]]*String[[:space:]]\+repositoryUrl[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$JOBS_FILE" | head -n 1)"
SCM_BRANCH="$(sed -n "s/^[[:space:]]*String[[:space:]]\+scmBranch[[:space:]]*=[[:space:]]*'\([^']*\)'.*/\1/p" "$JOBS_FILE" | head -n 1)"

[[ -n "$SCM_URL" && -n "$SCM_BRANCH" ]] \
    || fail "could not read repositoryUrl and scmBranch from ${JOBS_FILE}.
       They are the single place either is set; restore them, or update the
       patterns in this script if the definitions were restructured."

info "repository: ${SCM_URL}"
info "branch:     ${SCM_BRANCH}"

for entry in "${JOB_DEFINITIONS[@]}"; do
    job_name="${entry%%:*}"
    job_file="${entry#*:}"

    grep -qF "pipelineJob('${job_name}')" "$JOBS_FILE" \
        || fail "${JOBS_FILE} does not define the job '${job_name}'."
    grep -qF "scriptPath('${job_file}')" "$JOBS_FILE" \
        || fail "${JOBS_FILE} does not point any job at '${job_file}'."

    info "defined: ${job_name} <- ${job_file}"
done

# The definitions describe an anonymous checkout of a public repository. A
# credential reference appearing here would mean that changed.
if grep -qE 'credentialsId|password' "$JOBS_FILE"; then
    fail "${JOBS_FILE} references a credential.
       The jobs are defined for anonymous checkout; a credential belongs in the
       Jenkins credentials store, never in a file that is committed."
fi

# --------------------------------------------------------------------------
# Pipeline files in the remote branch
#
# A Pipeline job loads its Jenkinsfile from the remote, so a file that exists
# only in this working copy produces a job that is created and then fails on
# every build. The question is what Jenkins can read now, and a remote-tracking
# ref only records what this checkout last happened to see, so the branch is
# fetched from the remote before it is examined.
#
# The refspec names one branch: no other ref is updated, no tag is fetched, and
# the index and working tree are left untouched.
# --------------------------------------------------------------------------

step "Pipeline files in the remote branch"

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || fail "${REPO_ROOT} is not a Git checkout, so the remote branch cannot be checked."

SCM_REMOTE=""
while read -r remote_name remote_url; do
    if [[ "$remote_url" == "$SCM_URL" ]]; then
        SCM_REMOTE="$remote_name"
        break
    fi
done < <(git -C "$REPO_ROOT" remote -v | awk '$3 == "(fetch)" { print $1, $2 }')

[[ -n "$SCM_REMOTE" ]] \
    || fail "no Git remote in ${REPO_ROOT} fetches from ${SCM_URL}.
       That is the repository the jobs are defined against, so this checkout
       cannot confirm what it contains."

REMOTE_REF="refs/remotes/${SCM_REMOTE}/${SCM_BRANCH}"

# Anonymous, like the checkout the jobs perform. The terminal prompt is off so
# an unreachable or non-public repository fails here rather than blocking on a
# credential this installation does not have. The update is forced because what
# matters is the branch as it stands now: a rewritten history is still readable
# by Jenkins, and refusing it here would only enforce a history policy that is
# not this guard's business.
GIT_TERMINAL_PROMPT=0 git -C "$REPO_ROOT" fetch --quiet --no-tags "$SCM_REMOTE" \
    "+refs/heads/${SCM_BRANCH}:${REMOTE_REF}" \
    || fail "could not fetch branch '${SCM_BRANCH}' from remote '${SCM_REMOTE}'.
       It may not exist there, or ${SCM_URL} may be unreachable.
       Nothing has been applied: the jobs would point at a branch Jenkins
       cannot read."

git -C "$REPO_ROOT" rev-parse --verify --quiet "$REMOTE_REF" >/dev/null \
    || fail "the fetch of '${SCM_BRANCH}' from '${SCM_REMOTE}' left no ref at ${REMOTE_REF}."

info "remote:  ${SCM_REMOTE} (${SCM_URL})"
info "fetched: ${REMOTE_REF} at $(git -C "$REPO_ROOT" rev-parse --short "$REMOTE_REF")"

for entry in "${JOB_DEFINITIONS[@]}"; do
    job_name="${entry%%:*}"
    job_file="${entry#*:}"

    git -C "$REPO_ROOT" cat-file -e "${REMOTE_REF}:${job_file}" 2>/dev/null \
        || fail "'${job_file}' is not present on ${SCM_REMOTE}/${SCM_BRANCH}.
       Job '${job_name}' would be created and then fail on every build, because
       it loads that file from the remote and not from this working copy.
       Commit and push it to that branch first."

    info "present: ${job_file} on ${SCM_REMOTE}/${SCM_BRANCH}"
done

# --------------------------------------------------------------------------
# The release must already exist
# --------------------------------------------------------------------------

step "Existing release"

release_exists \
    || fail "no Helm release '${JENKINS_RELEASE_NAME}' in namespace '${JENKINS_NAMESPACE}'.
       Jobs are created inside a running Jenkins. To create one, run:
         ${SCRIPT_DIR}/install-jenkins.sh"

# --------------------------------------------------------------------------
# Reconcile
#
# Delegated rather than repeated: configure-jenkins.sh is the one mechanism
# that puts this repository's configuration into the controller, and the job
# definitions are part of that configuration.
# --------------------------------------------------------------------------

step "Reconcile"

if [[ "$DRY_RUN" == true ]]; then
    "${SCRIPT_DIR}/configure-jenkins.sh" --dry-run
    step "Dry run complete"
    info "no job was created or changed"
    exit 0
fi

"${SCRIPT_DIR}/configure-jenkins.sh"

# --------------------------------------------------------------------------
# Configuration reload
#
# The sidecar notices the changed JCasC ConfigMap and asks the controller to
# reload; the jobs exist once that has happened. Polled instead of assumed, so
# the verification below cannot report an absence that is only a race.
# --------------------------------------------------------------------------

step "Configuration reload"

POD="$(kubectl get pods -n "$JENKINS_NAMESPACE" \
    -l "app.kubernetes.io/component=jenkins-controller" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

[[ -n "$POD" ]] \
    || fail "no controller Pod found in namespace '${JENKINS_NAMESPACE}'."

info "controller Pod: ${POD}"

job_config_path() { printf '/var/jenkins_home/jobs/%s/config.xml' "$1"; }

deadline=$(( SECONDS + JOB_WAIT_SECONDS ))
while :; do
    pending=()
    for entry in "${JOB_DEFINITIONS[@]}"; do
        job_name="${entry%%:*}"
        kubectl exec "$POD" -n "$JENKINS_NAMESPACE" -c jenkins -- \
            test -f "$(job_config_path "$job_name")" >/dev/null 2>&1 \
            || pending+=("$job_name")
    done

    (( ${#pending[@]} == 0 )) && break

    (( SECONDS < deadline )) \
        || fail "still missing after ${JOB_WAIT_SECONDS}s: ${pending[*]}
       The configuration was applied but the controller did not create the
       jobs. Look at the reload for the reason:
         kubectl logs ${POD} -n ${JENKINS_NAMESPACE} -c jenkins | grep -i casc
         kubectl logs ${POD} -n ${JENKINS_NAMESPACE} -c config-reload"

    sleep 5
done

info "reload complete"

# --------------------------------------------------------------------------
# Verification
#
# Read back from the controller rather than from this repository, so what is
# reported is the configuration actually in force.
# --------------------------------------------------------------------------

step "Jobs"

FAILURES=0
ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }

for entry in "${JOB_DEFINITIONS[@]}"; do
    job_name="${entry%%:*}"
    job_file="${entry#*:}"

    if ! config="$(kubectl exec "$POD" -n "$JENKINS_NAMESPACE" -c jenkins -- \
            cat "$(job_config_path "$job_name")" 2>/dev/null)"; then
        bad "${job_name}: configuration could not be read from the controller"
        continue
    fi

    ok "${job_name}: exists"

    for expected in "<scriptPath>${job_file}</scriptPath>" \
                    "<url>${SCM_URL}</url>" \
                    "<name>*/${SCM_BRANCH}</name>"; do
        if grep -qF "$expected" <<< "$config"; then
            ok "${job_name}: ${expected}"
        else
            bad "${job_name}: expected ${expected} in its configuration"
        fi
    done
done

# Anything else under jobs/ was not created by this repository. Reported rather
# than removed: this script owns the two jobs above and nothing more.
others="$(kubectl exec "$POD" -n "$JENKINS_NAMESPACE" -c jenkins -- \
    sh -c 'ls -1 /var/jenkins_home/jobs 2>/dev/null' 2>/dev/null || true)"

# shellcheck disable=SC2086  # split on whitespace: one job name per line.
for name in $others; do
    known=false
    for entry in "${JOB_DEFINITIONS[@]}"; do
        [[ "${entry%%:*}" == "$name" ]] && known=true
    done
    [[ "$known" == true ]] || warn "job '${name}' exists on the controller but is not defined in this repository."
done

# --------------------------------------------------------------------------
# Result
# --------------------------------------------------------------------------

if (( FAILURES > 0 )); then
    printf '\n%d check(s) failed.\n' "$FAILURES" >&2
    exit 1
fi

step "Jobs are in place"
info "Check the rest of the installation with ${SCRIPT_DIR}/verify-jenkins.sh"
