#!/bin/bash
# Contract/lint test for the --keep-trees auto-cleanup opt-out (issue #766).
#
# /pipeline:run auto-cleans merged worktrees during Step 0 housekeeping
# (before discovery, non-blocking), reusing the existing cleanup-worktree.sh /
# create-checkpoint-tag.sh machinery and the existing ALLOW_DELETIONS gate.
# Passing --keep-trees anywhere in argv suppresses the auto-cleanup for that
# invocation (candidates are still surfaced, just not acted on). The flag is
# argv-only — no pipeline.config default.
#
# Five grep/awk lint assertions over skills/run/SKILL.md and
# skills/run/references/dispatch-routing.md. Modeled on
# tests/test-run-skill-auto-merge-default.sh (want_in/grep -qE) and
# tests/test-run-skill-dispatch-routing.sh (awk window slice).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_SKILL="${ROOT}/skills/status/SKILL.md"
# Auto-cleanup housekeeping prose (cleanup-worktree.sh / CLEANUP-SUMMARY /
# create-checkpoint-tag.sh) relocated from the deleted dispatch-routing.md into
# skills/status/references/housekeeping.md when run→status renamed (#763).
DISPATCH="${ROOT}/skills/status/references/housekeeping.md"
FAILED=0

want_in() {
  local file="$1" name="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in $file: $pat)"
    FAILED=$((FAILED+1))
  fi
}

want_in_fixed() {
  local file="$1" name="$2" lit="$3"
  if grep -qF -- "$lit" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (literal not found in $file: $lit)"
    FAILED=$((FAILED+1))
  fi
}

want_in_window() {
  # name window_text pattern (-i case-insensitive ERE via grep -qiE)
  local name="$1" window="$2" pat="$3"
  if echo "$window" | grep -qiE -- "$pat"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in auto-cleanup section window: $pat)"
    FAILED=$((FAILED+1))
  fi
}

[ -f "$RUN_SKILL" ] || { echo "FAIL: $RUN_SKILL missing"; exit 1; }
[ -f "$DISPATCH" ]  || { echo "FAIL: $DISPATCH missing"; exit 1; }

# 1. Shortcuts table has a --keep-trees row.
want_in "$RUN_SKILL" "Shortcuts table lists --keep-trees" '\| .*--keep-trees.* \|'

# 2. An auto-cleanup section keyed on --keep-trees opting OUT exists: both the
#    flag literal AND an auto-proceed/auto-cleanup phrase are present.
want_in_fixed "$RUN_SKILL" "auto-cleanup section names --keep-trees" '--keep-trees'
want_in "$RUN_SKILL" "auto-cleanup section asserts auto-proceed/auto-cleanup" 'auto-?cleanup|auto-proceed'

# 3. The auto-cleanup mode is NON-BLOCKING and runs BEFORE discovery — assert a
#    pre-discovery / non-blocking literal inside the auto-cleanup section window.
AUTOCLEAN_WINDOW=$(awk '/^## Auto-cleanup mode \(--keep-trees\)/{grab=1} grab{print} grab && /^## / && !/^## Auto-cleanup mode/{if(seen)exit; seen=1}' "$RUN_SKILL")
[ -n "$AUTOCLEAN_WINDOW" ] || AUTOCLEAN_WINDOW=$(awk '/^## Auto-cleanup mode/{grab=1;print;next} grab && /^## /{exit} grab{print}' "$RUN_SKILL")
want_in_window "auto-cleanup section is non-blocking / pre-discovery" "$AUTOCLEAN_WINDOW" 'before discovery|pre-discovery|non-blocking'

# 4. The auto path STILL reuses the existing machinery — all three literals
#    must remain present in dispatch-routing.md (drift guard against a future
#    edit dropping them).
want_in_fixed "$DISPATCH" "housekeeping keeps cleanup-worktree.sh"     'cleanup-worktree.sh'
want_in_fixed "$DISPATCH" "housekeeping keeps CLEANUP-SUMMARY"         'CLEANUP-SUMMARY'
want_in_fixed "$DISPATCH" "housekeeping keeps create-checkpoint-tag.sh" 'create-checkpoint-tag.sh'

# 5. Drift guard: cleanup is NOT gated behind the Step 5 user-confirmation on
#    the default path. The Step 4 cleanup bullet must have been rewritten to
#    reference --keep-trees (proving it is no longer "propose + wait").
want_in "$RUN_SKILL" "Step 4 cleanup bullet rewritten around --keep-trees" 'cleanup.*--keep-trees|--keep-trees.*cleanup'

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: run/SKILL.md --keep-trees auto-cleanup contract met"
