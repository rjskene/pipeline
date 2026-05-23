#!/bin/bash
set -uo pipefail

# Task 1 (issue #417): PATH B PR touching only source files with no test
# commits → TDD row verdict SKIP, aggregate "Non-compliant (skipped: TDD)".

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
["scripts/foo.sh"]
EOF
cat > "$COMMITS_JSON" <<'EOF'
[{"oid":"aaa111","files":["scripts/foo.sh"]}]
EOF
cat > "$LABELS_JSON" <<'EOF'
[]
EOF

OUT="$(bash "$SCRIPT" 999 999 --dry-run \
  --files-json "$FILES_JSON" \
  --commits-json "$COMMITS_JSON" \
  --labels-json "$LABELS_JSON" 2>&1)"

if echo "$OUT" | grep -q "## Compliance Audit"; then
  pass_msg "stdout contains '## Compliance Audit' heading"
else
  fail_msg "stdout contains '## Compliance Audit' heading (got: $OUT)"
fi

if echo "$OUT" | grep -qF "| TDD   | yes (PATH B) | no test files in commits | SKIP |"; then
  pass_msg "stdout contains PATH B SKIP TDD row"
else
  fail_msg "stdout contains PATH B SKIP TDD row (got: $OUT)"
fi

if echo "$OUT" | grep -qF "Aggregate: Non-compliant (skipped: TDD)"; then
  pass_msg "stdout contains 'Aggregate: Non-compliant (skipped: TDD)'"
else
  fail_msg "stdout contains 'Aggregate: Non-compliant (skipped: TDD)' (got: $OUT)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
