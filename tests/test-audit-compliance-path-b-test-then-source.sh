#!/bin/bash
set -uo pipefail

# Task 2 (issue #417): PATH B PR with one commit touching tests AND another
# touching source → TDD row verdict PASS, aggregate "Compliant".

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
["tests/test-foo.sh", "scripts/foo.sh"]
EOF
cat > "$COMMITS_JSON" <<'EOF'
[
  {"oid":"aaa111","files":["tests/test-foo.sh"]},
  {"oid":"bbb222","files":["scripts/foo.sh"]}
]
EOF
cat > "$LABELS_JSON" <<'EOF'
[]
EOF

OUT="$(bash "$SCRIPT" 999 999 --dry-run \
  --files-json "$FILES_JSON" \
  --commits-json "$COMMITS_JSON" \
  --labels-json "$LABELS_JSON" 2>&1)"

if echo "$OUT" | grep -qF "| TDD   | yes (PATH B) | test committed before/with source (test-first) | PASS |"; then
  pass_msg "stdout contains PATH B PASS TDD row"
else
  fail_msg "stdout contains PATH B PASS TDD row (got: $OUT)"
fi

if echo "$OUT" | grep -qF "Aggregate: Compliant"; then
  pass_msg "stdout contains 'Aggregate: Compliant'"
else
  fail_msg "stdout contains 'Aggregate: Compliant' (got: $OUT)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
