#!/bin/bash
set -euo pipefail

# Tests for the label-application algorithm in the classify-issue skill
# (skills/classify-issue/SKILL.md at plugin root).
#
# The skill applies `docs-only` / `multi-task` labels directly instead of
# just recommending them. The label-application logic lives in a bash
# block between the sentinel comments `# BEGIN-LABEL-APPLY` and
# `# END-LABEL-APPLY`. This test extracts that block from the canonical
# SKILL.md, stubs `gh` to log invocations, and asserts the expected
# add-label / remove-label calls for each recommendation × current-label
# combination.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

RENDERED="$SKILL_FILE"

# Extract the label-application bash block. Include the BEGIN line (not the
# END line) so the block is a runnable fragment.
APPLY_SCRIPT="$WORKDIR/apply-label.sh"
awk '
  /^[[:space:]]*# BEGIN-LABEL-APPLY/ { inblock = 1 }
  inblock { print }
  /^[[:space:]]*# END-LABEL-APPLY/   { inblock = 0 }
' "$RENDERED" > "$APPLY_SCRIPT"

if [ ! -s "$APPLY_SCRIPT" ]; then
  echo "ERROR: could not extract BEGIN-LABEL-APPLY..END-LABEL-APPLY block" >&2
  exit 1
fi

# Stub gh on PATH. Logs every invocation; returns success.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
GH_LOG="$WORKDIR/gh-calls.log"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "$@" >> "$GH_LOG_FILE"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Runs the extracted block with the given inputs. Returns the number of
# `gh issue edit` calls logged.
run_apply() {
  local recommended="$1"
  local current_labels="$2"
  local issue_n="${3:-999}"
  : > "$GH_LOG"
  set +e
  env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    GH_LOG_FILE="$GH_LOG" \
    ISSUE_N="$issue_n" \
    RECOMMENDED_PATH="$recommended" \
    CURRENT_LABELS="$current_labels" \
    REPO="fake/repo" \
    bash "$APPLY_SCRIPT" >"$WORKDIR/out.txt" 2>"$WORKDIR/err.txt"
  local rc=$?
  set -e
  return $rc
}

log_contains() {
  grep -qE "$1" "$GH_LOG"
}

log_count() {
  wc -l < "$GH_LOG" | tr -d ' '
}

# --- Test 1: PATH A, no current labels -> add docs-only only ---
echo "Test 1: PATH A + no labels -> add docs-only"
inc
run_apply A "" 111
if log_contains 'issue edit 111 --repo fake/repo --add-label docs-only' \
   && ! log_contains 'multi-task' \
   && [ "$(log_count)" = "1" ]; then
  pass_msg "added docs-only (1 call, no multi-task)"
else
  fail_msg "unexpected gh calls for PATH A + empty labels: $(cat "$GH_LOG")"
fi

# --- Test 2: PATH C, no current labels -> add multi-task only ---
echo "Test 2: PATH C + no labels -> add multi-task"
inc
run_apply C "" 222
if log_contains 'issue edit 222 --repo fake/repo --add-label multi-task' \
   && ! log_contains 'docs-only' \
   && [ "$(log_count)" = "1" ]; then
  pass_msg "added multi-task (1 call, no docs-only)"
else
  fail_msg "unexpected gh calls for PATH C + empty labels: $(cat "$GH_LOG")"
fi

# --- Test 3: PATH B, no current labels -> no calls ---
echo "Test 3: PATH B + no labels -> no gh calls"
inc
run_apply B "" 333
if [ "$(log_count)" = "0" ]; then
  pass_msg "no label edits for PATH B"
else
  fail_msg "unexpected gh calls for PATH B: $(cat "$GH_LOG")"
fi

# --- Test 4: A -> C reclassification (currently has docs-only, rec C) ---
echo "Test 4: rec C + currently docs-only -> remove docs-only, add multi-task"
inc
run_apply C "docs-only" 444
if log_contains 'issue edit 444 --repo fake/repo --remove-label docs-only' \
   && log_contains 'issue edit 444 --repo fake/repo --add-label multi-task' \
   && [ "$(log_count)" = "2" ]; then
  pass_msg "swap docs-only -> multi-task (remove then add, 2 calls)"
else
  fail_msg "unexpected gh calls for A->C swap: $(cat "$GH_LOG")"
fi

# --- Test 5: C -> A reclassification (currently has multi-task, rec A) ---
echo "Test 5: rec A + currently multi-task -> remove multi-task, add docs-only"
inc
run_apply A "multi-task" 555
if log_contains 'issue edit 555 --repo fake/repo --remove-label multi-task' \
   && log_contains 'issue edit 555 --repo fake/repo --add-label docs-only' \
   && [ "$(log_count)" = "2" ]; then
  pass_msg "swap multi-task -> docs-only (remove then add, 2 calls)"
else
  fail_msg "unexpected gh calls for C->A swap: $(cat "$GH_LOG")"
fi

# --- Test 6: Idempotent — rec A + already docs-only -> no calls ---
echo "Test 6: rec A + already docs-only -> no gh calls"
inc
run_apply A "docs-only" 666
if [ "$(log_count)" = "0" ]; then
  pass_msg "idempotent: no calls when label already matches recommendation"
else
  fail_msg "expected 0 calls (idempotent), got: $(cat "$GH_LOG")"
fi

