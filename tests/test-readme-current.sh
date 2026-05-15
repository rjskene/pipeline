#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
PASS=0; FAIL=0
assert_in()  { if grep -qF "$2" "$README"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert_out() { if grep -qF "$2" "$README"; then echo "  FAIL: $1"; FAIL=$((FAIL+1)); else echo "  PASS: $1"; PASS=$((PASS+1)); fi; }

usage_table() { awk '/^## Usage/,/^---/' "$README"; }
assert_in_usage() {
  if usage_table | grep -qF "$2"; then
    echo "  PASS: $1"; PASS=$((PASS+1))
  else
    echo "  FAIL: $1"; FAIL=$((FAIL+1))
  fi
}

assert_in_usage "Usage table lists /pipeline:classify-issue" "/pipeline:classify-issue"
assert_in_usage "Usage table lists /pipeline:fullsend"       "/pipeline:fullsend"
assert_in_usage "Usage table lists /pipeline:doctor"         "/pipeline:doctor"

if head -20 "$README" | grep -qF "classify-issue"; then
  echo "  PASS: lifecycle diagram contains classify-issue"; PASS=$((PASS+1))
else
  echo "  FAIL: lifecycle diagram contains classify-issue"; FAIL=$((FAIL+1))
fi

if head -20 "$README" | grep -qF "fullsend"; then
  echo "  PASS: lifecycle area references fullsend"; PASS=$((PASS+1))
else
  echo "  FAIL: lifecycle area references fullsend"; FAIL=$((FAIL+1))
fi

assert_in  "Label flow line mentions docs-only path label"   "docs-only"
assert_in  "Label flow line mentions multi-task path label"  "multi-task"
assert_out "no multi-line subtree section"                   "## Migrating from a subtree install"
assert_in  "single-line subtree pointer still links migration guide" "docs/migration-from-subtree.md"
assert_out "no install.sh references"                        "install.sh"
assert_in  "fullsend pointer paragraph present"              "autonomous end-to-end runs"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
