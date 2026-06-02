#!/bin/bash
set -euo pipefail

# Tests for the tracker-label filter block in the run skill
# (skills/run/SKILL.md). Issue #31: tracker issues must be excluded from
# the ready/action queue but surfaced in the status table.
#
# The filter logic lives in a bash block between the sentinel comments
# `# BEGIN-TRACKER-FILTER` and `# END-TRACKER-FILTER`. This test extracts
# that block, stubs `gh` to emit a fixed JSON payload via ISSUE_LIST_JSON,
# runs the block, and asserts the expected READY_ISSUES / TRACKER_ISSUES
# partitions. Also asserts the create-issues tracker block applies the
# tracker label.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_SKILL="$SCRIPT_DIR/../skills/status/SKILL.md"
CREATE_SKILL="$SCRIPT_DIR/../skills/create-issues/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$RUN_SKILL" ]; then
  echo "ERROR: run SKILL.md not found at $RUN_SKILL" >&2
  exit 1
fi
if [ ! -f "$CREATE_SKILL" ]; then
  echo "ERROR: create-issues SKILL.md not found at $CREATE_SKILL" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Extract the tracker-filter bash block. Include the BEGIN line (not the
# END line) so the block is a runnable fragment.
FILTER_SCRIPT="$WORKDIR/filter.sh"
awk '
  /^[[:space:]]*# BEGIN-TRACKER-FILTER/ { inblock = 1 }
  inblock { print }
  /^[[:space:]]*# END-TRACKER-FILTER/   { inblock = 0 }
' "$RUN_SKILL" > "$FILTER_SCRIPT"

# Fixture payload: 4 issues — one tracker, two ready, one with a stage label.
FIXTURE_FILE="$WORKDIR/issues.json"
cat > "$FIXTURE_FILE" <<'EOF'
[
  {"number": 100, "title": "epic(foo): tracker for #101, #102", "labels": [{"name":"tracker"}]},
  {"number": 101, "title": "feat: sub one", "labels": []},
  {"number": 102, "title": "feat: sub two", "labels": [{"name":"plan-pending"}]},
  {"number": 103, "title": "feat: solo", "labels": []}
]
EOF

# Run the extracted filter block with ISSUE_LIST_JSON set from the fixture.
# Emit READY_ISSUES and TRACKER_ISSUES to a results file the test can read.
RUNNER="$WORKDIR/run-filter.sh"
cat > "$RUNNER" <<EOF
#!/bin/bash
set -euo pipefail
ISSUE_LIST_JSON=\$(cat "$FIXTURE_FILE")
export ISSUE_LIST_JSON
# Consumer-configurable label vars — set to empty so the SKIP regex still
# behaves (the filter must tolerate empty values).
export PIPELINE_LABELS_EXCLUDED=""
export PIPELINE_LABELS_LATER=""
export PIPELINE_LABELS_HUMAN=""
export PIPELINE_LABELS_BRAINSTORM=""
source "$FILTER_SCRIPT"
echo "READY=\${READY_ISSUES:-}"
echo "TRACKER=\${TRACKER_ISSUES:-}"
EOF
chmod +x "$RUNNER"

RESULTS="$WORKDIR/results.txt"
set +e
bash "$RUNNER" > "$RESULTS" 2> "$WORKDIR/err.txt"
RC=$?
set -e

READY_LINE=$(grep '^READY=' "$RESULTS" 2>/dev/null | sed 's/^READY=//' || echo "")
TRACKER_LINE=$(grep '^TRACKER=' "$RESULTS" 2>/dev/null | sed 's/^TRACKER=//' || echo "")

# --- Test 1: tracker (#100) NOT in READY_ISSUES ---
echo "Test 1: tracker issue (#100) is NOT in READY_ISSUES"
inc
if [ "$RC" -eq 0 ] && ! echo " $READY_LINE " | grep -q ' 100 '; then
  pass_msg "tracker not in ready set"
else
  fail_msg "tracker leaked into READY (rc=$RC, READY='$READY_LINE', err=$(cat "$WORKDIR/err.txt"))"
fi

# --- Test 2: tracker (#100) IS in TRACKER_ISSUES ---
echo "Test 2: tracker issue (#100) IS in TRACKER_ISSUES"
inc
if [ "$RC" -eq 0 ] && echo " $TRACKER_LINE " | grep -q ' 100 '; then
  pass_msg "tracker present in TRACKER set"
else
  fail_msg "tracker missing from TRACKER (rc=$RC, TRACKER='$TRACKER_LINE')"
fi

# --- Test 3: non-tracker no-label issue (#101) IS in READY ---
echo "Test 3: #101 (no labels, non-tracker) IS in READY_ISSUES"
inc
if [ "$RC" -eq 0 ] && echo " $READY_LINE " | grep -q ' 101 '; then
  pass_msg "#101 present in READY"
else
  fail_msg "#101 missing from READY (READY='$READY_LINE')"
fi

# --- Test 4: non-tracker no-label issue (#103) IS in READY ---
echo "Test 4: #103 (no labels, non-tracker) IS in READY_ISSUES"
inc
if [ "$RC" -eq 0 ] && echo " $READY_LINE " | grep -q ' 103 '; then
  pass_msg "#103 present in READY"
else
  fail_msg "#103 missing from READY (READY='$READY_LINE')"
fi

# --- Test 5: plan-pending stage label (#102) NOT in READY ---
echo "Test 5: #102 (plan-pending) is NOT in READY_ISSUES"
inc
if [ "$RC" -eq 0 ] && ! echo " $READY_LINE " | grep -q ' 102 '; then
  pass_msg "staged issue not in ready set"
else
  fail_msg "staged issue leaked into READY (READY='$READY_LINE')"
fi

# --- Test 6: create-issues tracker block contains --label tracker ---
echo "Test 6: skills/create-issues/SKILL.md tracker block applies --label tracker"
inc
if grep -A 30 'Tracker issue body template' "$CREATE_SKILL" | grep -q -- '--label tracker'; then
  pass_msg "create-issues tracker block wires --label tracker"
else
  fail_msg "create-issues tracker block missing --label tracker"
fi

# --- Test 7: run SKILL.md has BEGIN/END-TRACKER-FILTER sentinels ---
echo "Test 7: skills/run/SKILL.md contains BEGIN/END-TRACKER-FILTER sentinels"
inc
if grep -q "BEGIN-TRACKER-FILTER" "$RUN_SKILL" && grep -q "END-TRACKER-FILTER" "$RUN_SKILL"; then
  pass_msg "sentinels present in run skill"
else
  fail_msg "sentinels missing from run skill"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
