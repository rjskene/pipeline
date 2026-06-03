#!/bin/bash
set -uo pipefail

# Regression guard for issue #897 — CI suite speedup.
#
# Covers three contracts:
#  1. scripts/run-test-suite.sh exists, is executable, and preserves STRICT
#     aggregate fail under parallel fan-out (a deliberately-failing stub with a
#     high exit code like 250 MUST still red the runner). xargs -P masks child
#     exit codes by default, so the runner uses a mktemp sentinel file.
#  2. .github/workflows/ci.yml wires the `tests` job to run-test-suite.sh (no
#     inline `for t in tests/test` loop, no `|| true` swallow), caches the
#     apt/jq setup (actions/cache present), and path-filters the heavy `tests`
#     job while the `guard` job stays always-on (ungated).
#  3. pipeline.config.example mirrors the parallel PIPELINE_TEST_CMD guidance
#     and the gitignored-pipeline.config host-side hand-patch callout
#     (dual-scan per CLAUDE.md #357 reference shape).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-test-suite.sh"
CI_YML="$ROOT/.github/workflows/ci.yml"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# ---------------------------------------------------------------------------
# 1. Runner existence + strict-fail behavior
# ---------------------------------------------------------------------------

inc
if [ -f "$RUNNER" ]; then
  pass_msg "scripts/run-test-suite.sh exists"
else
  fail_msg "scripts/run-test-suite.sh missing"
fi

inc
if [ -x "$RUNNER" ]; then
  pass_msg "scripts/run-test-suite.sh is executable"
else
  fail_msg "scripts/run-test-suite.sh is not executable"
fi

if [ -x "$RUNNER" ]; then
  # 1a. Strict-fail: a high-exit-code stub (250) MUST red the runner.
  WORK_FAIL="$(mktemp -d)"
  trap 'rm -rf "$WORK_FAIL"' EXIT
  cat > "$WORK_FAIL/test-ok-1.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$WORK_FAIL/test-ok-2.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$WORK_FAIL/test-boom.sh" <<'STUB'
