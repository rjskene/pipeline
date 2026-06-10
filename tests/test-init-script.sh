#!/bin/bash
# Tests for scripts/init.sh — the backing script for the /pipeline:init command.
# Covers: preflight dependency checks, repo/base detection + config generation,
# .gitignore append (idempotent), label seeding delegation, and the doctor tail.
#
# Harness patterns are borrowed from tests/test-doctor-jq-check.sh (PATH-sandbox
# with selectively-masked deps) and tests/test-doctor-fix-labels.sh (recording
# gh shim that logs `gh label create` calls).
#
# NOTE: this script deliberately does NOT use `set -e`. Cases capture exit codes
# explicitly via `rc=$?` after a guarded subshell, so a non-zero step must not
# abort the whole run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/init.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: $HELPER does not exist"
  exit 1
fi

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Symlink the standard utility toolkit into a sandbox bin/ so a scrubbed
# PATH=$TMP/bin still resolves core utils. gh / jq / tmux are added per-case so
# system copies cannot leak through the preflight assertions.
SYS1=/usr/bin
SYS2=/bin
for util in bash sh grep head tail awk sed cat git basename dirname find sort uniq wc tr cut printf realpath stat ls rm mkdir chmod touch tee python3 env xargs mktemp date diff sleep cp mv uname; do
  if [ -x "$SYS1/$util" ]; then
    ln -sf "$SYS1/$util" "$TMP/bin/$util"
  elif [ -x "$SYS2/$util" ]; then
    ln -sf "$SYS2/$util" "$TMP/bin/$util"
  fi
done

# Recording gh shim — handles repo detection (nameWithOwner / defaultBranchRef),
# label create (logged to $SHIM_LOG), label list, and auth status. Used by the
# config-generation and label-seeding cases. Self-contained (no jq dependency).
make_gh_shim() {
  cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
ALL="$*"
case "$ALL" in
  *"repo view"*nameWithOwner*) echo "testowner/testrepo" ;;
  *"repo view"*defaultBranchRef*) echo "main" ;;
  "auth status"*) exit 0 ;;
  *"repo view"*) exit 0 ;;
  *"label list"*) printf '%s\n' "${LABELS_JSON:-}" ;;
  "label create"*)
    NAME="$3"; shift 3
    COLOR=""; DESC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --color) COLOR="$2"; shift 2 ;;
        --description) DESC="$2"; shift 2 ;;
        --repo) shift 2 ;;
        --force) shift ;;
        *) shift ;;
      esac
    done
    echo "$NAME|$COLOR|$DESC" >> "${SHIM_LOG:-/dev/null}"
    exit 0 ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$TMP/bin/gh"
}

make_jq_stub() {
  cat > "$TMP/bin/jq" <<'JQ'
#!/bin/bash
exit 0
JQ
  chmod +x "$TMP/bin/jq"
}

# ===========================================================================
# Task 1 — preflight dependency checks.
# ===========================================================================

# ---------------------------------------------------------------------------
# Case 1: jq masked off PATH (non-Windows) → PREFLIGHT: jq status=fail with an
#         install hint, non-zero exit, and NO pipeline.config written.
# ---------------------------------------------------------------------------
echo "Case 1: jq missing (hard fail)"
FX="$TMP/fx-no-jq"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim   # gh present; jq absent
(
  cd "$FX"
  export PATH="$TMP/bin"
  if command -v jq >/dev/null 2>&1; then echo "[harness] precondition: jq leaked" >&2; exit 88; fi
  export INIT_PLATFORM_OVERRIDE=linux
  bash "$HELPER" --preflight-only
) > "$FX/out" 2> "$FX/err"
rc=$?
out="$(cat "$FX/out" "$FX/err")"
if [ "$rc" -eq 88 ]; then
  fail_msg "case-1 precondition broken"
else
  grep -qE '^PREFLIGHT: jq status=fail' <<<"$out" \
    && pass_msg "no-jq: emits PREFLIGHT: jq status=fail" \
    || { fail_msg "no-jq: missing jq fail line"; echo "$out" | sed 's/^/    /'; }
  grep -qiE 'install|apt-get|brew|winget' <<<"$out" \
    && pass_msg "no-jq: carries an install hint" \
    || fail_msg "no-jq: no install hint"
  [ "$rc" -ne 0 ] && pass_msg "no-jq: non-zero exit ($rc)" || fail_msg "no-jq: exit was 0 (must fail-fast)"
  [ ! -f "$FX/pipeline.config" ] && pass_msg "no-jq: no pipeline.config written" || fail_msg "no-jq: config written despite preflight fail"
