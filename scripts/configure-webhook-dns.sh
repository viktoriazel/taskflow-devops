#!/usr/bin/env bash
#
# configure-webhook-dns.sh - manage the public Route 53 A alias for the Jenkins
# webhook endpoint.
#
# This is the only public name Jenkins has. It points at the load balancer the
# webhook Ingress created, which publishes one path and accepts traffic only
# from GitHub's hook ranges. The Jenkins UI is not published under it, or under
# any other name; it stays reachable through kubectl port-forward.
#
# Same shape as configure-app-dns.sh: the hostname comes from the Ingress
# manifest in Git, while the load balancer and the hosted zone are looked up at
# run time, because the AWS Load Balancer Controller creates the load balancer
# and it is not a Terraform output.
#
# An existing record is never overwritten, and deletion needs an exact match to
# the live load balancer. Anything else is reported and left alone.
#
# Dependencies: kubectl, aws.

set -euo pipefail

# --------------------------------------------------------------------------
# Constants and configuration
# --------------------------------------------------------------------------

# Resolve paths relative to the script so execution does not depend on CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INGRESS_MANIFEST="${REPO_ROOT}/jenkins/webhook-ingress.yaml"

NAMESPACE="jenkins"
INGRESS_NAME="jenkins-webhook"

AWS_REGION="${AWS_REGION:-eu-north-1}"

# Refuse to run against an unexpected cluster; overridable for another
# environment built from the same configuration.
EXPECTED_CLUSTER_NAME="${EXPECTED_CLUSTER_NAME:-taskflow-dev-eks}"

MODE=""
DRY_RUN=false

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

info()   { printf '  %s\n' "$*"; }
step()   { printf '\n==> %s\n' "$*"; }
warn()   { printf 'WARNING: %s\n' "$*" >&2; }
fail()   { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 3; }

# --------------------------------------------------------------------------
# Load balancer discovery and alias matching
#
# One lookup and one matching rule, used by every mode.
# --------------------------------------------------------------------------

ALB_DNS=""
ALB_ZONE_ID=""
ALB_ARN=""
ALB_LOOKUP_ERROR=""

# Route 53 stores the alias target as a FQDN, sometimes with a dualstack.
# prefix, while the Ingress reports a bare hostname, so both are normalized
# before they are compared. The hosted zone id is compared exactly.
normalize_alb_dns() {
    local name="${1,,}"
    name="${name%.}"
    name="${name#dualstack.}"
    printf '%s' "$name"
}

# Returns 0 with ALB_DNS / ALB_ZONE_ID / ALB_ARN filled, or 1 with
# ALB_LOOKUP_ERROR set; the caller decides what that means.
resolve_live_alb() {
    local address row

    ALB_DNS=""
    ALB_ZONE_ID=""
    ALB_ARN=""
    ALB_LOOKUP_ERROR=""

    address="$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

    if [[ -z "$address" ]]; then
        ALB_LOOKUP_ERROR="Ingress '${INGRESS_NAME}' in namespace '${NAMESPACE}' has no load balancer address.
       Either it does not exist in this cluster, or the controller has not
       finished provisioning one."
        return 1
    fi

    # Matching the exact DNS name gives the canonical hosted zone id and proves
    # the load balancer is in this account and region.
    row="$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?DNSName=='${address}'].[DNSName,CanonicalHostedZoneId,LoadBalancerArn]" \
        --output text)"

    if [[ -z "$row" ]]; then
        ALB_LOOKUP_ERROR="no load balancer in ${AWS_REGION} has DNS name '${address}'.
       The cluster and the Elastic Load Balancing API disagree, which usually
       means the wrong region or the wrong AWS account."
        return 1
    fi

    if (( $(wc -l <<< "$row") != 1 )); then
        ALB_LOOKUP_ERROR="more than one load balancer in ${AWS_REGION} reports DNS name '${address}'."
        return 1
    fi

    read -r ALB_DNS ALB_ZONE_ID ALB_ARN <<< "$row"

    if [[ -z "$ALB_ZONE_ID" || "$ALB_ZONE_ID" == "None" ]]; then
        ALB_LOOKUP_ERROR="load balancer '${address}' reports no canonical hosted zone id."
        return 1
    fi

    return 0
}

