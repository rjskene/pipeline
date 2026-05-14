#!/bin/bash
set -euo pipefail

# Tests for scripts/post-plan.sh — the atomic helper that posts a plan
# comment, applies plan-pending, and verifies both side effects. The gh CLI
# is replaced by a PATH-resident shim that records calls to $GH_CALLS_LOG
# and reads scripted stdout/stderr/exit codes from $GH_SCRIPT_DIR/<n>.{out,err,rc}.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/post-plan.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "  (helper does not exist yet at $HELPER — every case will FAIL by design until Task 4)"
fi

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
n=$(cat "$GH_SCRIPT_DIR/.counter" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$GH_SCRIPT_DIR/.counter"
echo "$*" >> "$GH_CALLS_LOG"
[ -f "$GH_SCRIPT_DIR/$n.out" ] && cat "$GH_SCRIPT_DIR/$n.out"
[ -f "$GH_SCRIPT_DIR/$n.err" ] && cat "$GH_SCRIPT_DIR/$n.err" >&2
rc=$(cat "$GH_SCRIPT_DIR/$n.rc" 2>/dev/null || echo 0)
exit "$rc"
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="HTS-COLLAB-ORG/claude-pipeline"
DRAFT="$TMP/draft.md"
printf '## Implementation Plan\n\nbody\n' > "$DRAFT"

# reset scripted state between cases
reset_case() {
  local case_dir="$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir"
  export GH_SCRIPT_DIR="$case_dir"
  export GH_CALLS_LOG="$case_dir/calls.log"
  : > "$GH_CALLS_LOG"
}

# ---- Case (a): happy path ----
echo "Case (a): happy path"
inc
A="$TMP/case-a"; reset_case "$A"
# Call 1: gh issue comment ... --body-file (exit 0)
echo 0 > "$A/1.rc"
# Call 2: gh issue view ... --json comments (return body containing '## Implementation Plan')
printf '%s\n' '1' > "$A/2.out"
echo 0 > "$A/2.rc"
# Call 3: gh issue edit ... --add-label plan-pending (exit 0)
echo 0 > "$A/3.rc"
# Call 4: gh issue view ... --json labels (return labels with plan-pending)
printf '%s\n' 'plan-pending' > "$A/4.out"
echo 0 > "$A/4.rc"

if bash "$HELPER" 44 "$DRAFT" >"$A/stdout" 2>"$A/stderr"; then
  # Check call sequence
  if grep -qE "^issue comment .*--body-file" "$GH_CALLS_LOG" \
     && grep -qE "^issue view .*--json comments" "$GH_CALLS_LOG" \
     && grep -qE "^issue edit .*--add-label plan-pending" "$GH_CALLS_LOG" \
     && grep -qE "^issue view .*--json labels" "$GH_CALLS_LOG"; then
    pass_msg "happy path: helper exit 0; correct call sequence"
  else
    fail_msg "happy path: call sequence wrong; calls.log:"
    sed 's/^/    /' "$GH_CALLS_LOG"
  fi
else
  rc=$?
  fail_msg "happy path: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$A/stderr"
fi

# ---- Case (b): fail-once-then-succeed on comment ----
echo "Case (b): fail-once-then-succeed on comment"
inc
B="$TMP/case-b"; reset_case "$B"
# Call 1: gh issue comment — exit 1 with stderr
printf '%s\n' 'network error' > "$B/1.err"
echo 1 > "$B/1.rc"
# Call 2: gh issue comment retry — exit 0
echo 0 > "$B/2.rc"
# Call 3: gh issue view --json comments — return 1
printf '%s\n' '1' > "$B/3.out"
echo 0 > "$B/3.rc"
# Call 4: gh issue edit — exit 0
echo 0 > "$B/4.rc"
# Call 5: gh issue view --json labels — return plan-pending
printf '%s\n' 'plan-pending' > "$B/5.out"
echo 0 > "$B/5.rc"

if bash "$HELPER" 44 "$DRAFT" >"$B/stdout" 2>"$B/stderr"; then
  n_comments=$(grep -cE "^issue comment " "$GH_CALLS_LOG" || true)
  if [ "$n_comments" -eq 2 ]; then
    pass_msg "retry on comment: helper exit 0; saw 2 'issue comment' calls"
  else
    fail_msg "retry on comment: expected 2 'issue comment' calls, saw $n_comments"
  fi
else
  rc=$?
  fail_msg "retry on comment: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$B/stderr"
fi

# ---- Case (c): verify-comment gate trips ----
echo "Case (c): verify-comment gate trips"
inc
C="$TMP/case-c"; reset_case "$C"
# Call 1: comment (exit 0)
echo 0 > "$C/1.rc"
# Call 2: view comments — return 0
printf '%s\n' '0' > "$C/2.out"
echo 0 > "$C/2.rc"
# Call 3: view comments retry — return 0
printf '%s\n' '0' > "$C/3.out"
echo 0 > "$C/3.rc"

if bash "$HELPER" 44 "$DRAFT" >"$C/stdout" 2>"$C/stderr"; then
  fail_msg "verify-comment trip: helper exit 0; expected non-zero"
else
  if grep -qF ".claude/logs/plan-drafts/" "$C/stderr" 2>/dev/null || grep -qF "$DRAFT" "$C/stderr"; then
    if grep -qF "Implementation Plan" "$C/stderr"; then
      pass_msg "verify-comment trip: helper exit non-zero with draft path + 'Implementation Plan' in stderr"
    else
      fail_msg "verify-comment trip: stderr missing 'Implementation Plan' identifier"
      echo "    stderr:"; sed 's/^/      /' "$C/stderr"
    fi
  else
    fail_msg "verify-comment trip: stderr missing draft path"
    echo "    stderr:"; sed 's/^/      /' "$C/stderr"
  fi
fi

# ---- Case (d): label missing after edit ----
echo "Case (d): label missing after edit"
inc
D="$TMP/case-d"; reset_case "$D"
# Call 1: comment (exit 0)
echo 0 > "$D/1.rc"
# Call 2: view comments — return 1
printf '%s\n' '1' > "$D/2.out"
echo 0 > "$D/2.rc"
# Call 3: edit (exit 0)
echo 0 > "$D/3.rc"
# Call 4: view labels — return no plan-pending
printf '%s\n' 'priority/P2' > "$D/4.out"
echo 0 > "$D/4.rc"
# Call 5: view labels retry — still no plan-pending
printf '%s\n' 'priority/P2' > "$D/5.out"
echo 0 > "$D/5.rc"

if bash "$HELPER" 44 "$DRAFT" >"$D/stdout" 2>"$D/stderr"; then
  fail_msg "label missing: helper exit 0; expected non-zero"
else
  if grep -qF "plan-pending" "$D/stderr"; then
    pass_msg "label missing: helper exit non-zero with 'plan-pending' in stderr"
  else
    fail_msg "label missing: stderr missing 'plan-pending'"
    echo "    stderr:"; sed 's/^/      /' "$D/stderr"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