# --- Test 7: Idempotent — rec C + already multi-task -> no calls ---
echo "Test 7: rec C + already multi-task -> no gh calls"
inc
run_apply C "multi-task" 777
if [ "$(log_count)" = "0" ]; then
  pass_msg "idempotent: no calls when multi-task already set"
else
  fail_msg "expected 0 calls (idempotent), got: $(cat "$GH_LOG")"
fi

# --- Test 8: rec B + currently docs-only -> remove docs-only only ---
echo "Test 8: rec B + currently docs-only -> remove docs-only"
inc
run_apply B "docs-only" 888
if log_contains 'issue edit 888 --repo fake/repo --remove-label docs-only' \
   && ! log_contains 'add-label' \
   && [ "$(log_count)" = "1" ]; then
  pass_msg "removed docs-only when downgrading to B"
else
  fail_msg "unexpected gh calls for rec B + docs-only: $(cat "$GH_LOG")"
fi

# --- Test 9: template contains cache-reconcile branch (self-heal) ---
echo "Test 9: template self-heal path for cached-with-mismatched-label"
inc
if grep -q "Reconciling labels for cached classification" "$RENDERED"; then
  pass_msg "cached-with-mismatch self-heal branch present in rendered skill"
else
  fail_msg "rendered skill does not describe the cached-with-mismatch reconcile path"
fi

# --- Test 10: template documents the label allow-set guardrail ---
echo "Test 10: template constrains writes to {docs-only, multi-task}"
inc
if grep -q "docs-only|multi-task" "$RENDERED" \
   && grep -q "REFUSED" "$RENDERED"; then
  pass_msg "allow-set guardrail present with REFUSED fail-loud"
else
  fail_msg "missing allow-set guardrail (REFUSED on non-path label)"
fi

# --- Test 11: footer no longer says 'Advisory only' ---
echo "Test 11: footer describes label application, not advisory-only"
inc
if grep -q "Advisory only" "$RENDERED"; then
  fail_msg "rendered skill still marked 'Advisory only' — should say label applied"
else
  pass_msg "advisory-only footer replaced"
fi

# --- Test 12: constraints allow gh issue edit for path labels only ---
echo "Test 12: constraints allow gh issue edit for path labels"
inc
if grep -qE "MAY call .?gh issue edit" "$RENDERED" \
   && grep -q "Never touch any other label" "$RENDERED"; then
  pass_msg "constraints section updated to permit scoped label edits"
else
  fail_msg "constraints still READ ONLY or missing scope statement"
fi

# --- Test 13: signal table maps "one-line fix" wording to quick-fix / PATH D ---
echo "Test 13: signal table covers quick-fix heuristics (one-line, rename, typo, tweak, ...)"
inc
# The step-4 signal table row added for PATH D must reference the trigger
# phrases including "one-line" and the quick-fix label, so an issue body
# containing the literal phrase "one-line fix" routes to PATH D / quick-fix.
if grep -qE 'one-line.*rename.*typo.*add guard.*small bug.*tweak.*quick-fix.*\| D \|' "$RENDERED" \
   || grep -qE '\| .*one-line.*quick-fix.* \| D \|' "$RENDERED"; then
  pass_msg "signal table row maps quick-fix heuristics to PATH D"
else
  fail_msg "no PATH D signal-table row covering 'one-line'/'quick-fix' heuristics"
fi

# --- Test 14: explicit quick-fix label -> PATH D, confidence=high ---
echo "Test 14: explicit quick-fix label yields recommended_path=D / confidence=high"
inc
# The step-4 table already maps explicit `docs-only` / `multi-task` labels
# to PATH A/C with confidence=high. The new PATH D row must give the same
# treatment to an explicit `quick-fix` label.
if grep -qE 'Labels include .?quick-fix.?\s*\| D \| high' "$RENDERED"; then
  pass_msg "explicit quick-fix label -> PATH D high confidence row present"
else
  fail_msg "no signal-table row mapping 'Labels include quick-fix' -> D/high"
fi

# --- Test 15: _safe_label allow-set includes quick-fix ---
echo "Test 15: _safe_label allow-set substring contains quick-fix"
inc
if grep -qE 'docs-only\|multi-task\|quick-fix' "$RENDERED"; then
  pass_msg "_safe_label allow-set extended to include quick-fix"
else
  fail_msg "_safe_label allow-set does not include quick-fix"
fi

# --- Test 16: D -> B reclassification removes quick-fix ---
echo "Test 16: rec B + currently quick-fix -> remove quick-fix"
inc
run_apply B "quick-fix" 1616
if log_contains 'issue edit 1616 --repo fake/repo --remove-label quick-fix' \
   && ! log_contains 'add-label' \
   && [ "$(log_count)" = "1" ]; then
  pass_msg "removed quick-fix when downgrading from D to B"
else
  fail_msg "unexpected gh calls for rec B + quick-fix: $(cat "$GH_LOG")"
fi

# --- Test 17: PATH D, no current labels -> add quick-fix only ---
echo "Test 17: PATH D + no labels -> add quick-fix"
inc
run_apply D "" 1717
if log_contains 'issue edit 1717 --repo fake/repo --add-label quick-fix' \
   && ! log_contains 'docs-only' \
   && ! log_contains 'multi-task' \
   && [ "$(log_count)" = "1" ]; then
  pass_msg "added quick-fix (1 call, no docs-only/multi-task)"
else
  fail_msg "unexpected gh calls for PATH D + empty labels: $(cat "$GH_LOG")"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