# Both halves of the alias target must match. This only answers where the record
# points; whether it may be touched at all is decided by CURRENT_UNMANAGED.
alias_matches_live_alb() {
    [[ -n "$CURRENT_ALIAS_DNS" && "$CURRENT_ALIAS_DNS" != "None" ]] || return 1
    [[ "$(normalize_alb_dns "$CURRENT_ALIAS_DNS")" == "$(normalize_alb_dns "$ALB_DNS")" ]] || return 1
    [[ "$CURRENT_ALIAS_ZONE" == "$ALB_ZONE_ID" ]] || return 1
    return 0
}

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") <apply|delete|status> [--dry-run] [-h|--help]

Manages the public DNS A record for the Jenkins webhook endpoint, as an alias to
the load balancer the webhook Ingress created.

Modes:
  apply     Create the alias record if the name is free, and report it as
            already configured if it is the intended alias. Anything else is
            refused, never overwritten.
  delete    Remove the alias record, but only if it points at the load balancer
            this cluster's webhook Ingress currently uses.
  status    Report the current record and whether it matches the live load
            balancer. Read-only.

Options:
  --dry-run   Resolve and report everything, print the change that would be
              made, and stop without submitting a Route 53 change.
  -h, --help  Show this help.

Environment:
  AWS_REGION             Region holding the load balancer. Default: eu-north-1
  EXPECTED_CLUSTER_NAME  Cluster the script is allowed to read.
                         Default: taskflow-dev-eks

Exit codes: 0 ok, 1 error, 2 usage, 3 refused by a safety guard.

The hostname is read from jenkins/webhook-ingress.yaml, so DNS stays in step
with the Ingress definition in Git.

This name publishes the webhook path alone. Before creating it, confirm the
load balancer still accepts only GitHub's ranges:
  ${SCRIPT_DIR}/check-webhook-cidrs.sh
EOF
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        apply|delete|status)
            [[ -z "$MODE" ]] \
                || { printf 'ERROR: more than one mode given: %s and %s\n\n' "$MODE" "$1" >&2
                     usage >&2
                     exit 2; }
            MODE="$1"
            ;;
        --dry-run)  DRY_RUN=true ;;
        -h|--help)  usage; exit 0 ;;
        *)          printf 'ERROR: unknown argument: %s\n\n' "$1" >&2
                    usage >&2
                    exit 2 ;;
    esac
    shift
done

[[ -n "$MODE" ]] \
    || { printf 'ERROR: no mode given.\n\n' >&2; usage >&2; exit 2; }

if [[ "$DRY_RUN" == true && "$MODE" == "status" ]]; then
    info "status is read-only; --dry-run has no effect on it"
fi

# --------------------------------------------------------------------------
# Preflight: tooling
# --------------------------------------------------------------------------

step "Checking tooling"

for cmd in kubectl aws; do
    command -v "$cmd" >/dev/null 2>&1 \
        || fail "${cmd} not found in PATH."
done

if (( BASH_VERSINFO[0] < 4 )); then
    fail "bash 4 or newer is required (found ${BASH_VERSION})."
fi

[[ -f "$INGRESS_MANIFEST" ]] \
    || fail "webhook Ingress manifest not found at ${INGRESS_MANIFEST}. Run this script from a full checkout of the repository."

info "repo root: ${REPO_ROOT}"
info "region:    ${AWS_REGION}"

# --------------------------------------------------------------------------
# Preflight: cluster identity
#
# The load balancer is found through the cluster, so the wrong cluster would put
# the wrong load balancer behind the right hostname.
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

# The cluster may appear as a bare name or as an ARN ending in that name.
if [[ "$CURRENT_CLUSTER" != "$EXPECTED_CLUSTER_NAME" && "$CURRENT_CLUSTER" != */"$EXPECTED_CLUSTER_NAME" ]]; then
    fail "active cluster '${CURRENT_CLUSTER}' is not '${EXPECTED_CLUSTER_NAME}'.
       Refusing to touch DNS for a cluster this repository does not describe.
       Switch context, or set EXPECTED_CLUSTER_NAME if this is intentional."
fi

info "cluster matches - continuing"

