#!/bin/bash
set -euo pipefail
# Guard: skills/execute-issue-plan/SKILL.md must declare that PATH D skips
# Step 8 in its entirety. We assert that "PATH D" appears within 200
# characters of BOTH "skip" and "Step 8" in the rendered SKILL.md.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

echo "Test 1: SKILL.md exists"
inc
if [ -f "$SKILL" ]; then
  pass_msg "SKILL.md found"
else
  fail_msg "SKILL.md missing at $SKILL"
fi

echo "Test 2: 'PATH D' appears within 200 chars of both 'skip' and 'Step 8' in SKILL.md"
inc
# Flatten newlines to a single line so we can use a windowed regex.
FLAT=$(tr '\n' ' ' < "$SKILL")
# Use python for reliable windowed substring check.
if python3 - "$FLAT" <<'PY'
import sys, re
text = sys.argv[1]
matches = [m.start() for m in re.finditer(r'PATH D', text)]
ok = False
for i in matches:
    window = text[max(0, i - 200): i + 200 + len('PATH D')]
    if re.search(r'skip', window, re.IGNORECASE) and 'Step 8' in window:
        ok = True
        break
sys.exit(0 if ok else 1)
PY
then
  pass_msg "PATH D directive co-located with skip + Step 8"
else
  fail_msg "no 'PATH D' occurrence within 200 chars of BOTH 'skip' and 'Step 8'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
