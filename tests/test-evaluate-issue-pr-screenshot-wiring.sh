#!/bin/bash
# NOT pipefail: every assert is `awk ... | grep -q PATTERN`. When grep -q matches
# early it closes the pipe, killing awk with SIGPIPE (exit 141); under pipefail
# that surfaces as a spurious non-zero — a flaky FAIL even though grep matched.
set -u
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

# Issue #517 — inline Agent dispatch mode for browser-eval PRs. The
# Invocation-mode section gains a third bullet; the inline-mode visual-proof
# setup re-uses the same durable URL substring (raw.githubusercontent.com/
# <owner>/<repo>/<merge-sha>/.eval-screenshots/) as the existing §117/§224
# contract. This guards against the inline-mode bullet drifting to a
# branch-pinned URL shape (which 404s post-merge per issue #506).

INLINE="awk '/Inline Agent dispatch \\(browser-eval/,/## Lifecycle/' '$SKILL'"

assert "Invocation-mode section names inline Agent dispatch (browser-eval) as default" \
  "grep -q 'Inline Agent dispatch (browser-eval' '$SKILL'"
assert "inline-mode bullet conditions on PIPELINE_EVAL_ISOLATION != container" \
  "grep -qE 'PIPELINE_EVAL_ISOLATION[^a-zA-Z_]+!=[^a-zA-Z_]+container|PIPELINE_EVAL_ISOLATION.*!=.*container' '$SKILL'"
assert "inline-mode bullet names --container-mode classifier emission" \
  "$INLINE | grep -q -- '--container-mode'"
assert "inline-mode bullet preserves the durable raw.githubusercontent.com/<merge-sha>/.eval-screenshots substring" \
  "$INLINE | grep -qE 'raw\\.githubusercontent\\.com/<owner>/<repo>/<merge-sha>/\\.eval-screenshots/'"

# Container-dispatch admonition must scope to ISOLATION=container only (issue #517).
assert "container-dispatch admonition scopes to PIPELINE_EVAL_ISOLATION=container" \
  "awk '/Container dispatch .issue #218/,/## Lifecycle/' '$SKILL' | grep -q 'PIPELINE_EVAL_ISOLATION=container'"

# Step 6c — inline-mode visual proof setup sub-bullet (issue #517).
S6C="awk '/\\*\\*6c\\. Inline-mode visual proof setup/,/^7\\. \\*\\*If fixable/' '$SKILL'"
assert "Step 6c (inline-mode visual proof setup) is present" \
  "grep -q '6c\\. Inline-mode visual proof setup' '$SKILL'"
assert "Step 6c binds python3 -m http.server to 127.0.0.1" \
  "$S6C | grep -qE 'python3 -m http\\.server.*--bind 127\\.0\\.0\\.1|python3 -m http\\.server.*-b 127\\.0\\.0\\.1'"
assert "Step 6c includes an EXIT trap for bg server cleanup" \
  "$S6C | grep -qE \"trap .*EXIT\""
assert "Step 6c uses curl readiness probe with 5 retries, 1s delay" \
  "$S6C | grep -qE 'curl.*--retry 5.*--retry-delay 1|curl.*--retry-delay 1.*--retry 5'"

# Canonical Agent prompt template fenced block (issue #517).
TPL="awk '/Canonical Agent prompt template/,/Constraints/' '$SKILL'"
assert "Canonical Agent prompt template heading present" \
  "grep -q 'Canonical Agent prompt template' '$SKILL'"
for field in Worktree PR "Target dir" Port Auto-merge; do
  assert "Agent prompt template names field: $field" \
    "$TPL | grep -q '$field'"
done

# 60s per-tool wall-clock budget for browser_evaluate / browser_navigate
# with explicit #511 cross-ref (issue #517).
assert "skill documents 60s per-tool budget for browser_evaluate / browser_navigate" \
  "grep -qE '60s.*browser_(evaluate|navigate)|browser_(evaluate|navigate).*60s' '$SKILL'"
assert "60s budget paragraph cross-refs issue #511" \
  "grep -q '#511' '$SKILL'"

# Migration-warning behavior (issue #517) — orchestrator owns the warning;
# skill must document the contract so reviewers know where to look.
assert "skill documents migration-warning behavior for missing TARGET_DIR" \
  "grep -qE 'TARGET_DIR.*unset|PIPELINE_VISUAL_PROOF_TARGET_DIR.*unset' '$SKILL'"
assert "migration-warning section names run-queue.sh launch_agent as owner" \
  "grep -qE 'run-queue\\.sh.*launch_agent|launch_agent.*run-queue\\.sh' '$SKILL'"
assert "migration-warning section states evaluation proceeds without visual proof / never blocks" \
  "grep -qE 'never blocks|non-blocking' '$SKILL'"

# -----------------------------------------------------------------------------
# Issue #551 — private-repo blob-link branch (Step 6 wrapper choice). The attach
# helper emits a blob URL on private repos; Step 6 must independently choose the
# `[]()` link wrapper (not `![]()` inline image) so GitHub's authenticated viewer
# renders the PNG for members. The private-row assertion targets the WRAPPER
# CHOICE — the runtime `${url}` variable form actually present in the SKILL —
# NOT a `blob/.eval-screenshots` literal (which only appears in the Step 9
# template, outside the $S6 range).
S6="awk '/^6\\. \\*\\*Visual validation/,/^7\\. \\*\\*If fixable/' '$SKILL'"
assert "Step 6 detects repo visibility via isPrivate" \
  "$S6 | grep -qE 'gh repo view.*isPrivate'"
assert "Step 6 guards the private branch on PRIVATE=true" \
  "$S6 | grep -qE '\\[ \"?\\\$PRIVATE\"? = \"?true\"? \\]'"
assert "Step 6 emits a private blob LINK row (- [name](url), not image)" \
  "$S6 | grep -qE '\"- \\[\\\$\\{name%\\.\\*\\}\\]\\(\\\$\\{url\\}\\)\"'"
assert "Step 6 keeps the public inline IMAGE row (- ![name](url))" \
  "$S6 | grep -qE '\"- !\\[\\\$\\{name%\\.\\*\\}\\]\\(\\\$\\{url\\}\\)\"'"
# Whole-file: user-attachments CDN limitation prose.
assert "skill documents user-attachments CDN limitation for private inline rendering" \
  "grep -qi 'user-attachments' '$SKILL'"
# Step 11.3 GREEN-range: rewrite prose must mention the blob form for private repos.
assert "Step 11.3 documents blob-URL rewrite for private repos" \
  "$GREEN | grep -qE 'blob/.*\\.eval-screenshots|blob link'"

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