fi

# ---------------------------------------------------------------------------
# Case 2: gh masked off PATH → PREFLIGHT: gh status=fail, non-zero, no config.
# ---------------------------------------------------------------------------
echo "Case 2: gh missing (hard fail)"
FX="$TMP/fx-no-gh"; rm -rf "$FX"; mkdir -p "$FX"
rm -f "$TMP/bin/gh"      # mask gh
make_jq_stub            # jq present
(
  cd "$FX"
  export PATH="$TMP/bin"
  if command -v gh >/dev/null 2>&1; then echo "[harness] precondition: gh leaked" >&2; exit 88; fi
  export INIT_PLATFORM_OVERRIDE=linux
  bash "$HELPER" --preflight-only
) > "$FX/out" 2> "$FX/err"
rc=$?
out="$(cat "$FX/out" "$FX/err")"
if [ "$rc" -eq 88 ]; then
  fail_msg "case-2 precondition broken"
else
  grep -qE '^PREFLIGHT: gh status=fail' <<<"$out" \
    && pass_msg "no-gh: emits PREFLIGHT: gh status=fail" \
    || { fail_msg "no-gh: missing gh fail line"; echo "$out" | sed 's/^/    /'; }
  [ "$rc" -ne 0 ] && pass_msg "no-gh: non-zero exit ($rc)" || fail_msg "no-gh: exit was 0"
  [ ! -f "$FX/pipeline.config" ] && pass_msg "no-gh: no pipeline.config written" || fail_msg "no-gh: config written"
fi
rm -f "$TMP/bin/jq"

# ---------------------------------------------------------------------------
# Case 3: gh + jq present → pass lines for gh, jq, bash. Exit 0 (preflight-only).
# ---------------------------------------------------------------------------
echo "Case 3: all hard deps present"
FX="$TMP/fx-ok"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
make_jq_stub
(
  cd "$FX"
  export PATH="$TMP/bin"
  export INIT_PLATFORM_OVERRIDE=linux
  bash "$HELPER" --preflight-only
) > "$FX/out" 2> "$FX/err"
rc=$?
out="$(cat "$FX/out" "$FX/err")"
grep -qE '^PREFLIGHT: gh status=pass'   <<<"$out" && pass_msg "ok: gh pass"   || { fail_msg "ok: missing gh pass"; echo "$out" | sed 's/^/    /'; }
grep -qE '^PREFLIGHT: jq status=pass'   <<<"$out" && pass_msg "ok: jq pass"   || fail_msg "ok: missing jq pass"
grep -qE '^PREFLIGHT: bash status=pass' <<<"$out" && pass_msg "ok: bash pass" || fail_msg "ok: missing bash pass"
[ "$rc" -eq 0 ] && pass_msg "ok: exit 0" || fail_msg "ok: non-zero exit ($rc)"

# ---------------------------------------------------------------------------
# Case 4: tmux absent → PREFLIGHT: tmux status=warn (NOT fail) with the
#         queue-runner / Linux-container guidance. Warn does not gate exit.
# ---------------------------------------------------------------------------
echo "Case 4: tmux absent (warn, not fail)"
FX="$TMP/fx-no-tmux"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
make_jq_stub
rm -f "$TMP/bin/tmux"   # ensure tmux not resolvable
(
  cd "$FX"
  export PATH="$TMP/bin"
  export INIT_PLATFORM_OVERRIDE=linux
  bash "$HELPER" --preflight-only
) > "$FX/out" 2> "$FX/err"
rc=$?
out="$(cat "$FX/out" "$FX/err")"
grep -qE '^PREFLIGHT: tmux status=warn' <<<"$out" \
  && pass_msg "no-tmux: emits PREFLIGHT: tmux status=warn" \
  || { fail_msg "no-tmux: missing tmux warn line"; echo "$out" | sed 's/^/    /'; }
grep -qiE 'queue|container|linux' <<<"$out" \
  && pass_msg "no-tmux: carries queue-runner/container guidance" \
  || fail_msg "no-tmux: no guidance"
