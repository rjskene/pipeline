#!/bin/bash
set -uo pipefail

# Regression guard for issue #1208 Task 1 — chunked FOREGROUND test-suite runner.
#
# #1208's failure class: the full ~590-file suite does not fit inside one
# Bash-call timeout, so agents reach for `run_in_background` — and a backgrounded
# suite is the direct trigger of the narrate-and-yield drop-out (the agent has
# nothing left to do in-turn and yields with work uncommitted). The durable fix
# is a MECHANISM, not more prose: `scripts/run-test-suite.sh --chunk k/n` runs a
# deterministic 1/n slice of the corpus in the FOREGROUND so the operator/agent
# can run `--chunk 1/4 … --chunk 4/4` as four sequential foreground Bash calls.
#
# Contracts pinned here:
#   1. `--chunk k/n` emits exactly one `CHUNK=<k>/<n> FILES=<count> RESULT=<pass|fail>`
#      summary line and exits 0/1 accordingly.
#   2. The partition is DISJOINT and TOTAL: the union of all n chunks equals the
#      default (unchunked) file set, and no file lands in two chunks.
#   3. The partition is DETERMINISTIC across invocations.
#   4. STRICT aggregate fail survives per-chunk (a stub exiting 250 reds only its
#      own chunk).
#   5. The Phase-2 serial-retry flake semantics (#897) survive in chunk mode.
#   6. Argument validation: a malformed / out-of-range spec exits 2 with an
#      `invalid --chunk` diagnostic and emits NO `CHUNK=` line.
#   7. DEFAULT mode is byte-compatible: no `--chunk` ⇒ no `CHUNK=` line at all.
#   8. The `TESTS_DIR=` env form still works alongside `--chunk`.
#   9. `pipeline.config.example` documents the chunked form.
#
# STRIDE RULE (the partition contract both this test and the implementation
# depend on): with the file list in the existing `find | sort -z` order, 0-based
# index `i` belongs to chunk `(i % n) + 1`. So for stubs
# test-01.sh test-02.sh test-03.sh test-04.sh with n=2:
#   chunk 1 = {test-01.sh, test-03.sh}   chunk 2 = {test-02.sh, test-04.sh}
#
# All runner exercises use `mktemp -d` stub dirs — NEVER the real tests/ dir.
# Mirrors the ROOT / pass_msg / fail_msg / inc / `exit 1` shape of
# tests/test-ci-parallel-runner.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/scripts/run-test-suite.sh"
EXAMPLE="$ROOT/pipeline.config.example"

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

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

OUT_SEQ=0
RC=0
RUN_OUT=""

