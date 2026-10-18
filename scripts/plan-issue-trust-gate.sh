#!/usr/bin/env bash
# plan-issue-trust-gate.sh — plan-issue Step 0a: the opener-association gate.
# The issue BODY is trusted only when its OPENER has write access. Resolves the
# opener's association over REST (`gh issue view --json author` carries none),
# checks it with the single-arg `is-trusted-author` primitive, and routes a
# failure through refuse-untrusted-opener.sh (idempotent triage comment + the
# durable PIPELINE_LABELS_HUMAN label).
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: plan-issue-trust-gate.sh <N>

Prints ONE line and exits:
  OPENER=trusted assoc=<A>   exit 0  (OWNER/MEMBER/COLLABORATOR) — plan the issue
  OPENER=refused assoc=<A>   exit 3  refusal routed through refuse-untrusted-opener.sh
                                     — STOP: no draft, no post-plan.sh, no plan-pending
Env: PIPELINE_REPO (required).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; exit 2 ;; esac
N="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

ASSOC=$(gh api "repos/${PIPELINE_REPO:-}/issues/$N" --jq '.author_association')
if bash "$SELF_DIR/filter-trusted-comments.sh" is-trusted-author "$ASSOC"; then
  echo "OPENER=trusted assoc=$ASSOC"
  exit 0
fi
bash "$SELF_DIR/refuse-untrusted-opener.sh" "$N" "${ASSOC:-NONE}" \
  --context "A trusted operator must re-file or vouch before this issue is auto-planned." >&2
echo "OPENER=refused assoc=$ASSOC"
exit 3
