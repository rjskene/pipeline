#!/bin/bash
set -uo pipefail

# Issue #640: source-then-test commit ordering (test committed AFTER source)
# → TDD row verdict WEAK, aggregate "Compliant (weak: TDD)".

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
# Source commit FIRST, test commit SECOND → test-after → WEAK.
cat > "$COMMITS_JSON" <<'EOF'
[
  {"oid":"s1","files":["scripts/foo.sh"]},
  {"oid":"t1","files":["tests/test-foo.sh"]}
]
EOF
cat > "$LABELS_JSON" <<'EOF'
[]
EOF

OUT="$(bash "$SCRIPT" 999 999 --dry-run \
  --files-json "$FILES_JSON" \
  --commits-json "$COMMITS_JSON" \
  --labels-json "$LABELS_JSON" 2>&1)"

if echo "$OUT" | grep -qF "| TDD   | yes (PATH B) | test committed after source (test-after) | WEAK |"; then
  pass_msg "stdout contains PATH B WEAK TDD row"
else
  fail_msg "stdout contains PATH B WEAK TDD row (got: $OUT)"
fi

if echo "$OUT" | grep -qF "Aggregate: Compliant (weak: TDD)"; then
  pass_msg "stdout contains 'Aggregate: Compliant (weak: TDD)'"
else
  fail_msg "stdout contains 'Aggregate: Compliant (weak: TDD)' (got: $OUT)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