#!/bin/bash
exit 250
STUB
  chmod +x "$WORK_FAIL"/*.sh

  inc
  TESTS_DIR="$WORK_FAIL" bash "$RUNNER" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass_msg "runner exits non-zero when a stub exits 250 (strict aggregate fail preserved)"
  else
    fail_msg "runner exited 0 despite a stub exiting 250 (strict-fail lost)"
  fi

  # 1b. All-passing stubs => runner exits 0.
  WORK_OK="$(mktemp -d)"
  cat > "$WORK_OK/test-ok-1.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
  cat > "$WORK_OK/test-ok-2.sh" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "$WORK_OK"/*.sh

  inc
  TESTS_DIR="$WORK_OK" bash "$RUNNER" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass_msg "runner exits 0 when all stubs pass"
  else
    fail_msg "runner exited $rc despite all stubs passing"
  fi
  rm -rf "$WORK_OK"
fi

# ---------------------------------------------------------------------------
# 2. ci.yml shape
# ---------------------------------------------------------------------------

if [ -f "$CI_YML" ]; then
  inc
  if grep -q 'run-test-suite.sh' "$CI_YML"; then
    pass_msg "ci.yml invokes scripts/run-test-suite.sh"
  else
    fail_msg "ci.yml does not invoke scripts/run-test-suite.sh"
  fi

  inc
  if grep -Eq 'for[[:space:]]+t[[:space:]]+in[[:space:]]+tests/test' "$CI_YML"; then
    fail_msg "ci.yml still contains an inline 'for t in tests/test' loop"
  else
    pass_msg "ci.yml has no inline 'for t in tests/test' loop"
  fi

  inc
  if grep -Eq '\|\|[[:space:]]*true' "$CI_YML"; then
    fail_msg "ci.yml still contains a '|| true' swallow"
  else
    pass_msg "ci.yml has no '|| true' swallow"
  fi

  inc
  if grep -q 'actions/cache' "$CI_YML"; then
    pass_msg "ci.yml caches the apt/jq setup (actions/cache present)"
  else
    fail_msg "ci.yml is missing an actions/cache step"
  fi

  # Path-filter: the heavy `tests` job is path-scoped; `guard` stays ungated.
  # The mechanism is a paths-filter action (job-level gate) rather than native
  # on.pull_request.paths — native paths would make the required `tests` check
  # silently DISAPPEAR on docs PRs (the #897 path-filter caveat). Instead the
  # `tests` job always runs but short-circuits to no-op success on docs/prose
  # diffs, so the required check still reports. Assert either the native
  # paths/paths-ignore form OR the paths-filter action + a code-gated `if:`.
  inc
  if grep -Eq '(paths|paths-ignore):' "$CI_YML" \
     || { grep -q 'paths-filter' "$CI_YML" && grep -Eq 'needs\.changes\.outputs\.code' "$CI_YML"; }; then
    pass_msg "ci.yml carries a path filter governing the tests job"
  else
    fail_msg "ci.yml has no path filter governing the tests job"
  fi

  # Guard always-on: assert no job-level `if:` gate sits inside the guard job.
  # Extract the guard job block (from `  guard:` to the next top-level job key).
  inc
  guard_block="$(awk '/^  guard:/{f=1} f&&/^  [a-zA-Z_]+:/&&!/^  guard:/{exit} f{print}' "$CI_YML")"
  if printf '%s\n' "$guard_block" | grep -Eq '^[[:space:]]+if:'; then
    fail_msg "guard job carries a job-level 'if:' gate (must stay always-on)"
  else
    pass_msg "guard job has no job-level 'if:' gate (stays always-on)"
  fi
else
  inc; fail_msg "ci.yml not found at $CI_YML"
fi

# ---------------------------------------------------------------------------
# 2b. Test-isolation regression pins (issue #897 Task 5).
#     These two tests reded ONLY under the parallel fan-out. Pin the fixes so a
#     revert reds again:
#       - test-fullsend-wave-execute-loop.sh used `echo "$VAR" | grep -q`, which
#         under `set -o pipefail` + CPU load returns 141 (SIGPIPE) when grep
#         short-circuits before echo finishes — a parallel-only flake. The fix
#         is here-string grep (`grep -q <<< "$VAR"`), no pipe, no SIGPIPE.
#       - test-run-queue-executor-terminal.sh used fixed /tmp/wt-911-* paths that
#         collide across concurrent runs; the fix routes them through a per-run
#         unique $STUB_WT_BASE.
# ---------------------------------------------------------------------------

FULLSEND_TEST="$ROOT/tests/test-fullsend-wave-execute-loop.sh"
TERMINAL_TEST="$ROOT/tests/test-run-queue-executor-terminal.sh"

inc
if [ -f "$FULLSEND_TEST" ] && grep -q 'echo "\$EXEC_REGION" | grep' "$FULLSEND_TEST"; then
  fail_msg "test-fullsend-wave-execute-loop.sh uses SIGPIPE-prone 'echo \$EXEC_REGION | grep' (parallel-flaky; use here-string grep)"
else
  pass_msg "test-fullsend-wave-execute-loop.sh avoids the SIGPIPE-prone echo|grep idiom"
fi

inc
if [ -f "$TERMINAL_TEST" ] && grep -Eq 'mkdir[^#]*"/tmp/wt-|rm -rf[^#]*"/tmp/wt-' "$TERMINAL_TEST"; then
  fail_msg "test-run-queue-executor-terminal.sh uses fixed /tmp/wt-* paths (parallel-colliding; use a per-run unique base dir)"
else
  pass_msg "test-run-queue-executor-terminal.sh uses a per-run unique worktree base (no fixed /tmp/wt-* paths)"
fi

# ---------------------------------------------------------------------------
# 3. pipeline.config.example mirror (dual-scan per CLAUDE.md #357)
# ---------------------------------------------------------------------------

if [ -f "$EXAMPLE" ]; then
  inc
  if grep -q 'run-test-suite.sh' "$EXAMPLE"; then
    pass_msg "example documents the parallel run-test-suite.sh form"
  else
    fail_msg "example does not document the parallel run-test-suite.sh form"
  fi

  inc
  if grep -Eqi 'gitignored|hand-patch|host-side' "$EXAMPLE"; then
    pass_msg "example notes the gitignored pipeline.config host-side hand-patch"
  else
    fail_msg "example does not note the gitignored host-side hand-patch callout"
  fi
else
  inc; fail_msg "pipeline.config.example not found"
fi

# Live host-only config: if present AND already migrated to the parallel runner,
# no-op; this scan is informational and never fails CI (the live file is
# gitignored and cannot ship in the PR — host-side hand-patch per CLAUDE.md).
if [ -f "$LIVE" ]; then
  if grep -q 'run-test-suite.sh' "$LIVE"; then
    echo "  INFO: live pipeline.config already uses run-test-suite.sh"
  else
    echo "  INFO: live pipeline.config not yet migrated (host-side hand-patch pending)"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
