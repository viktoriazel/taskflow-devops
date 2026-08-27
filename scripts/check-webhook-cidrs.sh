#!/usr/bin/env bash
#
# check-webhook-cidrs.sh - compare the webhook load balancer's source
# restriction against the ranges GitHub currently publishes for its hooks.
#
# The webhook endpoint is the only part of Jenkins reachable from the internet,
# and its Ingress accepts only GitHub's hook ranges. Those ranges are pinned in
# the manifest and GitHub changes them from time to time, so they need checking.
#
# Read-only: it compares and reports, and never edits the manifest or touches
# the cluster. Any difference is an error - a missing range blocks deliveries,
# an extra one keeps the load balancer open to an address GitHub no longer uses.
#
# Only IPv4 is compared, because the load balancer is IPv4-only. GitHub's IPv6
# ranges are printed for information only.
#
# Dependencies: curl, python3.

set -euo pipefail

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INGRESS_MANIFEST="${REPO_ROOT}/jenkins/webhook-ingress.yaml"
CIDR_ANNOTATION="alb.ingress.kubernetes.io/inbound-cidrs"

# GitHub's published list of the addresses its services send traffic from.
GITHUB_META_URL="${GITHUB_META_URL:-https://api.github.com/meta}"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

info() { printf '  %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h|--help]

Compares the IPv4 ranges in the ${CIDR_ANNOTATION}
annotation of jenkins/webhook-ingress.yaml against the "hooks" ranges GitHub
publishes at ${GITHUB_META_URL}.

Read-only: nothing is applied and the manifest is never edited. A difference is
reported with the added and removed ranges, and exits non-zero.

Environment:
  GITHUB_META_URL  Where the published ranges are read from.
                   Default: https://api.github.com/meta

Exit codes: 0 the sets match, 1 they differ or the check could not run,
2 usage.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)         usage >&2; printf '\nUnknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

step "Preflight"

for cmd in curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || fail "${cmd} not found in PATH."
done

[[ -f "$INGRESS_MANIFEST" ]] \
    || fail "webhook Ingress manifest not found at ${INGRESS_MANIFEST}.
       Run this from a full checkout of the repository."

info "manifest: ${INGRESS_MANIFEST#"${REPO_ROOT}/"}"
info "source:   ${GITHUB_META_URL}"

# --------------------------------------------------------------------------
# The pinned ranges
#
# Read from the manifest in Git, not from the live Ingress: the manifest is what
# gets reapplied, so it is what has to be correct.
# --------------------------------------------------------------------------

step "Pinned ranges"

PINNED="$(sed -n "s|^[[:space:]]*${CIDR_ANNOTATION}:[[:space:]]*\([^[:space:]#]*\).*|\1|p" \
    "$INGRESS_MANIFEST" | head -n 1)"

[[ -n "$PINNED" ]] \
    || fail "no ${CIDR_ANNOTATION} annotation found in ${INGRESS_MANIFEST}.
       Without it the load balancer would accept every source address. Restore
       the annotation, or update the pattern here if the manifest was
       restructured."

info "annotation value: ${PINNED}"

# --------------------------------------------------------------------------
# GitHub's published ranges
#
# Downloaded to a file, not piped, so a failed download fails here instead of
# turning into an empty comparison that would look like a match.
# --------------------------------------------------------------------------

step "Published ranges"

META_FILE="$(mktemp)"
# shellcheck disable=SC2064  # expand now: the path must survive the trap.
trap "rm -f '${META_FILE}'" EXIT

curl --silent --show-error --fail --location --max-time 30 \
    --header 'Accept: application/vnd.github+json' \
    --output "$META_FILE" "$GITHUB_META_URL" \
    || fail "could not download ${GITHUB_META_URL}.
       The check is inconclusive, which is treated as a failure: an unverified
       source restriction is not a verified one."

[[ -s "$META_FILE" ]] || fail "${GITHUB_META_URL} returned an empty document."

# --------------------------------------------------------------------------
# Comparison
#
# Both sides are parsed as networks, not compared as text, so order and spelling
# cannot cause a false difference. An entry that does not parse is an error, not
# a skipped line.
# --------------------------------------------------------------------------

step "Comparison"

python3 - "$META_FILE" "$PINNED" <<'PY'
import ipaddress
import json
import sys

meta_path, pinned_raw = sys.argv[1], sys.argv[2]

def parse(values, origin):
    v4, v6 = set(), set()
    for raw in values:
        text = raw.strip()
        if not text:
            continue
        try:
            net = ipaddress.ip_network(text, strict=False)
        except ValueError as exc:
            sys.exit("ERROR: %s contains an entry that is not a network: %r (%s)"
                     % (origin, text, exc))
        (v4 if net.version == 4 else v6).add(net)
    return v4, v6

try:
    with open(meta_path, encoding="utf-8") as handle:
        meta = json.load(handle)
except (OSError, ValueError) as exc:
    sys.exit("ERROR: could not read the published ranges: %s" % exc)

hooks = meta.get("hooks")
if not isinstance(hooks, list) or not hooks:
    sys.exit("ERROR: the published document has no usable 'hooks' list. "
             "The check is inconclusive and is treated as a failure.")

published_v4, published_v6 = parse(hooks, "the published hooks list")
pinned_v4, pinned_v6 = parse(pinned_raw.split(","), "the manifest annotation")

def show(title, nets):
    print("  %s (%d):" % (title, len(nets)))
    for net in sorted(nets, key=lambda n: (n.network_address.packed, n.prefixlen)):
        print("    %s" % net)

show("published IPv4", published_v4)
show("pinned IPv4", pinned_v4)

# The load balancer is IPv4-only, so an IPv6 entry in the manifest would do
# nothing at all.
if pinned_v6:
    print("  the manifest pins IPv6 ranges, which an IPv4-only load balancer "
          "cannot enforce:")
    for net in sorted(pinned_v6, key=lambda n: n.network_address.packed):
        print("    %s" % net)

print("  published IPv6 (%d, reported only - not added, the load balancer is "
      "IPv4-only):" % len(published_v6))
for net in sorted(published_v6, key=lambda n: n.network_address.packed):
    print("    %s" % net)

problems = []

# A /0 entry would allow every source while the annotation still looks set up.
for net in pinned_v4:
    if net.prefixlen == 0:
        problems.append("the manifest pins %s, which allows every source "
                        "address" % net)

if pinned_v6:
    problems.append("the manifest pins IPv6 ranges but the load balancer is "
                    "IPv4-only")

added = published_v4 - pinned_v4
removed = pinned_v4 - published_v4

if added:
    problems.append("GitHub publishes %d IPv4 range(s) the manifest does not "
                    "pin; deliveries from them would be dropped" % len(added))
if removed:
    problems.append("the manifest pins %d IPv4 range(s) GitHub no longer "
                    "publishes; the load balancer accepts sources GitHub does "
                    "not use" % len(removed))

if not problems:
    print()
    print("  the pinned IPv4 set is exactly the published IPv4 set")
    sys.exit(0)

print()
if added:
    show("added by GitHub, missing from the manifest", added)
if removed:
    show("pinned in the manifest, no longer published by GitHub", removed)

print()
for problem in problems:
    print("  - %s" % problem)
print()
print("  The manifest is not edited by this script. Update"
      " jenkins/webhook-ingress.yaml")
print("  deliberately, then reapply it and re-run this check.")
sys.exit(1)
PY

step "Ranges match"
info "the webhook load balancer accepts exactly GitHub's published hook sources"
