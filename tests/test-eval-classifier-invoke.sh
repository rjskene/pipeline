#!/bin/bash
set -uo pipefail

# Tests for scripts/eval-classifier-invoke.sh (issue #218; repointed to
# the plugin-shipped helper by #325). The helper is the single source of
# truth for invoking the consumer-provided pre-spawn classifier. Contract:
#   PIPELINE_EVAL_CLASSIFIER unset           -> exit 0, stderr `classifier-unset`
#   classifier rc=0 stdout='line1\nline2\n'  -> exit 0, stdout forwards verbatim
#   classifier rc=N stderr=<msg>             -> exit N, stderr forwards <msg>
#   PIPELINE_EVAL_CLASSIFIER set but file
#     missing on disk                        -> exit 3, stderr `classifier-not-found:`

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/eval-classifier-invoke.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Stage the helper at PLUGIN_ROOT/scripts/eval-classifier-invoke.sh and
# provide REPO_ROOT via PIPELINE_PROJECT_ROOT, matching the new contract
# (the plugin-shipped helper resolves REPO_ROOT from PIPELINE_PROJECT_ROOT
# rather than its own dirname). The classifier script is staged under
# REPO_ROOT/.claude/scripts/ so consumer-relative PIPELINE_EVAL_CLASSIFIER
# paths still resolve.
PROJ="$WORKDIR/proj"
PLUGIN_ROOT="$WORKDIR/plugin"
mkdir -p "$PROJ/.claude/scripts" "$PLUGIN_ROOT/scripts"
cp "$SCRIPT_UNDER_TEST" "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh"
chmod +x "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh"
# Helper now reads REPO_ROOT from PIPELINE_PROJECT_ROOT, not from its own dirname.
export PIPELINE_PROJECT_ROOT="$PROJ"

# Stub classifier — happy path
mkdir -p "$PROJ/.claude/scripts"
cat > "$PROJ/.claude/scripts/stub-classifier-ok.sh" <<'EOF'
#!/bin/bash
echo "--container-mode=web-eval"
echo "--foo=bar"
exit 0
EOF
chmod +x "$PROJ/.claude/scripts/stub-classifier-ok.sh"

# Stub classifier — non-zero exit
cat > "$PROJ/.claude/scripts/stub-classifier-fail.sh" <<'EOF'
#!/bin/bash
echo "cannot reach docker daemon" >&2
exit 2
EOF
chmod +x "$PROJ/.claude/scripts/stub-classifier-fail.sh"

# -------------------------------------------------------------------------
# Test 1: PIPELINE_EVAL_CLASSIFIER unset -> exit 0, stderr classifier-unset
# -------------------------------------------------------------------------
echo "Test 1: classifier unset is a no-op (exit 0, stderr marker)"
inc
OUT_FILE="$WORKDIR/out1.txt"
ERR_FILE="$WORKDIR/err1.txt"
unset PIPELINE_EVAL_CLASSIFIER
bash "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh" 100 200 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "expected exit 0 when classifier unset, got $rc"
elif [ -s "$OUT_FILE" ]; then
  fail_msg "expected empty stdout when classifier unset; got: $(cat "$OUT_FILE")"
elif ! grep -q "classifier-unset" "$ERR_FILE"; then
  fail_msg "expected stderr marker 'classifier-unset'; got: $(cat "$ERR_FILE")"
else
  pass_msg "exit 0, empty stdout, stderr contains 'classifier-unset'"
fi

# -------------------------------------------------------------------------
# Test 2: classifier rc=0 with multi-line stdout -> stdout forwarded verbatim
# -------------------------------------------------------------------------
echo "Test 2: classifier rc=0 stdout forwarded verbatim"
inc
OUT_FILE="$WORKDIR/out2.txt"
ERR_FILE="$WORKDIR/err2.txt"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/stub-classifier-ok.sh" \
  bash "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh" 100 200 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
EXPECTED=$'--container-mode=web-eval\n--foo=bar'
ACTUAL="$(cat "$OUT_FILE")"
if [ "$rc" -ne 0 ]; then
  fail_msg "expected exit 0, got $rc (stderr: $(cat "$ERR_FILE"))"
elif [ "$ACTUAL" != "$EXPECTED" ]; then
  fail_msg "stdout mismatch: expected '$EXPECTED' got '$ACTUAL'"
else
  pass_msg "stdout forwarded verbatim, exit 0"
fi

# -------------------------------------------------------------------------
# Test 3: classifier rc=2 with stderr -> helper exits 2 and forwards stderr
# -------------------------------------------------------------------------
echo "Test 3: classifier rc=2 forwards stderr and exit code"
inc
OUT_FILE="$WORKDIR/out3.txt"
ERR_FILE="$WORKDIR/err3.txt"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/stub-classifier-fail.sh" \
  bash "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh" 100 200 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -ne 2 ]; then
  fail_msg "expected exit 2, got $rc"
elif ! grep -q "cannot reach docker daemon" "$ERR_FILE"; then
  fail_msg "expected stderr to forward 'cannot reach docker daemon'; got: $(cat "$ERR_FILE")"
else
  pass_msg "exit 2, stderr forwarded"
fi

# -------------------------------------------------------------------------
# Test 4: PIPELINE_EVAL_CLASSIFIER configured but file missing -> exit 3
# -------------------------------------------------------------------------
echo "Test 4: configured classifier missing on disk -> exit 3"
inc
OUT_FILE="$WORKDIR/out4.txt"
ERR_FILE="$WORKDIR/err4.txt"
PIPELINE_EVAL_CLASSIFIER=".claude/scripts/does-not-exist.sh" \
  bash "$PLUGIN_ROOT/scripts/eval-classifier-invoke.sh" 100 200 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -ne 3 ]; then
  fail_msg "expected exit 3, got $rc"
elif ! grep -q "classifier-not-found:" "$ERR_FILE"; then
  fail_msg "expected stderr 'classifier-not-found:'; got: $(cat "$ERR_FILE")"
else
  pass_msg "exit 3, classifier-not-found marker emitted"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
