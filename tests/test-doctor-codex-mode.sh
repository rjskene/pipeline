#!/bin/bash
# Tests for the doctor Codex-mode checks (#985, Leg 6 of the Codex dual-target
# migration). All Codex checks live behind a single
# `if [ "$PIPELINE_HARNESS" = "codex" ]` gate; Claude Code runs emit ZERO new
# CHECK lines. Fixtures set PIPELINE_HARNESS=codex in pipeline.config (the
# authoritative override read by scripts/platform.sh) and point the config-file
# reads at fixture TOML via PIPELINE_CODEX_CONFIG.
#
# Checks under test (one task each):
#   codex_installed              — `codex` CLI on PATH                (FAIL grade)
#   codex_multi_agent_enabled    — [features] multi_agent = true      (FAIL grade)
#   codex_hooks_wired            — [[hooks.*]] wires a load-bearing py (FAIL grade)
#   codex_hooks_trusted          — trust marker present                (WARN grade)
#   codex_mcp_reachable          — [mcp_servers.*] table present       (WARN grade)
#
# Modeled on tests/test-doctor-base-branch-enforcement.sh (fresh_fx shape).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

if [ ! -f "$DOCTOR" ]; then
  echo "FAIL: $DOCTOR does not exist"
  exit 1
fi

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ----- Shared shim bin: gh (always succeeds) + codex (present by default) ------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  auth)    [ "$2" = "status" ] && exit 0 ;;
  repo)    [ "$2" = "view" ] && exit 0 ;;
  label)   [ "$2" = "list" ] && { echo '[]'; exit 0; } ;;
  version) echo "gh version 2.40.0 (2024-01-01)"; echo "https://github.com/cli/cli/releases/tag/v2.40.0"; exit 0 ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"
# A codex shim — its mere presence on PATH is what codex_installed probes.
cat > "$TMP/bin/codex" <<'CODEX'
#!/bin/bash
echo "codex 0.0.0"
exit 0
CODEX
chmod +x "$TMP/bin/codex"

# Fresh fixture: fake consumer project (git-init'd, pipeline.config) + plugin
# root + a fake CODEX_HOME. $1 = fixture name; $2 = harness value to write into
# pipeline.config (default "codex").
fresh_fx() {
  local name="$1"
  local harness="${2:-codex}"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.codex" "$root/plugin/hooks" "$root/plugin/.claude-plugin" \
           "$root/codex-home"
  ( cd "$root/proj" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git commit --allow-empty -q -m init \
      && (git branch -q staging 2>/dev/null || git checkout -q -b staging) ) >/dev/null 2>&1
  cat > "$root/proj/pipeline.config" <<CFG
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
PIPELINE_HARNESS="$harness"
CFG
  echo "$root"
}

# Run doctor inside a fixture's proj/ with the codex-aware env. Extra env may be
# appended as "VAR=value" args. Captures combined output to $root/out.
run_doctor() {
  local root="$1"; shift
  local binpath="$TMP/bin"
  (
    cd "$root/proj"
    env PATH="$binpath:$PATH" \
        CLAUDE_PLUGIN_ROOT="$root/plugin" \
        CODEX_HOME="$root/codex-home" \
        "$@" \
        bash "$DOCTOR"
  ) > "$root/out" 2>&1 || true
}

# ===========================================================================
# Task 3 — platform gate + codex_installed
# ===========================================================================

# --- (3a) codex present + harness=codex → codex_installed=pass --------------
echo "Case 3a: codex on PATH, harness=codex → codex_installed=pass"
ROOT=$(fresh_fx fx-3a-present codex)
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_installed status=pass' <<<"$out"; then
  pass_msg "(3a) codex present → codex_installed=pass"
else
  fail_msg "(3a) expected codex_installed=pass"
  echo "$out" | grep -E 'codex_installed' | sed 's/^/    /' || true
fi

# --- (3b) codex absent + harness=codex → codex_installed=fail ---------------
echo "Case 3b: codex NOT on PATH, harness=codex → codex_installed=fail"
ROOT=$(fresh_fx fx-3b-absent codex)
# Per-case bin dir WITHOUT a codex shim (still has gh).
mkdir -p "$TMP/bin-nocodex"
cp "$TMP/bin/gh" "$TMP/bin-nocodex/gh"
(
  cd "$ROOT/proj"
  env PATH="$TMP/bin-nocodex:/usr/bin:/bin" \
      CLAUDE_PLUGIN_ROOT="$ROOT/plugin" \
      CODEX_HOME="$ROOT/codex-home" \
      bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_installed status=fail' <<<"$out"; then
  pass_msg "(3b) codex absent → codex_installed=fail"
else
  fail_msg "(3b) expected codex_installed=fail"
  echo "$out" | grep -E 'codex_installed' | sed 's/^/    /' || true
fi

# --- (3c) harness=claude → NO codex_* lines emitted (harness-skip guard) -----
echo "Case 3c: harness=claude → no codex_* CHECK lines"
ROOT=$(fresh_fx fx-3c-claude claude)
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_' <<<"$out"; then
  fail_msg "(3c) expected NO codex_* lines under harness=claude"
  echo "$out" | grep -E '^CHECK: codex_' | sed 's/^/    /' || true
else
  pass_msg "(3c) harness=claude emits zero codex_* checks"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
