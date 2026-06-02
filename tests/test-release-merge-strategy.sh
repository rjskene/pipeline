#!/bin/bash
set -euo pipefail
# Regression guard for issue #459: the pipeline's auto-merge commands MUST use
# merge-commits (`gh pr merge ... --merge`), NOT squash (`--squash`). Squash
# collapses staging's per-PR conventional commits into one non-conventional
# release subject on `main`, so release-please emits a single CHANGELOG line
# ("Miscellaneous Chores" / "release: vX.Y.Z") instead of enumerating each
# feat:/fix:. Merge-commits keep the per-PR commits reachable from `main` via
# the merge's second parent, which release-please's commit walker traverses.
#
# SCOPE IS PATTERN-ONLY: this guard matches the COMMAND pattern
# `gh pr merge ... --squash` / `... --merge` only. It deliberately does NOT
# scan for the bare word "squash" — prose references to historical/descriptive
# squash behavior (e.g. evaluate-issue-pr/SKILL.md, fullsend/SKILL.md,
# run/SKILL.md, merge-orchestration.md, process-maps.md) are legitimate and
# must remain untouched (issue #459, Blocker 3).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# #763: the run→status rename moved the `gh pr merge ... --merge` command out of
# the now read-only /pipeline:status skill and DELETED
# skills/run/references/merge-orchestration.md (the merge-orchestration prose
# relocated into skills/fullsend/SKILL.md, already in this list). The remaining
# FILES still each carry a live `gh pr merge ... --merge` command.
FILES=(
  "skills/evaluate-issue-pr/SKILL.md"
  "skills/fullsend/SKILL.md"
  "docs/release-cadence.md"
)

for rel in "${FILES[@]}"; do
  F="$REPO_ROOT/$rel"
  assert "$rel: file exists" "[ -f '$F' ]"
  # No `gh pr merge ... --squash` command anywhere in the file.
  assert "$rel: no 'gh pr merge ... --squash' command" \
    "! grep -qE 'gh pr merge[^|]*--squash' '$F'"
  # At least one `gh pr merge ... --merge` command present.
  assert "$rel: has 'gh pr merge ... --merge' command" \
    "grep -qE 'gh pr merge[^|]*--merge( |\$|[^-])' '$F'"
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
