#!/bin/bash
set -uo pipefail

# Issue #640: a single commit touching BOTH a test file and a source file
# yields FIRST_TEST_IDX == FIRST_SRC_IDX; test-index <= source-index → PASS
# (red+green in one commit is legitimately test-first).

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

FILES_JSON="$TMPDIR/files.json"
COMMITS_JSON="$TMPDIR/commits.json"
LABELS_JSON="$TMPDIR/labels.json"

cat > "$FILES_JSON" <<'EOF'
["scripts/foo.sh","tests/test-foo.sh"]
EOF
# One commit touching BOTH test and source.
cat > "$COMMITS_JSON" <<'EOF'
[{"oid":"c1","files":["scripts/foo.sh","tests/test-foo.sh"]}]
EOF
cat > "$LABELS_JSON" <<'EOF'
[]
EOF

OUT="$(bash "$SCRIPT" 999 999 --dry-run \
  --files-json "$FILES_JSON" \
  --commits-json "$COMMITS_JSON" \
  --labels-json "$LABELS_JSON" 2>&1)"

if echo "$OUT" | grep -qF "| TDD   | yes (PATH B) | test committed before/with source (test-first) | PASS |"; then
  pass_msg "stdout contains PATH B PASS (tie-break) TDD row"
else
  fail_msg "stdout contains PATH B PASS (tie-break) TDD row (got: $OUT)"
fi

if echo "$OUT" | grep -qF "Aggregate: Compliant"; then
  pass_msg "stdout contains 'Aggregate: Compliant'"
else
  fail_msg "stdout contains 'Aggregate: Compliant' (got: $OUT)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
