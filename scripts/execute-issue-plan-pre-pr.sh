#!/usr/bin/env bash
# execute-issue-plan-pre-pr.sh — execute-issue-plan Step 9a: derive the
# Conventional-Commits PR title, then run the cross-cutting guard aggregator
# (fail-closed on a non-zero exit AND on an INERT cruft arm), in one call.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-issue-plan-pre-pr.sh" <N>

Run from inside the feature worktree (the guards inspect the cwd's branch).
1. Derives the PR title via scripts/derive-pr-title.sh <N>: exit 2 (tracker)
   or any other non-zero exit aborts.
2. Runs scripts/check-cross-cutting-guards.sh once (cruft, config drift,
   namespace, golden-seed, README-anchor) and prints its output; a non-zero
   exit, or an "INERT: check-branch-cruft.sh" line, aborts.
On success the LAST stdout line is PR_TITLE=<title> (exit 0); pass that title
literally to gh pr create --title. Every abort prints an ABORT: line and exits 1.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, CLAUDE_PLUGIN_ROOT (defaults to this repo).
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
N="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"

PR_TITLE=$("${CLAUDE_PLUGIN_ROOT}/scripts/derive-pr-title.sh" "$N")
rc=$?
if [ "$rc" -eq 2 ]; then
  # exit 2 = tracker (epic title or `tracker` label) — these never get PRs.
  echo "ABORT: Issue #$N is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
  exit 1
elif [ "$rc" -ne 0 ]; then
  echo "ABORT: derive-pr-title.sh failed with exit $rc for issue #$N" >&2
  exit 1
fi

# ONE aggregator call: it runs check-branch-cruft.sh and check-config-drift.sh
# internally. Its cruft arm prints "INERT: check-branch-cruft.sh" to stderr
# WITHOUT failing the aggregator, so INERT aborts here too (fail-closed).
GUARD_OUT=$(bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh" 2>&1); GUARD_RC=$?
printf '%s\n' "$GUARD_OUT"
[ "$GUARD_RC" -eq 0 ] \
  || { echo "ABORT: cross-cutting guard failure — cruft path on the branch, undocumented PIPELINE_* drift, or a namespace/golden-seed/README-anchor invariant; see above and fix before opening the PR." >&2; exit 1; }
if printf '%s\n' "$GUARD_OUT" | grep -q 'INERT: check-branch-cruft.sh'; then
  echo "ABORT: the cruft guard went INERT — it did NOT run. Resolve PIPELINE_BASE_BRANCH and re-run from inside the worktree." >&2; exit 1
fi

echo "PR_TITLE=$PR_TITLE"
exit 0
