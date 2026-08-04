#!/bin/bash
set -euo pipefail

# Shared helper owning the full step-0a untrusted-opener refusal aftermath
# (issue #1196). Both skills/classify-issue/SKILL.md and
# skills/plan-issue/SKILL.md route their 0a refusal branch through this
# helper instead of a bare, unconditional `gh issue comment`.
#
# Usage:
#   refuse-untrusted-opener.sh <issue-number> <association> [--context "<sentence>"]
#
# Behavior:
#   - One `gh issue view <N> --json comments,labels` round-trip serves both
#     the idempotency scan and the label check.
#   - Posts a single triage-request comment UNLESS a trusted-author
#     (OWNER/MEMBER/COLLABORATOR) comment already carries either the legacy
#     wire form (`Untrusted opener (authorAssociation=`) or the
#     `<!-- pipeline:untrusted-opener-triage -->` sentinel — idempotent, so
#     autonomous re-runs never accumulate duplicate triage comments (#1184).
#     A marker from an untrusted author is never honored (anti-spoof).
#   - Applies the durable `${PIPELINE_LABELS_HUMAN:-human}` label when
#     absent, so the issue leaves the "ready" bucket and autonomous runs
#     stop re-selecting it. Skips the edit when already present. A failed
#     `gh issue edit` degrades to `label=failed` on stdout — never a hard
#     error, since the comment (the security-relevant half) already landed.
#   - Emits exactly one machine-readable stdout line:
#       REFUSED: untrusted opener (assoc=<A>) for #<N>; comment=posted|skipped label=applied|already-present|failed
#     Untrusted comment bytes fetched by the idempotency scan are NEVER
#     echoed to stdout.
#   - Exit 0 on the refusal path; exit 2 is reserved for usage errors, and
#     usage errors make no mutating `gh` calls.

SENTINEL='<!-- pipeline:untrusted-opener-triage -->'

usage() {
  echo "usage: refuse-untrusted-opener.sh <issue-number> <association> [--context \"<sentence>\"]" >&2
}

N="${1:-}"
ASSOC="${2:-}"
if [ -z "$N" ] || [ -z "$ASSOC" ]; then
  usage
  exit 2
fi
shift 2

CONTEXT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --context)
      CONTEXT="${2:-}"
      shift 2 2>/dev/null || shift "$#"
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "${PIPELINE_REPO:-}" ]; then
  usage
  exit 2
fi

JSON=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json comments,labels)

# --- idempotency scan: trusted-author-scoped marker match -----------------
ALREADY=$(jq -r --arg legacy 'Untrusted opener (authorAssociation=' --arg sentinel "$SENTINEL" '
  [ .comments[]?
    | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a))
    | select((.body // "" | contains($legacy)) or (.body // "" | contains($sentinel)))
  ] | length > 0
' <<<"$JSON")

if [ "$ALREADY" = "true" ]; then
  COMMENT_STATE="skipped"
else
  BODY="Untrusted opener (authorAssociation=$ASSOC, no write access): surfacing for human triage."
  if [ -n "$CONTEXT" ]; then
    BODY="$BODY $CONTEXT"
  fi
  BODY="$BODY (issue #546)
$SENTINEL"
  gh issue comment "$N" --repo "$PIPELINE_REPO" --body "$BODY" >/dev/null
  COMMENT_STATE="posted"
fi

# --- durable human label ----------------------------------------------------
LBL="${PIPELINE_LABELS_HUMAN:-human}"
HAS_LABEL=$(jq -r --arg l "$LBL" '[.labels[]? | select(.name == $l)] | length > 0' <<<"$JSON")

if [ "$HAS_LABEL" = "true" ]; then
  LABEL_STATE="already-present"
else
  if gh issue edit "$N" --repo "$PIPELINE_REPO" --add-label "$LBL" >/dev/null 2>&1; then
    LABEL_STATE="applied"
  else
    LABEL_STATE="failed"
    echo "WARNING: refuse-untrusted-opener: failed to apply label '$LBL' to issue #$N" >&2
  fi
fi

echo "REFUSED: untrusted opener (assoc=$ASSOC) for #$N; comment=$COMMENT_STATE label=$LABEL_STATE"
exit 0