# Build a dir of stubs that each echo a `RANFILE:<name>` marker and exit 0.
mk_echo_stubs() {
  local d="$1"; shift
  mkdir -p "$d"
  local n
  for n in "$@"; do
    printf '#!/bin/bash\necho "RANFILE:%s"\nexit 0\n' "$n" > "$d/$n"
  done
  chmod +x "$d"/*.sh
}

# Add one stub that echoes its marker then exits with the given code.
mk_exit_stub() {
  local d="$1" n="$2" code="$3"
  mkdir -p "$d"
  printf '#!/bin/bash\necho "RANFILE:%s"\nexit %s\n' "$n" "$code" > "$d/$n"
  chmod +x "$d/$n"
}

# Run the runner in the FOREGROUND, capturing combined stdout+stderr to a file.
# (Combined capture deliberately: the `invalid --chunk` diagnostic goes to
# stderr per the contract, and combined capture matches it either way.)
run_runner() {
  OUT_SEQ=$((OUT_SEQ + 1))
  RUN_OUT="$WORK_ROOT/out-$OUT_SEQ.txt"
  bash "$RUNNER" "$@" > "$RUN_OUT" 2>&1
  RC=$?
}

# Same, but supplying the tests dir via the TESTS_DIR env var instead of argv.
run_runner_env() {
  local dir="$1"; shift
  OUT_SEQ=$((OUT_SEQ + 1))
  RUN_OUT="$WORK_ROOT/out-$OUT_SEQ.txt"
  TESTS_DIR="$dir" bash "$RUNNER" "$@" > "$RUN_OUT" 2>&1
  RC=$?
}

# Extract the sorted-unique set of RANFILE markers from a captured run.
markers() { grep -o 'RANFILE:[^[:space:]]*' "$1" 2>/dev/null | sort -u > "$2"; }

# ---------------------------------------------------------------------------
# 1 + 2. Summary token, disjointness and total coverage.
# ---------------------------------------------------------------------------

COV="$WORK_ROOT/cov"
mk_echo_stubs "$COV" test-01.sh test-02.sh test-03.sh test-04.sh

run_runner --chunk 1/2 "$COV"; c1_rc="$RC"; c1_out="$RUN_OUT"
markers "$c1_out" "$WORK_ROOT/c1.txt"

run_runner --chunk 2/2 "$COV"; c2_rc="$RC"; c2_out="$RUN_OUT"
markers "$c2_out" "$WORK_ROOT/c2.txt"

run_runner "$COV"; def_rc="$RC"; def_out="$RUN_OUT"
markers "$def_out" "$WORK_ROOT/def.txt"

# 1) `--chunk 1/2` over a 4-stub dir: exit 0 + one line carrying all three of
#    CHUNK=1/2, FILES=2, RESULT=pass.
inc
if [ "$c1_rc" -eq 0 ] && grep -Eq 'CHUNK=1/2.*FILES=2.*RESULT=pass' "$c1_out"; then
  pass_msg "chunk-summary: --chunk 1/2 exits 0 and prints CHUNK=1/2 FILES=2 RESULT=pass"
else
  fail_msg "chunk-summary: --chunk 1/2 exited $c1_rc without a 'CHUNK=1/2 FILES=2 RESULT=pass' line"
fi

# 2) Disjoint + total coverage against the default (unchunked) run.
sort -u "$WORK_ROOT/c1.txt" "$WORK_ROOT/c2.txt" > "$WORK_ROOT/union.txt"
comm -12 "$WORK_ROOT/c1.txt" "$WORK_ROOT/c2.txt" > "$WORK_ROOT/overlap.txt"

inc
if [ -s "$WORK_ROOT/c1.txt" ] && [ -s "$WORK_ROOT/c2.txt" ] \
   && [ ! -s "$WORK_ROOT/overlap.txt" ] \
   && [ "$def_rc" -eq 0 ] \
   && cmp -s "$WORK_ROOT/union.txt" "$WORK_ROOT/def.txt"; then
  pass_msg "chunk-partition: chunks 1/2 + 2/2 are disjoint and their union equals the default run's file set"
else
  fail_msg "chunk-partition: chunk 1 ($(wc -l < "$WORK_ROOT/c1.txt")) / chunk 2 ($(wc -l < "$WORK_ROOT/c2.txt")) / overlap ($(wc -l < "$WORK_ROOT/overlap.txt")) do not partition the default set ($(wc -l < "$WORK_ROOT/def.txt"))"
fi

# ---------------------------------------------------------------------------
# 3. Determinism — same dir, same chunk spec, same file set.
# ---------------------------------------------------------------------------

run_runner --chunk 1/2 "$COV"
markers "$RUN_OUT" "$WORK_ROOT/c1-again.txt"

inc
if [ -s "$WORK_ROOT/c1-again.txt" ] && cmp -s "$WORK_ROOT/c1.txt" "$WORK_ROOT/c1-again.txt"; then
  pass_msg "chunk-determinism: two --chunk 1/2 invocations select the same file set"
else
  fail_msg "chunk-determinism: --chunk 1/2 selected a different file set on the second invocation"
fi

# ---------------------------------------------------------------------------
# 4. STRICT aggregate fail is per-chunk.
#    test-02.sh sits at 0-based index 1 => chunk 2 under the stride rule.
# ---------------------------------------------------------------------------

FAILDIR="$WORK_ROOT/faildir"
mk_echo_stubs "$FAILDIR" test-01.sh test-03.sh test-04.sh
mk_exit_stub  "$FAILDIR" test-02.sh 250

run_runner --chunk 2/2 "$FAILDIR"; f2_rc="$RC"; f2_out="$RUN_OUT"
run_runner --chunk 1/2 "$FAILDIR"; f1_rc="$RC"; f1_out="$RUN_OUT"

inc
if [ "$f2_rc" -ne 0 ] && grep -Eq 'CHUNK=2/2.*RESULT=fail' "$f2_out"; then
  pass_msg "chunk-strict-fail: the chunk holding the exit-250 stub exits non-zero with RESULT=fail"
else
  fail_msg "chunk-strict-fail: --chunk 2/2 exited $f2_rc without a 'CHUNK=2/2 ... RESULT=fail' line (stride rule: index 1 => chunk 2)"
fi

inc
if [ "$f1_rc" -eq 0 ] && grep -Eq 'CHUNK=1/2.*RESULT=pass' "$f1_out"; then
  pass_msg "chunk-strict-fail: the sibling chunk is unaffected (exit 0, RESULT=pass)"
else
  fail_msg "chunk-strict-fail: --chunk 1/2 exited $f1_rc without a 'CHUNK=1/2 ... RESULT=pass' line (a sibling chunk's failure leaked)"
fi

# ---------------------------------------------------------------------------
# 5. Phase-2 serial-retry flake semantics survive in chunk mode (#897 case 1c).
# ---------------------------------------------------------------------------

FLAKEDIR="$WORK_ROOT/flakedir"
mkdir -p "$FLAKEDIR"
cat > "$FLAKEDIR/test-flaky.sh" <<'STUB'
#!/bin/bash
# Fails the first time it is run, passes thereafter (marker in its own dir).
marker="$(dirname "$0")/.flaky-seen"
if [ ! -f "$marker" ]; then
  touch "$marker"
  exit 1
fi
exit 0
STUB
chmod +x "$FLAKEDIR"/*.sh

run_runner --chunk 1/1 "$FLAKEDIR"; flake_rc="$RC"; flake_out="$RUN_OUT"

inc
if [ "$flake_rc" -eq 0 ] && grep -Eq 'CHUNK=1/1.*RESULT=pass' "$flake_out"; then
  pass_msg "chunk-flake: a recovered-on-retry flake does not red --chunk 1/1 (serial-retry semantics preserved)"
else
  fail_msg "chunk-flake: --chunk 1/1 exited $flake_rc on a stub that passes on retry (serial-retry semantics lost in chunk mode)"
fi

# ---------------------------------------------------------------------------
# 6. Argument validation — exit 2, `invalid --chunk` diagnostic, no CHUNK= line.
# ---------------------------------------------------------------------------

for spec in '0/3' '4/3' '1/0' 'x/3' '2'; do
  run_runner --chunk "$spec" "$COV"; v_rc="$RC"; v_out="$RUN_OUT"
  inc
  if [ "$v_rc" -eq 2 ] && grep -Fq -- 'invalid --chunk' "$v_out" && ! grep -Fq -- 'CHUNK=' "$v_out"; then
    pass_msg "chunk-argcheck: --chunk $spec exits 2 with an 'invalid --chunk' diagnostic and no CHUNK= line"
  else
    fail_msg "chunk-argcheck: --chunk $spec exited $v_rc (want 2) / missing 'invalid --chunk' / emitted a CHUNK= line"
  fi
done

# ---------------------------------------------------------------------------
# 7. Default mode unchanged — no CHUNK= token, strict fail intact.
# ---------------------------------------------------------------------------

inc
if [ "$def_rc" -eq 0 ] && ! grep -Fq -- 'CHUNK=' "$def_out"; then
  pass_msg "default-mode: no --chunk ⇒ exit 0 on all-passing stubs and NO CHUNK= line"
else
  fail_msg "default-mode: unchunked run exited $def_rc and/or leaked a CHUNK= line (default output must be unchanged)"
fi

HARDDIR="$WORK_ROOT/harddir"
mk_echo_stubs "$HARDDIR" test-01.sh
mk_exit_stub  "$HARDDIR" test-boom.sh 1

run_runner "$HARDDIR"; hard_rc="$RC"; hard_out="$RUN_OUT"

inc
if [ "$hard_rc" -ne 0 ] && ! grep -Fq -- 'CHUNK=' "$hard_out"; then
  pass_msg "default-mode: unchunked run still reds a deterministically-failing stub, with no CHUNK= line"
else
  fail_msg "default-mode: unchunked run exited $hard_rc on a failing stub and/or leaked a CHUNK= line"
fi

# ---------------------------------------------------------------------------
# 8. TESTS_DIR env form still works in chunk mode.
# ---------------------------------------------------------------------------

ENVDIR="$WORK_ROOT/envdir"
mk_echo_stubs "$ENVDIR" test-01.sh test-02.sh

run_runner_env "$ENVDIR" --chunk 1/1; env_rc="$RC"; env_out="$RUN_OUT"
markers "$env_out" "$WORK_ROOT/env.txt"

run_runner --chunk 1/1 "$ENVDIR"; pos_rc="$RC"; pos_out="$RUN_OUT"
markers "$pos_out" "$WORK_ROOT/pos.txt"

inc
if [ "$env_rc" -eq 0 ] && [ "$pos_rc" -eq 0 ] \
   && grep -Eq 'CHUNK=1/1.*FILES=2.*RESULT=pass' "$env_out" \
   && grep -Eq 'CHUNK=1/1.*FILES=2.*RESULT=pass' "$pos_out" \
   && [ -s "$WORK_ROOT/env.txt" ] \
   && cmp -s "$WORK_ROOT/env.txt" "$WORK_ROOT/pos.txt"; then
  pass_msg "chunk-env-form: TESTS_DIR=<dir> ... --chunk 1/1 behaves identically to the positional form"
else
  fail_msg "chunk-env-form: TESTS_DIR env form (exit $env_rc) diverges from the positional form (exit $pos_rc) under --chunk 1/1"
fi

# ---------------------------------------------------------------------------
# 9. pipeline.config.example documents the chunked form.
#    Scans the TRACKED example ONLY — never the gitignored live pipeline.config
#    (that would impose a host-side hand-apply requirement; see CLAUDE.md
#    "Configuration conventions").
# ---------------------------------------------------------------------------

inc
if [ -f "$EXAMPLE" ] && grep -Fq -- '--chunk' "$EXAMPLE"; then
  pass_msg "example: pipeline.config.example documents the --chunk form"
else
  fail_msg "example: pipeline.config.example does not mention --chunk"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
