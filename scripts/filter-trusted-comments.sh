#!/bin/bash
set -euo pipefail

# Shared trust-filter helper for untrusted comment authors.
#
# Trust set = {OWNER, MEMBER, COLLABORATOR} (GitHub write access). Everything
# else — CONTRIBUTOR, NONE, FIRST_TIME_CONTRIBUTOR, FIRST_TIMER, unknown, empty
# — is untrusted.
#
# Modes:
#   filter-trusted-comments.sh is-trusted-author <association>
#       Low-level primitive. Exit 0 if trusted, 1 if not. Reused by #548/#549.
#
#   filter-trusted-comments.sh <N>
#       Default mode. Single `gh issue view <N> --json body,comments` call.
#       stdout = issue body, then the body of each comment from a trusted
#       author (hard-drop semantics — untrusted comment bytes never reach
#       stdout). stderr = machine-readable audit:
#         ignored <N> comments from untrusted authors: @x, @y
#       Requires PIPELINE_REPO in the environment.

# Trust set, shared by both modes.
TRUSTED_JSON='["OWNER","MEMBER","COLLABORATOR"]'

is_trusted_author() {
  case "${1:-}" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "is-trusted-author" ]; then
  is_trusted_author "${2:-}"
  exit $?
fi

# --- Default mode ---
N="${1:-}"
if [ -z "$N" ]; then
  echo "usage: filter-trusted-comments.sh <issue-number> | is-trusted-author <association>" >&2
  exit 2
fi

JSON=$(gh issue view "$N" --repo "${PIPELINE_REPO:-}" --json body,comments)

# stdout: issue body, then each trusted comment's body. Untrusted comment
# bytes are dropped here and never emitted.
jq -r --argjson trusted "$TRUSTED_JSON" '
  .body,
  (.comments[]? | select(.authorAssociation as $a | $trusted | index($a)) | .body)
' <<<"$JSON"

# stderr: dropped-author audit. Count + comma-separated @logins of comments
# from untrusted authors.
DROPPED=$(jq -r --argjson trusted "$TRUSTED_JSON" '
  [.comments[]? | select(.authorAssociation as $a | ($trusted | index($a)) | not) | "@" + .author.login]
  | (length | tostring) + " comments from untrusted authors: " + (join(", "))
' <<<"$JSON")
echo "ignored $DROPPED" >&2
