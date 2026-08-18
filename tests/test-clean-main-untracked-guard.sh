#!/bin/bash
set -uo pipefail

# Contract test for the fullsend Step 6a Clean-main guard recovery (issue #1207).
# The #1122 guard targets a STAGED/index leak. `--clean-main` now emits a distinct
# CLEAN=untracked-only token for an untracked-only checkout, and the Step 6a prose
# MUST map that token to an advisory that never stashes. The CLEAN=dirty recovery
# must no longer carry the untracked flag, which would sweep operator-owned files.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="skills/fullsend/SKILL.md"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$ROOT/$SKILL" ]; then
  echo "FAIL: $SKILL not found under $ROOT" >&2
  exit 1
fi

REGION="$(awk '
  /^[[:space:]]*6\. \*\*Execute \(wave N\)\*\*/ {capturing=1}
  /^[[:space:]]*(\*\*)?6b\./ {capturing=0}
  capturing {print}
' "$ROOT/$SKILL")"

if [ -z "$REGION" ]; then
  echo "FAIL: could not extract Step 6 region from $SKILL (markers moved?)" >&2
  exit 1
fi

assert_region_contains() {
  local label="$1" needle="$2"
  inc
  if printf '%s' "$REGION" | grep -F -q -- "$needle"; then
    pass_msg "$label: Step 6 region contains \"$needle\""
  else
    fail_msg "$label: Step 6 region missing \"$needle\""
  fi
}

# 1) All three CLEAN= tokens are wired into the Step 6a action table.
assert_region_contains "token-ok"        "CLEAN=ok"
assert_region_contains "token-untracked" "CLEAN=untracked-only"
assert_region_contains "token-dirty"     "CLEAN=dirty"

# 2) The untracked-only branch carries an explicit do-NOT-stash directive.
inc
if printf '%s' "$REGION" | grep -E -q -- 'CLEAN=untracked-only' \
   && printf '%s' "$REGION" | grep -E -q -- '(D|d)o NOT stash|[Nn]ever run .git stash'; then
  pass_msg "no-stash-directive: untracked-only branch states do NOT stash"
else
  fail_msg "no-stash-directive: Step 6 region missing a do-NOT-stash directive for untracked-only"
fi

# 3) HARD GUARD: the untracked-sweeping stash invocation must not appear ANYWHERE
#    in the Step 6 region — not in a recovery command, not inside a prohibition.
#    That flag sweeps untracked files; this is the #1207 data-loss hazard.
inc
if printf '%s' "$REGION" | grep -F -q -- 'stash push -u'; then
  fail_msg "no-stash-u: Step 6 region still contains the untracked-sweeping stash form (#1207 data-loss hazard)"
else
  pass_msg "no-stash-u: Step 6 region contains no untracked-sweeping stash form"
fi

# 4) The CLEAN=dirty branch still auto-recovers (guard narrowed, not removed).
assert_region_contains "dirty-recovery" "stash push"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
