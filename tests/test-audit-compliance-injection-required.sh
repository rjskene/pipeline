#!/bin/bash
set -uo pipefail

# Review fix (issue #417): v0 of audit-compliance.sh has the injection path
# wired but not the live `gh` fallback (deferred to v1 / #418). Without a
# guard the script silently runs with empty JSON bodies and emits a
# misleading "Non-compliant" audit on rc=0. This test locks the guard:
# invoking with two positional args but missing ANY of the three injection
# flags must hard-fail with a clear stderr message.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-compliance.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SCRIPT" ]; then
  fail_msg "script exists at scripts/audit-compliance.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DUMMY_FILES="$TMPDIR/files.json"
DUMMY_COMMITS="$TMPDIR/commits.json"
DUMMY_LABELS="$TMPDIR/labels.json"
echo "[]" > "$DUMMY_FILES"
echo "[]" > "$DUMMY_COMMITS"
echo "[]" > "$DUMMY_LABELS"

assert_guard_fires() {
  local desc="$1"; shift
  local out rc
  out="$(bash "$SCRIPT" 999 999 "$@" 2>&1 1>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass_msg "$desc — exits non-zero (rc=$rc)"
  else
    fail_msg "$desc — exits non-zero (got rc=$rc, stderr: $out)"
    return
  fi
  if echo "$out" | grep -qF "v0 requires"; then
    pass_msg "$desc — stderr mentions v0 requirement"
  else
    fail_msg "$desc — stderr mentions v0 requirement (got: $out)"
  fi
}

# 0 of 3 injection flags
assert_guard_fires "no injection flags" --dry-run

# 1 of 3 flags
assert_guard_fires "only --files-json" --dry-run --files-json "$DUMMY_FILES"
assert_guard_fires "only --commits-json" --dry-run --commits-json "$DUMMY_COMMITS"
assert_guard_fires "only --labels-json" --dry-run --labels-json "$DUMMY_LABELS"

# 2 of 3 flags (missing --labels-json)
assert_guard_fires "missing --labels-json" --dry-run \
  --files-json "$DUMMY_FILES" --commits-json "$DUMMY_COMMITS"

# All three present → guard MUST NOT fire (script proceeds normally).
OUT_OK="$(bash "$SCRIPT" 999 999 --dry-run \
  --files-json "$DUMMY_FILES" \
  --commits-json "$DUMMY_COMMITS" \
  --labels-json "$DUMMY_LABELS" 2>&1)"
RC_OK=$?
if [ "$RC_OK" = "0" ] && echo "$OUT_OK" | grep -q "## Compliance Audit"; then
  pass_msg "all three flags present — script runs normally"
else
  fail_msg "all three flags present — script runs normally (rc=$RC_OK, out: $OUT_OK)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
