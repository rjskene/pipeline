#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

SKILL="$REPO_ROOT/skills/evaluate-issue-pr/SKILL.md"

assert "skill file exists" "[ -f '$SKILL' ]"
assert "skill references eval-screenshot-attach.sh"      "grep -q 'eval-screenshot-attach.sh' '$SKILL'"
assert "skill no longer references eval-screenshot-cleanup.sh" "! grep -q 'eval-screenshot-cleanup.sh' '$SKILL'"

# attach call must appear under Step 6 (visual-validation), bounded by Step 7
assert "attach call appears under Step 6 (visual validation)" \
  "awk '/^6\\. \\*\\*Visual validation/,/^7\\. \\*\\*If fixable/' '$SKILL' | grep -q 'eval-screenshot-attach.sh'"

# Step 11 green path must NOT invoke the (now-deleted) cleanup helper.
assert "cleanup call ABSENT from Step 11 green path" \
  "! awk '/On .green.:/,/On any .block-/' '$SKILL' | grep -q 'eval-screenshot-cleanup.sh'"

# Step 9 comment template must include a Screenshot row and an inline image
# markdown row matching the new SHA-pinned URL shape.
assert "Step 9 template mentions Screenshot row"        "grep -q 'Screenshot' '$SKILL'"
assert "Step 9 template includes SHA-pinned raw image row" \
  "grep -qE '!\\[.*\\]\\(https://github\\.com/.*/raw/.*/mock-web-eval/screenshots/.*\\.png\\)' '$SKILL'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
