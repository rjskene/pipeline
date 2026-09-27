#!/bin/bash
# test-no-retired-hook-refs-skills.sh — the retired-deletion-hook prose guard (#1418).
#
# #1418 retired `hooks/block_deletions.py` and `hooks/restrict_paths.py`. The
# deny rail is now the session's permission mode (the auto-mode classifier plus
# the #1421 PermissionRequest bridge) together with `enforce-comment-trust.py`.
# The RULES those hooks used to be cited as enforcing all SURVIVE — the
# `/tmp`-read ban, the `run_in_background` ban, the `ALLOW_DELETIONS` gate, and
# the `.claude/worktrees/` placement rule are unchanged. What changed is the
# ATTRIBUTION: prose must no longer name a hook that does not exist, or an
# operator reading the skill will go looking for a file that was deleted (and
# `doctor` will not report it missing, because it is not supposed to be there).
#
# SCOPE NOTE — this guard scans an EXPLICIT FILE LIST, not `skills/` wholesale.
# `skills/doctor/SKILL.md` also names `block_deletions.py` (in its
# `LOAD_BEARING_HOOKS` row) and is owned by a sibling change; a directory-wide
# scan would couple the two. Check (a) is the control that keeps the list
# honest: a renamed/moved target must red here rather than pass vacuously.
#
# Static-only: reads tracked sources, runs nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# The prose surfaces #1418 re-attributes.
SCAN_FILES="
skills/execute-issue-plan/SKILL.md
skills/status/SKILL.md
skills/status/references/housekeeping.md
skills/hotfix/SKILL.md
"

# The retired hook basenames, sans `.py` so a bare-module mention also reds.
RETIRED="restrict_paths block_deletions"

echo "=== (a) every scan target exists (a missing file would pass vacuously) ==="
MISSING=""
for f in $SCAN_FILES; do
  [ -f "$ROOT/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass_msg "all 4 scan targets exist"
else
  fail_msg "scan target(s) missing —$MISSING (the scan below would be vacuous)"
fi

echo "=== (b) no retired-hook reference survives in skill prose ==="
for f in $SCAN_FILES; do
  [ -f "$ROOT/$f" ] || continue
  HITS=""
  for pat in $RETIRED; do
    FOUND="$(grep -nF -- "$pat" "$ROOT/$f" 2>/dev/null || true)"
    [ -n "$FOUND" ] && HITS="$HITS$FOUND"$'\n'
  done
  if [ -z "$HITS" ]; then
    pass_msg "$f names neither retired hook"
  else
    N="$(printf '%s' "$HITS" | grep -c . )"
    fail_msg "$f still names a retired hook ($N line(s)) — keep the rule, change the attribution"
    printf '%s' "$HITS" | grep . | cut -c1-140 | sed 's/^/    /'
  fi
done

echo "=== (c) the surviving rules are still stated (attribution swap, not deletion) ==="
assert_file_contains() {
  local file="$1"; local needle="$2"; local label="$3"
  if [ -f "$ROOT/$file" ] && grep -qF -- "$needle" "$ROOT/$file"; then
    pass_msg "$label"
  else
    fail_msg "$label (missing from $file: $needle)"
  fi
}

# execute-issue-plan: the /tmp-read ban + its in-boundary redirect, the
# Monitor-yield ban, and the run_in_background ban all stay.
assert_file_contains skills/execute-issue-plan/SKILL.md \
  '.claude/logs/' "execute-issue-plan keeps the in-boundary monitor-output redirect"
assert_file_contains skills/execute-issue-plan/SKILL.md \
  'Monitor-yield ban' "execute-issue-plan keeps the Monitor-yield ban"
assert_file_contains skills/execute-issue-plan/SKILL.md \
  'Never `run_in_background` a test run' "execute-issue-plan keeps the run_in_background ban"

# status + housekeeping: the ALLOW_DELETIONS gate is reused, not removed —
# sync-worktrees.sh and prune-logs.sh each read it independently.
assert_file_contains skills/status/SKILL.md \
  'ALLOW_DELETIONS' "status keeps the ALLOW_DELETIONS gate"
assert_file_contains skills/status/SKILL.md \
  'sync-worktrees.sh' "status names sync-worktrees.sh as the surviving gate reader"
assert_file_contains skills/status/references/housekeeping.md \
  'ALLOW_DELETIONS' "housekeeping keeps the ALLOW_DELETIONS gate"
assert_file_contains skills/status/references/housekeeping.md \
  'Do NOT add a second gate.' "housekeeping keeps the no-second-gate rule"

# hotfix: the placement rule and the #353 history pin both stay.
assert_file_contains skills/hotfix/SKILL.md \
  '.claude/worktrees/' "hotfix keeps the worktree placement rule"
assert_file_contains skills/hotfix/SKILL.md \
  'issue #353' "hotfix keeps the issue #353 history reference"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
