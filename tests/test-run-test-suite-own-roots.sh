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
# Case 6 additionally guards issue #1426: the runner must scrub
# PIPELINE_PERMISSION_BRIDGE_DIR / PIPELINE_PERMISSION_BRIDGE_TIMEOUT from every
# spawned test UNCONDITIONALLY — a bridge-armed headless session otherwise makes
# every hook-exec'ing test queue a malformed request against the LIVE queue and
# block for the bridge timeout. The PIPELINE_TEST_ROOT_OVERRIDE hatch covers
# ROOTS ONLY, so the bridge scrub holds even with the hatch set.
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
  echo "BRIDGE_DIR=\${PIPELINE_PERMISSION_BRIDGE_DIR:-UNSET}"
  echo "BRIDGE_TIMEOUT=\${PIPELINE_PERMISSION_BRIDGE_TIMEOUT:-UNSET}"
} > "$MARKER"
exit 0
EOF
chmod +x "$STUB_DIR/test-marker.sh"

DECOY="$WORK/decoy"; mkdir -p "$DECOY"
# A decoy queue dir standing in for the live bridge queue (#1426).
BRIDGE_DECOY="$WORK/bridge-queue"; mkdir -p "$BRIDGE_DECOY"

run_stub() {
  local extra="$1"
  rm -f "$MARKER"
  PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
    PIPELINE_PERMISSION_BRIDGE_DIR="$BRIDGE_DECOY" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=7 \
    PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
    bash "$RUNNER" $extra "$STUB_DIR" >/dev/null 2>&1
}

# Per-KEY marker assertions, not whole-file equality: the marker grows a line
# whenever a new scrub is guarded (#1426 added two), and a wholesale comparison
# reds every existing case on that growth instead of only the new one.
marker_has() { grep -qxF "$1" "$MARKER" 2>/dev/null; }
roots_scrubbed() {
  marker_has 'PROJECT_ROOT=UNSET' && marker_has 'PLUGIN_ROOT=UNSET' \
    && marker_has 'USE_LOCAL=UNSET'
}
bridge_scrubbed() {
  marker_has 'BRIDGE_DIR=UNSET' && marker_has 'BRIDGE_TIMEOUT=UNSET'
}

echo "Case 1: default (parallel) dispatch scrubs the caller's roots"
run_stub ""
inc
if roots_scrubbed; then
  pass_msg "default mode: stub saw no inherited roots, not the decoy"
else
  fail_msg "default mode: expected all-UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

echo "Case 2: --chunk dispatch scrubs the caller's roots"
run_stub "--chunk 1/1"
inc
if roots_scrubbed; then
  pass_msg "chunk mode: stub saw no inherited roots, not the decoy"
else
  fail_msg "chunk mode: expected all-UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

echo "Case 3: PIPELINE_TEST_ROOT_OVERRIDE=1 escape hatch preserves the caller's roots"
rm -f "$MARKER"
PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_PERMISSION_BRIDGE_DIR="$BRIDGE_DECOY" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=7 \
  PIPELINE_TEST_ROOT_OVERRIDE=1 PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
  bash "$RUNNER" "$STUB_DIR" >/dev/null 2>&1
inc
if marker_has "PROJECT_ROOT=$DECOY" && marker_has "PLUGIN_ROOT=$DECOY" \
   && marker_has 'USE_LOCAL=true'; then
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

echo "Case 5: --changed-only re-scrubs after its config source"
# --changed-only resolves its base ref by sourcing scripts/_resolve-config.sh,
# which re-reads pipeline.config under `set -a` — re-EXPORTING that config's own
# PIPELINE_PROJECT_ROOT / PIPELINE_USE_LOCAL_PLUGIN into the runner process after
# the entry scrub. Hermetic fixture: a throwaway git repo whose pipeline.config
# names the decoy root (no commits, so no git identity is needed).
CO="$WORK/co"; mkdir -p "$CO/scripts" "$CO/tests"
cp "$ROOT/scripts/run-test-suite.sh" "$ROOT/scripts/_resolve-config.sh" "$CO/scripts/"
cat > "$CO/pipeline.config" <<EOF
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="co-base"
PIPELINE_PROJECT_ROOT="$DECOY"
PIPELINE_USE_LOCAL_PLUGIN=true
EOF
cp "$STUB_DIR/test-marker.sh" "$CO/tests/test-marker.sh"
git init -q "$CO" >/dev/null 2>&1
rm -f "$MARKER"
( cd "$CO" && env -u PIPELINE_REPO -u PIPELINE_BASE_BRANCH \
    PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
    PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
    bash scripts/run-test-suite.sh --changed-only ) >/dev/null 2>&1
inc
if roots_scrubbed; then
  pass_msg "--changed-only: config source did not re-export roots to the stub"
else
  fail_msg "--changed-only: expected all-UNSET; got:"; sed 's/^/    /' "$MARKER" 2>/dev/null
fi

echo "Case 6: the runner scrubs the permission-bridge env from every spawned test"
# #1426: the first live run under the #1421 bridge had
# tests/test-subagent-log-utils-win32.sh exec hooks/permission-bridge.py with the
# session's PIPELINE_PERMISSION_BRIDGE_DIR inherited; the hook queued a
# tool_name="" request against the LIVE queue and blocked 840 s for an operator
# answer nobody was expecting. The runner must therefore scrub both bridge knobs
# from every spawned test, in every dispatch mode, and UNCONDITIONALLY — the
# PIPELINE_TEST_ROOT_OVERRIDE hatch is for ROOTS (#1389), not for the bridge.
run_stub ""
inc
if bridge_scrubbed; then
  pass_msg "default mode: stub saw no inherited permission-bridge env"
else
  fail_msg "default mode: expected BRIDGE_DIR/BRIDGE_TIMEOUT=UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

run_stub "--chunk 1/1"
inc
if bridge_scrubbed; then
  pass_msg "chunk mode: stub saw no inherited permission-bridge env"
else
  fail_msg "chunk mode: expected BRIDGE_DIR/BRIDGE_TIMEOUT=UNSET; got:"; sed 's/^/    /' "$MARKER"
fi

rm -f "$MARKER"
PIPELINE_PROJECT_ROOT="$DECOY" CLAUDE_PLUGIN_ROOT="$DECOY" PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_PERMISSION_BRIDGE_DIR="$BRIDGE_DECOY" PIPELINE_PERMISSION_BRIDGE_TIMEOUT=7 \
  PIPELINE_TEST_ROOT_OVERRIDE=1 PIPELINE_TEST_LEAK_GUARD_REPO="" PIPELINE_TEST_PARALLELISM=1 \
  bash "$RUNNER" "$STUB_DIR" >/dev/null 2>&1
inc
if bridge_scrubbed; then
  pass_msg "escape hatch: the bridge scrub is unconditional (the hatch covers roots only)"
else
  fail_msg "escape hatch: PIPELINE_TEST_ROOT_OVERRIDE=1 leaked the bridge env; got:"; sed 's/^/    /' "$MARKER"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ]