[ "$rc" -eq 0 ] && pass_msg "no-tmux: warn does not gate exit (exit 0)" || fail_msg "no-tmux: warn caused non-zero exit ($rc)"

# ---------------------------------------------------------------------------
# Case 5: simulated Windows shape — jq resolvable on a Windows-style dir but
#         NOT on the bash PATH → PREFLIGHT: jq status=warn with the
#         `cp jq.exe /usr/bin/` guidance (advisory, not a hard fail).
# ---------------------------------------------------------------------------
echo "Case 5: Windows jq-not-on-bash-PATH (warn)"
FX="$TMP/fx-win"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
rm -f "$TMP/bin/jq"          # jq NOT on bash PATH
WINJQ="$TMP/winpath"; rm -rf "$WINJQ"; mkdir -p "$WINJQ"
cat > "$WINJQ/jq.exe" <<'EXE'
#!/bin/bash
exit 0
EXE
chmod +x "$WINJQ/jq.exe"
(
  cd "$FX"
  export PATH="$TMP/bin"
  if command -v jq >/dev/null 2>&1; then echo "[harness] precondition: jq leaked" >&2; exit 88; fi
  export INIT_PLATFORM_OVERRIDE=windows
  export INIT_WIN_JQ_DIRS="$WINJQ"
  bash "$HELPER" --preflight-only
) > "$FX/out" 2> "$FX/err"
rc=$?
out="$(cat "$FX/out" "$FX/err")"
if [ "$rc" -eq 88 ]; then
  fail_msg "case-5 precondition broken"
else
  grep -qE '^PREFLIGHT: jq status=warn' <<<"$out" \
    && pass_msg "win-jq: emits PREFLIGHT: jq status=warn" \
    || { fail_msg "win-jq: missing jq warn line"; echo "$out" | sed 's/^/    /'; }
  grep -qE 'jq\.exe' <<<"$out" \
    && pass_msg "win-jq: carries cp jq.exe guidance" \
    || fail_msg "win-jq: no cp jq.exe guidance"
fi

# ===========================================================================
# Task 2 — repo/base detection + config generation.
# Base branch is resolved from the gh shim (defaultBranchRef → main), so no
# local git repo is required in these fixtures.
# ===========================================================================