# --------------------------------------------------------------------------
# The hostname
#
# Taken from the manifest in Git, not the live Ingress, so it also works before
# the Ingress is applied.
# --------------------------------------------------------------------------

step "Webhook hostname"

WEBHOOK_HOST="$(sed -n 's/^[[:space:]]*-[[:space:]]*host:[[:space:]]*\([^[:space:]#]*\).*/\1/p' \
    "$INGRESS_MANIFEST" | head -n 1)"

[[ -n "$WEBHOOK_HOST" ]] \
    || fail "no rule host found in ${INGRESS_MANIFEST}.
       That file is where the published hostname is defined; add it there
       first, or update the pattern in this script if the manifest was
       restructured."

info "hostname: ${WEBHOOK_HOST}"

# --------------------------------------------------------------------------
# The hosted zone
#
# Matched by longest suffix, so the record lands in the most specific zone that
# covers the hostname. Two zones with the same name are ambiguous, so the script
# refuses instead of guessing.
# --------------------------------------------------------------------------

step "Hosted zone"

ZONE_ID=""
ZONE_NAME=""
ZONE_MATCHES=0

while read -r zone_name zone_id; do
    [[ -n "$zone_name" ]] || continue
    zone_name="${zone_name%.}"

    [[ "$WEBHOOK_HOST" == "$zone_name" || "$WEBHOOK_HOST" == *".${zone_name}" ]] || continue

    if (( ${#zone_name} > ${#ZONE_NAME} )); then
        ZONE_NAME="$zone_name"
        ZONE_ID="${zone_id##*/}"
        ZONE_MATCHES=1
    elif [[ "$zone_name" == "$ZONE_NAME" ]]; then
        ZONE_MATCHES=$(( ZONE_MATCHES + 1 ))
    fi
done < <(aws route53 list-hosted-zones \
    --query 'HostedZones[?Config.PrivateZone==`false`].[Name,Id]' \
    --output text)

[[ -n "$ZONE_ID" ]] \
    || fail "no public Route 53 hosted zone covers '${WEBHOOK_HOST}'.
       The zone is managed outside this repository and is not created here."

(( ZONE_MATCHES == 1 )) \
    || refuse "${ZONE_MATCHES} public hosted zones are named '${ZONE_NAME}'.
       Which one serves '${WEBHOOK_HOST}' depends on the domain's delegation,
       not on this script. Resolve the duplicate before writing any record."

info "zone: ${ZONE_NAME} (${ZONE_ID})"

# --------------------------------------------------------------------------
# The current record
#
# Read in every mode. More than the alias target is queried, because a record
# can carry routing or health configuration this script never writes.
# SetIdentifier comes last because it is free text and may contain spaces.
# --------------------------------------------------------------------------

step "Current record"

CURRENT_ALIAS_DNS=""
CURRENT_ALIAS_ZONE=""
CURRENT_ALIAS_HEALTH=""
CURRENT_TRAFFIC_POLICY=""
CURRENT_HEALTH_CHECK=""
CURRENT_SET_ID=""

# Non-empty when the record is a shape this script must not create or remove.
CURRENT_UNMANAGED=""

current_row="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --query "ResourceRecordSets[?Name=='${WEBHOOK_HOST}.' && Type=='A'].[AliasTarget.DNSName,AliasTarget.HostedZoneId,AliasTarget.EvaluateTargetHealth,TrafficPolicyInstanceId,HealthCheckId,SetIdentifier]" \
    --output text)"

if [[ -n "$current_row" ]]; then
    # More than one row means a routing policy this repository never creates.
    (( $(wc -l <<< "$current_row") == 1 )) \
        || refuse "${WEBHOOK_HOST} has more than one A record in ${ZONE_NAME}.
       That is a routing policy this script did not create and cannot safely
       reason about. Inspect the zone and resolve it deliberately."

    read -r CURRENT_ALIAS_DNS CURRENT_ALIAS_ZONE CURRENT_ALIAS_HEALTH \
            CURRENT_TRAFFIC_POLICY CURRENT_HEALTH_CHECK CURRENT_SET_ID <<< "$current_row"

    info "A ${WEBHOOK_HOST} -> ${CURRENT_ALIAS_DNS}"

    # One row is not proof of simple routing: a weighted, latency, failover or
    # geolocation record also returns one row, marked by its SetIdentifier.
    if [[ -n "$CURRENT_SET_ID" && "$CURRENT_SET_ID" != "None" ]]; then
        CURRENT_UNMANAGED="it carries a SetIdentifier ('${CURRENT_SET_ID}'), so it belongs to a
       weighted, latency, failover or geolocation routing policy"

    elif [[ -n "$CURRENT_TRAFFIC_POLICY" && "$CURRENT_TRAFFIC_POLICY" != "None" ]]; then
        CURRENT_UNMANAGED="it belongs to Route 53 Traffic Flow (traffic policy instance
       ${CURRENT_TRAFFIC_POLICY}) and has to be managed through that policy instance"

    elif [[ -n "$CURRENT_HEALTH_CHECK" && "$CURRENT_HEALTH_CHECK" != "None" ]]; then
        CURRENT_UNMANAGED="it references health check ${CURRENT_HEALTH_CHECK}, which this script
       neither creates nor manages"
    fi
else
    info "no A record for ${WEBHOOK_HOST}"
fi

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------

if [[ "$MODE" == "status" ]]; then
    step "Summary"

    if [[ -z "$CURRENT_ALIAS_DNS" ]]; then
        info "${WEBHOOK_HOST} has no A record; GitHub cannot reach the webhook endpoint under that name"
        exit 0
    fi

    if [[ -n "$CURRENT_UNMANAGED" ]]; then
        warn "${WEBHOOK_HOST} is outside this script's scope: ${CURRENT_UNMANAGED}"
    fi

    if [[ "$CURRENT_ALIAS_DNS" == "None" ]]; then
        warn "${WEBHOOK_HOST} has an A record that is not an alias; this script did not create it"
        exit 0
    fi

    info "${WEBHOOK_HOST} is an alias to ${CURRENT_ALIAS_DNS}"
    info "target zone: ${CURRENT_ALIAS_ZONE}"

    if resolve_live_alb; then
        if alias_matches_live_alb; then
            info "matches the load balancer the webhook Ingress currently uses"
        else
            warn "does NOT match the load balancer the webhook Ingress currently uses (${ALB_DNS})"
        fi
    else
        info "could not compare against the live load balancer: ${ALB_LOOKUP_ERROR%%$'\n'*}"
    fi

    exit 0
fi

# --------------------------------------------------------------------------
# Scope
#
# Checked before the load balancer lookup: a matching alias target does not make
# a record with extra configuration safe to create or remove from here.
# --------------------------------------------------------------------------

[[ -z "$CURRENT_UNMANAGED" ]] \
    || refuse "${WEBHOOK_HOST} is not managed by this script: ${CURRENT_UNMANAGED}.
       Neither creating nor removing it is safe from here. Resolve it
       deliberately in Route 53."

# --------------------------------------------------------------------------
# The live load balancer
#
# Both remaining modes need it: apply as the target to point at, delete as the
# record it must match exactly.
# --------------------------------------------------------------------------

step "Load balancer"

if ! resolve_live_alb; then
    if [[ "$MODE" == "delete" ]]; then
        refuse "${ALB_LOOKUP_ERROR}
       Without it there is nothing to check the existing record against, so the
       DNS record is not removed automatically."
    fi
    fail "${ALB_LOOKUP_ERROR}
       There is nothing to point DNS at until the Ingress has a load balancer."
fi

info "dns name:       ${ALB_DNS}"
info "canonical zone: ${ALB_ZONE_ID}"
info "load balancer:  ${ALB_ARN##*/}"

CHANGE_FILE="$(mktemp)"
trap 'rm -f "${CHANGE_FILE}"' EXIT

# --------------------------------------------------------------------------
# apply
#
# Three outcomes: create when the name is free, leave the intended alias alone,
# refuse anything else. An existing record is never rewritten.
# --------------------------------------------------------------------------

if [[ "$MODE" == "apply" ]]; then
    step "Deciding what to do"

    if [[ -z "$CURRENT_ALIAS_DNS" ]]; then
        info "the name is free - creating the alias"

    elif [[ "$CURRENT_ALIAS_DNS" == "None" ]]; then
        refuse "${WEBHOOK_HOST} already has an A record that is not an alias.
       This script did not create it and does not overwrite it. Remove or
       repoint it deliberately first."

    elif alias_matches_live_alb; then
        step "Already configured"
        info "${WEBHOOK_HOST} is already the intended alias to ${ALB_DNS}"
        info "no change required"
        exit 0

    else
        refuse "${WEBHOOK_HOST} already points at a different target.
       record: ${CURRENT_ALIAS_DNS} (zone ${CURRENT_ALIAS_ZONE})
       live:   ${ALB_DNS}. (zone ${ALB_ZONE_ID})
       Only this cluster's own webhook load balancer is managed here. Establish
       what that record belongs to before repointing it."
    fi

    # CREATE, not UPSERT: if a record appeared since the read above, Route 53
    # rejects the batch instead of overwriting it. EvaluateTargetHealth is off;
    # health-based routing is out of scope here.
    step "Submitting CREATE"

    cat >"$CHANGE_FILE" <<EOF
{
  "Comment": "Jenkins webhook endpoint",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "${WEBHOOK_HOST}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ALB_ZONE_ID}",
          "DNSName": "${ALB_DNS}.",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOF

    if [[ "$DRY_RUN" == true ]]; then
        info "dry run - the change below was not submitted"
        cat "$CHANGE_FILE"
        step "Dry run complete"
        exit 0
    fi

    aws route53 change-resource-record-sets \
        --hosted-zone-id "$ZONE_ID" \
        --change-batch "file://${CHANGE_FILE}" \
        --query 'ChangeInfo.[Id,Status]' \
        --output text \
        || fail "Route 53 rejected the change.
       If the name was taken between the read and this write, that is the
       guard working: re-run to see what is there now."

    step "Applied"
    info "${WEBHOOK_HOST} -> ${ALB_DNS}"
    info "Propagation takes a moment; check with: $(basename "${BASH_SOURCE[0]}") status"
    exit 0
fi

# --------------------------------------------------------------------------
# delete
#
# The record is removed only if it is a simple alias pointing at the load
# balancer the live webhook Ingress uses. Anything else is reported and left
# alone.
# --------------------------------------------------------------------------

step "Checking the record is safe to remove"

[[ -n "$CURRENT_ALIAS_DNS" ]] \
    || { info "no A record for ${WEBHOOK_HOST}; nothing to delete"; exit 0; }

[[ "$CURRENT_ALIAS_DNS" != "None" ]] \
    || refuse "the A record for ${WEBHOOK_HOST} is not an alias.
       This script only removes an alias to the webhook load balancer, and did
       not create whatever this is. Remove it deliberately instead."

alias_matches_live_alb \
    || refuse "the A record for ${WEBHOOK_HOST} does not point at the webhook load balancer.
       record: ${CURRENT_ALIAS_DNS} (zone ${CURRENT_ALIAS_ZONE})
       live:   ${ALB_DNS}. (zone ${ALB_ZONE_ID})
       Only the load balancer the webhook Ingress currently uses is removed
       here. Establish what this record belongs to before deleting it."

info "alias matches the live webhook load balancer - removable"

# Route 53 deletes by exact match, so the batch is rebuilt from what was just
# read. The scope guard above already ruled out the fields it does not carry.
if [[ "$CURRENT_ALIAS_HEALTH" == "True" ]]; then
    health_json=true
else
    health_json=false
fi

cat >"$CHANGE_FILE" <<EOF
{
  "Comment": "Remove Jenkins webhook endpoint",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${WEBHOOK_HOST}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${CURRENT_ALIAS_ZONE}",
          "DNSName": "${CURRENT_ALIAS_DNS}",
          "EvaluateTargetHealth": ${health_json}
        }
      }
    }
  ]
}
EOF

if [[ "$DRY_RUN" == true ]]; then
    info "dry run - the change below was not submitted"
    cat "$CHANGE_FILE"
    step "Dry run complete"
    exit 0
fi

step "Deleting A alias"

aws route53 change-resource-record-sets \
    --hosted-zone-id "$ZONE_ID" \
    --change-batch "file://${CHANGE_FILE}" \
    --query 'ChangeInfo.[Id,Status]' \
    --output text \
    || fail "Route 53 rejected the change."

step "Deleted"
info "${WEBHOOK_HOST} no longer resolves to the webhook load balancer"
