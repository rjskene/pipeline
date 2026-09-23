#!/bin/bash
set -uo pipefail

# Regression guard for issue #1389 — scripts/run-test-suite.sh must scrub
# PIPELINE_PROJECT_ROOT / CLAUDE_PLUGIN_ROOT / PIPELINE_USE_LOCAL_PLUGIN
# inherited from its caller (skill boot fence, orchestrator session) and
# re-derive them from ITS OWN tree (REPO_ROOT) before dispatching any test —
# else a worktree suite run silently tests the caller's tree (cycle 16: six
# false failures). Covers both dispatch paths (default parallel fan-out and
# `--chunk`, which share the same exported-env mechanism), the escape hatch
# (PIPELINE_TEST_ROOT_OVERRIDE=1), and the six named tests end-to-end.
#
# All runner exercises use `mktemp -d` stub/decoy dirs — NEVER the real
# tests/ dir as the "decoy" root. The leak guard is disabled
# (PIPELINE_TEST_LEAK_GUARD_REPO="") since these invocations are irrelevant
# to it and it would otherwise snapshot the real repo on every call.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-test-suite.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$RUNNER" ]; then
  echo "FAIL: scripts/run-test-suite.sh not found under $ROOT" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

STUB_DIR="$WORK/tests"; mkdir -p "$STUB_DIR"
MARKER="$WORK/marker.txt"
cat > "$STUB_DIR/test-marker.sh" <<EOF
#!/bin/bash
{
  echo "PROJECT_ROOT=\${PIPELINE_PROJECT_ROOT:-UNSET}"
  echo "PLUGIN_ROOT=\${CLAUDE_PLUGIN_ROOT:-UNSET}"
  echo "USE_LOCAL=\${PIPELINE_USE_LOCAL_PLUGIN:-UNSET}"
} > "$MARKER"
exit 0
EOF
chmod +x "$STUB_DIR/test-marker.sh"

DECOY="$WORK/decoy"; mkdir -p "$DECOY"

run_stub() {
  local extra="$1"
  rm -f "$MARKER"
  PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
    PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
    bash "$RUNNER" $extra "$STUB_DIR" >/dev/null 2>&1
}

UNSET3="$(printf 'PROJECT_ROOT=UNSET\nPLUGIN_ROOT=UNSET\nUSE_LOCAL=UNSET')"

echo "Case 1: default (parallel) dispatch scrubs the caller's roots"
run_stub ""
inc
if [ "$(cat "$MARKER")" = "$UNSET3" ]; then
  pass_msg "default mode: stub saw no inherited roots, not the decoy"
else
  fail_msg "default mode: expected all-UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

echo "Case 2: --chunk dispatch scrubs the caller's roots"
run_stub "--chunk 1/1"
inc
if [ "$(cat "$MARKER")" = "$UNSET3" ]; then
  pass_msg "chunk mode: stub saw no inherited roots, not the decoy"
else
  fail_msg "chunk mode: expected all-UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

echo "Case 3: PIPELINE_TEST_ROOT_OVERRIDE=1 escape hatch preserves the caller's roots"
rm -f "$MARKER"
PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_TEST_ROOT_OVERRIDE=1 PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
  bash "$RUNNER" "$STUB_DIR" >/dev/null 2>&1
inc
if [ "$(cat "$MARKER")" = "$(printf 'PROJECT_ROOT=%s\nPLUGIN_ROOT=%s\nUSE_LOCAL=true' "$DECOY" "$DECOY")" ]; then
  pass_msg "escape hatch: stub saw the caller's decoy roots, unchanged"
else
  fail_msg "escape hatch: expected roots=$DECOY true; got:"; sed 's/^/    /' "$MARKER"
fi

echo "Case 4: the six named tests pass when run through the runner with a decoy root exported"
NAMED="test_create_checkpoint_tag.sh test-run-queue-status-propagates-project-root.sh test-resolve-plugin-root.sh test-doctor-dogfood-plugin-root.sh test-spawn-claude-log-gate.sh test-spawn-claude-runs-log-model-column.sh"
NAMED_DIR="$WORK/named"; mkdir -p "$NAMED_DIR"
for n in $NAMED; do
  printf '#!/bin/bash\nexec bash "%s/tests/%s" "$@"\n' "$ROOT" "$n" > "$NAMED_DIR/$n"
  chmod +x "$NAMED_DIR/$n"
done
rc=0
PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_TEST_LEAK_GUARD_REPO="" \
  bash "$RUNNER" "$NAMED_DIR" > "$WORK/named.out" 2>&1 || rc=$?
inc
if [ "$rc" -eq 0 ]; then
  pass_msg "all six named tests passed via the runner with a decoy root exported"
else
  fail_msg "runner exited $rc on the six named tests; tail:"; tail -n 30 "$WORK/named.out" | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]
