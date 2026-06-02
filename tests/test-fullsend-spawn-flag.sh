#!/usr/bin/env bash
set -euo pipefail

# Regression guard for issue #750: skills/fullsend/SKILL.md must document the
# `--spawn` flag — the orthogonal transport flag that forces every path's
# execute (Step 6) and PR-eval (Step 7) onto the tmux run-queue instead of the
# inline-foreground default. Pure model-facing prose, so this is a
# phrase-presence guard (mirrors tests/test-create-issues-combine-bias.sh):
# block-scoped via awk to distinguish the Step 6 vs Step 7 branches so a future
# prose refactor that drops a branch fails loudly.

FILE="$(dirname "$0")/../skills/fullsend/SKILL.md"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

fail=0
assert_has() { grep -qiF "$1" "$FILE" || { echo "MISSING: $1"; fail=1; }; }

# (a) argv contract documents the flag.
assert_has "[issue_numbers...] [--manual-merge] [--spawn]"

# (d) negative / default — the bare-fullsend inline default is preserved.
assert_has "When \`--spawn\` is absent"

# (b) Step 6 has the all-paths-run-queue branch. Block-scope to the Step 6
# block so it is distinguished from Step 7. Step 6 starts at the
# "6. **Execute (wave N)" heading and ends at the "6b. " line.
step6="$(awk '/^6\. \*\*Execute \(wave N\)/{f=1} /^6b\. /{f=0} f' "$FILE")"
if [ -z "$step6" ]; then
  echo "VIOLATION: could not locate Step 6 (Execute) block"; fail=1
fi
printf '%s' "$step6" | grep -qiF "When \`--spawn\` is present" || { echo "MISSING (Step 6): When \`--spawn\` is present"; fail=1; }
printf '%s' "$step6" | grep -qiF -- "--spawn" || { echo "MISSING (Step 6): --spawn"; fail=1; }
printf '%s' "$step6" | grep -qiF "all paths" || { echo "MISSING (Step 6): all paths"; fail=1; }
printf '%s' "$step6" | grep -qiF "run-queue" || { echo "MISSING (Step 6): run-queue"; fail=1; }
printf '%s' "$step6" | grep -qiF "inline" || { echo "MISSING (Step 6): inline (negative-default)"; fail=1; }

# Issue #749: now that inline-C is PATH C's execute DEFAULT, --spawn has a LIVE
# effect on C (no longer a no-op) — the Step 6 --spawn branch must explicitly
# state PATH C execute reverts to the legacy spawn-claude.sh -> tdd-implementer
# fan-out.
printf '%s' "$step6" | grep -qiF "PATH C" || { echo "MISSING (Step 6 --spawn): PATH C explicit mention (#749)"; fail=1; }
printf '%s' "$step6" | grep -qiF "spawn-claude.sh" || { echo "MISSING (Step 6 --spawn): spawn-claude.sh revert target for PATH C (#749)"; fail=1; }
printf '%s' "$step6" | grep -qiF "tdd-implementer" || { echo "MISSING (Step 6 --spawn): tdd-implementer fan-out for reverted PATH C (#749)"; fail=1; }

# (c) Step 7 has the all-paths-run-queue branch. Block-scope to the Step 7
# block: starts at "7. **Evaluate PRs (wave N)" and ends at the "7b. " line.
step7="$(awk '/^7\. \*\*Evaluate PRs \(wave N\)/{f=1} /^7b\. /{f=0} f' "$FILE")"
if [ -z "$step7" ]; then
  echo "VIOLATION: could not locate Step 7 (Evaluate PRs) block"; fail=1
fi
printf '%s' "$step7" | grep -qiF -- "--spawn" || { echo "MISSING (Step 7): --spawn"; fail=1; }
printf '%s' "$step7" | grep -qiF "run-queue" || { echo "MISSING (Step 7): run-queue"; fail=1; }
printf '%s' "$step7" | grep -qiF -- "--skill evaluate-issue-pr" || { echo "MISSING (Step 7): --skill evaluate-issue-pr"; fail=1; }

# Issue #749 Task 6: inline-C's first rollout is operator merge-gated on a live
# branch test — run one real PATH C issue through inline fan-out, confirm the
# main-session context load is tolerable, and dispatch with --manual-merge (no
# auto-merge) until validated. Phrase-presence guard (file-level: the gate note
# lives in the PATH C execution routing-reference branch).
assert_has "Live branch-test merge gate"
assert_has "main-session context load is tolerable"
grep -qiF -- "--manual-merge" "$FILE" || { echo "MISSING (#749 merge gate): --manual-merge"; fail=1; }
grep -qiF "NO auto-merge" "$FILE" || { echo "MISSING (#749 merge gate): NO auto-merge"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "PASS: fullsend --spawn flag phrases present"
else
  exit 1
fi