# ---------------------------------------------------------------------------
# Case 6: non-interactive run generates pipeline.config with repo/base
#         prefilled from gh, no-op test/typecheck defaults when "no tests",
#         empty CI gate when "no CI", and a bash -n-clean, re-sourceable file.
# ---------------------------------------------------------------------------
echo "Case 6: config generation (no tests, no CI)"
FX="$TMP/fx-cfg"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
make_jq_stub
(
  cd "$FX"
  export PATH="$TMP/bin"
  export INIT_PLATFORM_OVERRIDE=linux
  export INIT_NON_INTERACTIVE=1
  export INIT_HAS_TESTS=n
  export INIT_HAS_CI=n
  bash "$HELPER" --config-only
) > "$FX/out" 2> "$FX/err"
rc=$?
if [ -f "$FX/pipeline.config" ]; then
  pass_msg "cfg: pipeline.config written"
  cfg="$(cat "$FX/pipeline.config")"
  grep -qE '^PIPELINE_REPO="testowner/testrepo"' <<<"$cfg" \
    && pass_msg "cfg: PIPELINE_REPO prefilled from nameWithOwner" \
    || { fail_msg "cfg: PIPELINE_REPO wrong"; echo "$cfg" | grep -i repo | sed 's/^/    /'; }
  grep -qE '^PIPELINE_BASE_BRANCH="main"' <<<"$cfg" \
    && pass_msg "cfg: PIPELINE_BASE_BRANCH prefilled from defaultBranchRef (main, not staging)" \
    || { fail_msg "cfg: PIPELINE_BASE_BRANCH not detected"; echo "$cfg" | grep -i base | sed 's/^/    /'; }
  grep -qE '^PIPELINE_TEST_CMD="true"' <<<"$cfg" \
    && pass_msg "cfg: no-tests → PIPELINE_TEST_CMD=true" || fail_msg "cfg: PIPELINE_TEST_CMD not no-op"
  grep -qE '^PIPELINE_TYPECHECK_CMD="true"' <<<"$cfg" \
    && pass_msg "cfg: no-tests → PIPELINE_TYPECHECK_CMD=true" || fail_msg "cfg: PIPELINE_TYPECHECK_CMD not no-op"
  grep -qE '^PIPELINE_CI_CHECK_ENABLED=""' <<<"$cfg" \
    && pass_msg "cfg: no-CI → PIPELINE_CI_CHECK_ENABLED empty" || fail_msg "cfg: PIPELINE_CI_CHECK_ENABLED not empty"
  grep -qE '^PIPELINE_WORKTREE_PREFIX=' <<<"$cfg" \
    && pass_msg "cfg: carries example defaults (PIPELINE_WORKTREE_PREFIX)" || fail_msg "cfg: missing example defaults"
  bash -n "$FX/pipeline.config" 2>/dev/null && pass_msg "cfg: bash -n clean" || fail_msg "cfg: bash -n errors"
  ( source "$FX/pipeline.config" ) >/dev/null 2>&1 && pass_msg "cfg: re-sourceable" || fail_msg "cfg: source failed"

  # --- issue #734: generated config seeds a COMMENTED PIPELINE_PRICE_* block ---
  # Discoverability anchor for cost-latency-report.sh --tokenomics overrides.
  # Divergence from pipeline.config.example: in the GENERATED config every price
  # line (Opus included) is commented out, so baked-in defaults stay authoritative
  # until the operator opts in. (Example keeps Opus live; it is never sourced.)
  grep -qE '^#.*[Pp]er-model token pricing' <<<"$cfg" \
    && pass_msg "cfg: PRICE block header comment present" \
    || fail_msg "cfg: PRICE block header comment missing"

  price_keys=(
    PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT
    PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT
    PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION
    PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ
    PIPELINE_PRICE_CLAUDE_SONNET_4_6_INPUT
    PIPELINE_PRICE_CLAUDE_SONNET_4_6_OUTPUT
    PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_CREATION
    PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_READ
    PIPELINE_PRICE_CLAUDE_HAIKU_4_5_INPUT
    PIPELINE_PRICE_CLAUDE_HAIKU_4_5_OUTPUT
    PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_CREATION
    PIPELINE_PRICE_CLAUDE_HAIKU_4_5_CACHE_READ
  )
  price_all_present=1
  price_all_commented=1
  for k in "${price_keys[@]}"; do
    # present in some form (commented or not)
    grep -qE "^[[:space:]]*#?[[:space:]]*${k}=" <<<"$cfg" || price_all_present=0
    # MUST be commented out in the generated config (no live, uncommented line)
    if grep -qE "^[[:space:]]*${k}=" <<<"$cfg"; then price_all_commented=0; fi
  done
  [ "$price_all_present" -eq 1 ] \
    && pass_msg "cfg: all 12 PIPELINE_PRICE_* keys present" \
    || { fail_msg "cfg: missing PIPELINE_PRICE_* keys"; echo "$cfg" | grep -i price | sed 's/^/    /'; }
  [ "$price_all_commented" -eq 1 ] \
    && pass_msg "cfg: all PIPELINE_PRICE_* lines commented (opt-in; no behavior change)" \
    || { fail_msg "cfg: a PIPELINE_PRICE_* line is live/uncommented"; echo "$cfg" | grep -iE '^[[:space:]]*PIPELINE_PRICE' | sed 's/^/    /'; }
else
  fail_msg "cfg: pipeline.config NOT written (rc=$rc)"; cat "$FX/err" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 7: has-tests=y honors the supplied test/typecheck/install commands.
# ---------------------------------------------------------------------------
echo "Case 7: config generation (with tests + CI)"
FX="$TMP/fx-cfg2"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
make_jq_stub
(
  cd "$FX"
  export PATH="$TMP/bin"
  export INIT_PLATFORM_OVERRIDE=linux
  export INIT_NON_INTERACTIVE=1
  export INIT_HAS_TESTS=y
  export INIT_HAS_CI=y
  export INIT_TEST_CMD="pytest -q"
  export INIT_TYPECHECK_CMD="mypy ."
  export INIT_INSTALL_CMD="pip install -e ."
  bash "$HELPER" --config-only
) > "$FX/out" 2> "$FX/err"
if [ -f "$FX/pipeline.config" ]; then
  cfg="$(cat "$FX/pipeline.config")"
  grep -qE '^PIPELINE_TEST_CMD="pytest -q"' <<<"$cfg" && pass_msg "cfg2: test cmd honored" || fail_msg "cfg2: test cmd not honored"
  grep -qE '^PIPELINE_TYPECHECK_CMD="mypy \."' <<<"$cfg" && pass_msg "cfg2: typecheck cmd honored" || fail_msg "cfg2: typecheck cmd not honored"
  grep -qE '^PIPELINE_CI_CHECK_ENABLED="true"' <<<"$cfg" && pass_msg "cfg2: CI gate kept" || fail_msg "cfg2: CI gate not kept"
