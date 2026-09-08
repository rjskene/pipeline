#!/bin/bash
set -euo pipefail
# Guard: the broken test must be deleted and no other file may reference
# the consumer-side args path it pointed at.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

# Scan TRACKED files only (git ls-files), not the working tree — a bare
# `grep -r` walks gitignored dirs (e.g. /dev/audits/, .gitignore:16) and is
# green in CI (fresh checkout has no gitignored files) but red on any dev
# host with local artifacts. See issue #1255.
scan_tracked_refs() {
  (cd "$REPO_ROOT" && git ls-files -z -- '*.sh' '*.yml' '*.yaml' '*.py' '*.json' '*.md' \
    | xargs -0 grep -En 'test-path-c-args-directive\.sh|c-execute-subagent-driven-development\.txt' 2>/dev/null) \
    | grep -v "$(basename "$0")" \
    | grep -v "^CHANGELOG\.md:" \
    || true
}

echo "Test 1: tests/test-path-c-args-directive.sh has been removed"
inc
if [ -e "$REPO_ROOT/tests/test-path-c-args-directive.sh" ]; then
  fail_msg "tests/test-path-c-args-directive.sh still exists (must be deleted)"
else
  pass_msg "test file removed"
fi

echo "Test 2: no source file references the removed test or its args path"
inc
HITS=$(scan_tracked_refs)
if [ -n "$HITS" ]; then
  fail_msg "unexpected references remain:"$'\n'"$HITS"
else
  pass_msg "no references found"
fi

echo "Test 3: guard ignores a gitignored file containing a matching string"
inc
PLANTED="$REPO_ROOT/dev/audits/test-path-c-args-directive-removed-regression-$$.md"
mkdir -p "$(dirname "$PLANTED")"
cleanup_planted() { rm -f "$PLANTED"; }
trap cleanup_planted EXIT
echo "planted reference: test-path-c-args-directive.sh" > "$PLANTED"
PLANTED_HITS=$(scan_tracked_refs)
cleanup_planted
trap - EXIT
if printf '%s' "$PLANTED_HITS" | grep -q "test-path-c-args-directive-removed-regression"; then
  fail_msg "guard scanned the gitignored planted file (scope leak)"
else
  pass_msg "guard ignored the gitignored planted file"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
