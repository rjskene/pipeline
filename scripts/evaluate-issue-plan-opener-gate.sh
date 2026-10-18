#!/usr/bin/env bash
# evaluate-issue-plan-opener-gate.sh — evaluate-issue-plan Step 0a: refuse to
# evaluate an issue whose OPENER lacks write access.
#
# The association comes from the REST endpoint (`gh api .../issues/<N>`);
# `gh issue view --json author` carries no association field. Trust is
# delegated to filter-trusted-comments.sh is-trusted-author — never re-implement
# or widen the tier set here. A refusal posts one triage comment and changes no
# label (unlike refuse-untrusted-opener.sh, which adds `human`).
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-plan-opener-gate.sh" <N>

Resolves the opener's authorAssociation for issue <N> and checks it with
filter-trusted-comments.sh is-trusted-author.
  trusted   -> prints "OPENER=trusted assoc=<A>", rc 0
  untrusted -> posts one triage comment, prints
               "REFUSED: untrusted opener (assoc=<A>) for #<N>; surfaced for
               human triage.", rc 0 — the caller STOPs (no plan fetch, no
               evaluation, no label change)
Env: PIPELINE_REPO.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
N="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

ASSOC=$(gh api repos/"$PIPELINE_REPO"/issues/"$N" --jq '.author_association')
if bash "$SELF_DIR/filter-trusted-comments.sh" is-trusted-author "$ASSOC"; then
  echo "OPENER=trusted assoc=$ASSOC"
  exit 0
fi
gh issue comment "$N" --repo "$PIPELINE_REPO" --body "Untrusted opener (authorAssociation=$ASSOC, no write access): surfacing for human triage. A trusted operator must re-file or vouch before this issue's plan is auto-evaluated. (issue #565)"
echo "REFUSED: untrusted opener (assoc=$ASSOC) for #$N; surfaced for human triage."
exit 0
