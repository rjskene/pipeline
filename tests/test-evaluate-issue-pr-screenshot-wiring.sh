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

# Step 6 must verify each screenshot actually landed on the remote branch
# (git ls-remote / gh api contents) BEFORE emitting an image markdown row.
assert "Step 6 verifies screenshot reached remote before emitting image" \
  "awk '/^6\\. \\*\\*Visual validation/,/^7\\. \\*\\*If fixable/' '$SKILL' | grep -qE 'git ls-remote|gh api repos.*/contents/\\.eval-screenshots'"

# Step 6 must emit a failure-loud row when verification fails, not a broken link.
assert "Step 6 emits failure-loud row on attach failure" \
  "awk '/^6\\. \\*\\*Visual validation/,/^7\\. \\*\\*If fixable/' '$SKILL' | grep -q '⚠️ screenshot attach failed'"

# Step 9 comment template must include a Screenshot row and an inline image
# markdown row matching the branch-pinned raw.githubusercontent.com URL shape.
assert "Step 9 template mentions Screenshot row"        "grep -q 'Screenshot' '$SKILL'"
assert "Step 9 template includes branch-pinned raw image row" \
  "grep -qE '!\\[.*\\]\\(https://raw\\.githubusercontent\\.com/[^)]+/\\.eval-screenshots/[^)]+\\.png\\)' '$SKILL'"

# Post-merge durable-URL contract (issue #506). The §117 attach prose and the
# §224 Step 11 green-path prose must describe the merge-SHA rewrite, NOT the
# superseded Option A ephemeral-404 behaviour.

# (a) The stale "intentionally 404" claim must be gone (it lived in §117 prose).
assert "no stale 'intentionally 404' claim remains" \
  "! grep -q 'intentionally 404' '$SKILL'"

# (b) §117 (Attach screenshots) must reference the merge-SHA rewrite and opt-out.
S117="awk '/Attach screenshots to the eval comment/,/Failure-loud verification/' '$SKILL'"
assert "§117 references merge-SHA rewrite" \
  "$S117 | grep -qi 'merge-sha'"
assert "§117 references PIPELINE_SCREENSHOT_REWRITE_ENABLED opt-out" \
  "$S117 | grep -q 'PIPELINE_SCREENSHOT_REWRITE_ENABLED'"

# (c) §224 Step 11 green path must invoke the rewrite step and call the URLs durable.
GREEN="awk '/On .green.:/,/On any .block-/' '$SKILL'"
assert "§224 green path invokes rewrite-eval-screenshot-urls.sh" \
  "$GREEN | grep -q 'rewrite-eval-screenshot-urls.sh'"
assert "§224 green path documents durable merge-SHA-pinned URLs" \
  "$GREEN | grep -qi 'durable'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