else
  fail_msg "cfg2: pipeline.config NOT written"
fi

# ---------------------------------------------------------------------------
# Case 8: refuses to clobber an existing pipeline.config without --force.
# ---------------------------------------------------------------------------
echo "Case 8: existing config not clobbered without --force"
FX="$TMP/fx-clobber"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
make_jq_stub
printf 'PIPELINE_REPO="pre/existing"\n' > "$FX/pipeline.config"
(
  cd "$FX"
  export PATH="$TMP/bin"
  export INIT_PLATFORM_OVERRIDE=linux
  export INIT_NON_INTERACTIVE=1 INIT_HAS_TESTS=n INIT_HAS_CI=n
  bash "$HELPER" --config-only
) > "$FX/out" 2> "$FX/err"
rc=$?
grep -qE '^PIPELINE_REPO="pre/existing"' "$FX/pipeline.config" \
  && pass_msg "clobber: existing config preserved (no --force)" \
  || fail_msg "clobber: existing config overwritten without --force"
[ "$rc" -ne 0 ] && pass_msg "clobber: non-zero exit signals refusal" || fail_msg "clobber: exit 0 despite refusing"

# ===========================================================================
# Task 3 — .gitignore append + label seeding + doctor tail.
# ===========================================================================

# ---------------------------------------------------------------------------
# Case 9: full run appends pipeline.config to .gitignore (idempotent), seeds
#         the 17 canonical labels via doctor.sh --fix labels, and tails the
#         read-only doctor audit (=== Summary ===). 17 since #997 added
#         needs-debug to doctor.sh LABEL_TABLE (which init delegates to).
# ---------------------------------------------------------------------------
echo "Case 9: gitignore + label seed + doctor tail"
FX="$TMP/fx-full"; rm -rf "$FX"; mkdir -p "$FX"
make_gh_shim
# Use the REAL jq for the doctor tail (doctor parses JSON); only gh is shimmed.
rm -f "$TMP/bin/jq"
run_full() {
  (
    cd "$FX"
    SHIM_LOG="$FX/shim.log" PATH="$TMP/bin:$PATH" \
      env INIT_PLATFORM_OVERRIDE=linux INIT_NON_INTERACTIVE=1 INIT_HAS_TESTS=n INIT_HAS_CI=n \
      bash "$HELPER" --force
  ) > "$FX/out" 2>&1
  echo "$?" > "$FX/rc"
}
: > "$FX/shim.log"
run_full
out="$(cat "$FX/out")"
# gitignore appended.
grep -Fxq "pipeline.config" "$FX/.gitignore" 2>/dev/null \
  && pass_msg "full: pipeline.config appended to .gitignore" \
  || { fail_msg "full: .gitignore missing pipeline.config"; cat "$FX/.gitignore" 2>/dev/null | sed 's/^/    /'; }
# label seeding fired 17 create calls.
count=$(grep -c '|' "$FX/shim.log" 2>/dev/null || echo 0)
[ "$count" = "17" ] && pass_msg "full: 17 gh label create calls" || { fail_msg "full: got $count label create calls (want 17)"; echo "$out" | tail -25 | sed 's/^/    /'; }
# doctor tail surfaced.
grep -q '=== Summary ===' <<<"$out" \
  && pass_msg "full: doctor tail surfaced (=== Summary ===)" \
  || { fail_msg "full: no doctor tail"; echo "$out" | tail -20 | sed 's/^/    /'; }

# Second run → .gitignore entry not duplicated (idempotent).
echo "Case 10: gitignore append is idempotent"
: > "$FX/shim.log"
run_full
dupes=$(grep -Fxc "pipeline.config" "$FX/.gitignore" 2>/dev/null || echo 0)
[ "$dupes" = "1" ] && pass_msg "idempotent: single pipeline.config line after re-run" || fail_msg "idempotent: $dupes pipeline.config lines"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
