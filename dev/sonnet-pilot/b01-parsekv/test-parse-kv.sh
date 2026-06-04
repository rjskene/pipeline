#!/usr/bin/env bash
# Colocated tests for parse-kv.sh / kv_get
# All five required behaviors: last-wins, comment-ignored, trim, absent->non-zero, value-with-equals

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=parse-kv.sh
source "$SCRIPT_DIR/parse-kv.sh"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $desc"
    ((pass++)) || true
  else
    echo "FAIL: $desc — expected='$expected' got='$actual'"
    ((fail++)) || true
  fi
}

assert_exit_nonzero() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    echo "FAIL: $desc — expected non-zero exit but got 0"
    ((fail++)) || true
  else
    echo "PASS: $desc"
    ((pass++)) || true
  fi
}

# ---- Create temp fixture file ----
TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT

cat >"$TMPFILE" <<'EOF'
# This is a comment — should be ignored even if it has KEY=VALUE style
  # indented comment, also ignored
FOO=first
BAR=hello
FOO=second
  KEY_WITH_SPACES  =  trimmed value
EQUALS_IN_VAL=a=b=c
EOF

# 1. Basic read
assert_eq "basic key read" "hello" "$(kv_get BAR "$TMPFILE")"

# 2. Last-assignment wins
assert_eq "last-assignment wins" "second" "$(kv_get FOO "$TMPFILE")"

# 3. Comment lines are ignored (# line contains KEY= but must not be parsed as a value)
assert_exit_nonzero "comment line with KEY= is ignored (key absent)" kv_get "This is a comment" "$TMPFILE"

# 4a. Key whitespace trimmed
assert_eq "whitespace around key trimmed" "trimmed value" "$(kv_get KEY_WITH_SPACES "$TMPFILE")"

# 4b. Value whitespace trimmed
VAL="$(kv_get KEY_WITH_SPACES "$TMPFILE")"
assert_eq "whitespace around value trimmed" "trimmed value" "$VAL"

# 5. Absent key returns non-zero exit and prints nothing
output="$(kv_get MISSING_KEY "$TMPFILE" 2>/dev/null || true)"
assert_eq "absent key prints nothing" "" "$output"
assert_exit_nonzero "absent key returns non-zero exit" kv_get MISSING_KEY "$TMPFILE"

# 6. Value may contain '='; split on first '=' only
assert_eq "value with equals signs" "a=b=c" "$(kv_get EQUALS_IN_VAL "$TMPFILE")"

# ---- Summary ----
echo ""
echo "Results: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
