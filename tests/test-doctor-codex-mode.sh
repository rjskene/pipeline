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

# ===========================================================================
# Task 4 — codex_multi_agent_enabled
# ===========================================================================

# --- (4a) [features] multi_agent = true → pass ------------------------------
echo "Case 4a: [features] multi_agent = true → codex_multi_agent_enabled=pass"
ROOT=$(fresh_fx fx-4a-on codex)
cat > "$ROOT/codex-home/config.toml" <<'TOML'
[features]
multi_agent = true
TOML
run_doctor "$ROOT" "PIPELINE_CODEX_CONFIG=$ROOT/codex-home/config.toml"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_multi_agent_enabled status=pass' <<<"$out"; then
  pass_msg "(4a) multi_agent=true → codex_multi_agent_enabled=pass"
else
  fail_msg "(4a) expected codex_multi_agent_enabled=pass"
  echo "$out" | grep -E 'codex_multi_agent_enabled' | sed 's/^/    /' || true
fi

# --- (4b) multi_agent absent/false → fail naming [features] multi_agent -----
echo "Case 4b: multi_agent = false → codex_multi_agent_enabled=fail"
ROOT=$(fresh_fx fx-4b-off codex)
cat > "$ROOT/codex-home/config.toml" <<'TOML'
[features]
multi_agent = false

[mcp_servers.playwright]
command = "npx"
TOML
run_doctor "$ROOT" "PIPELINE_CODEX_CONFIG=$ROOT/codex-home/config.toml"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_multi_agent_enabled status=fail.*\[features\] multi_agent' <<<"$out"; then
  pass_msg "(4b) multi_agent=false → fail naming [features] multi_agent"
else
  fail_msg "(4b) expected codex_multi_agent_enabled=fail mentioning '[features] multi_agent'"
  echo "$out" | grep -E 'codex_multi_agent_enabled' | sed 's/^/    /' || true
fi

# ===========================================================================
# Task 5 — codex_hooks_wired + codex_hooks_trusted
# ===========================================================================

# Helper: write a repo-local .codex/config.toml that wires the load-bearing
# enforcement hooks via the _run.sh launcher (array-form command), mirroring the
# committed manifest shape.
write_repo_hooks() {
  local proj="$1"
  mkdir -p "$proj/.codex"
  cat > "$proj/.codex/config.toml" <<'TOML'
[[hooks.PreToolUse]]
matcher = "Bash"
command = ["hooks/_run.sh", "enforce-base-branch.py"]

[[hooks.PreToolUse]]
matcher = "apply_patch"
command = ["hooks/_run.sh", "enforce-path-c-delegation.py"]
TOML
}

# --- (5a) hooks wired in repo-local .codex/config.toml → wired=pass ---------
echo "Case 5a: load-bearing hooks wired → codex_hooks_wired=pass"
ROOT=$(fresh_fx fx-5a-wired codex)
write_repo_hooks "$ROOT/proj"
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_hooks_wired status=pass' <<<"$out"; then
  pass_msg "(5a) hooks wired → codex_hooks_wired=pass"
else
  fail_msg "(5a) expected codex_hooks_wired=pass"
  echo "$out" | grep -E 'codex_hooks_wired' | sed 's/^/    /' || true
fi

# --- (5b) no [[hooks.*]] entries → wired=fail -------------------------------
echo "Case 5b: no hooks wired → codex_hooks_wired=fail"
ROOT=$(fresh_fx fx-5b-nohooks codex)
# .codex/config.toml exists but wires no enforcement hooks.
cat > "$ROOT/proj/.codex/config.toml" <<'TOML'
[mcp_servers.playwright]
command = "npx"
TOML
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_hooks_wired status=fail' <<<"$out"; then
  pass_msg "(5b) no hooks → codex_hooks_wired=fail"
else
  fail_msg "(5b) expected codex_hooks_wired=fail"
  echo "$out" | grep -E 'codex_hooks_wired' | sed 's/^/    /' || true
fi

# --- (5c) trust unconfirmable → codex_hooks_trusted=warn (never fail) -------
echo "Case 5c: no trust marker → codex_hooks_trusted=warn"
ROOT=$(fresh_fx fx-5c-untrusted codex)
write_repo_hooks "$ROOT/proj"
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_hooks_trusted status=warn' <<<"$out"; then
  pass_msg "(5c) trust unconfirmable → codex_hooks_trusted=warn"
else
  fail_msg "(5c) expected codex_hooks_trusted=warn"
  echo "$out" | grep -E 'codex_hooks_trusted' | sed 's/^/    /' || true
fi
# codex_hooks_trusted must NEVER be fail-grade (trust thrashes on dogfood).
if grep -qE '^CHECK: codex_hooks_trusted status=fail' <<<"$out"; then
  fail_msg "(5c) codex_hooks_trusted must never be fail-grade"
else
  pass_msg "(5c) codex_hooks_trusted is never fail-grade"
fi

# --- (5d) trust marker present → codex_hooks_trusted=pass -------------------
echo "Case 5d: trust marker present → codex_hooks_trusted=pass"
ROOT=$(fresh_fx fx-5d-trusted codex)
write_repo_hooks "$ROOT/proj"
# A managed/trusted marker under CODEX_HOME.
echo '{"trusted": true}' > "$ROOT/codex-home/trusted_hooks.json"
run_doctor "$ROOT"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_hooks_trusted status=pass' <<<"$out"; then
  pass_msg "(5d) trust marker → codex_hooks_trusted=pass"
else
  fail_msg "(5d) expected codex_hooks_trusted=pass"
  echo "$out" | grep -E 'codex_hooks_trusted' | sed 's/^/    /' || true
fi

# ===========================================================================
# Task 6 — codex_mcp_reachable
# ===========================================================================

# --- (6a) [mcp_servers.playwright] present → mcp_reachable=pass --------------
echo "Case 6a: [mcp_servers.playwright] present → codex_mcp_reachable=pass"
ROOT=$(fresh_fx fx-6a-mcp codex)
cat > "$ROOT/codex-home/config.toml" <<'TOML'
[features]
multi_agent = true

[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@0.0.75"]
TOML
run_doctor "$ROOT" "PIPELINE_CODEX_CONFIG=$ROOT/codex-home/config.toml"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_mcp_reachable status=pass' <<<"$out"; then
  pass_msg "(6a) MCP block present → codex_mcp_reachable=pass"
else
  fail_msg "(6a) expected codex_mcp_reachable=pass"
  echo "$out" | grep -E 'codex_mcp_reachable' | sed 's/^/    /' || true
fi

# --- (6b) no MCP block → mcp_reachable=warn (optional; never fail) -----------
echo "Case 6b: no MCP block → codex_mcp_reachable=warn"
ROOT=$(fresh_fx fx-6b-nomcp codex)
cat > "$ROOT/codex-home/config.toml" <<'TOML'
[features]
multi_agent = true
TOML
run_doctor "$ROOT" "PIPELINE_CODEX_CONFIG=$ROOT/codex-home/config.toml"
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: codex_mcp_reachable status=warn' <<<"$out"; then
  pass_msg "(6b) no MCP block → codex_mcp_reachable=warn"
else
  fail_msg "(6b) expected codex_mcp_reachable=warn"
  echo "$out" | grep -E 'codex_mcp_reachable' | sed 's/^/    /' || true
fi
# codex_mcp_reachable must NEVER be fail-grade (MCP gates only visual-proof).
if grep -qE '^CHECK: codex_mcp_reachable status=fail' <<<"$out"; then
  fail_msg "(6b) codex_mcp_reachable must never be fail-grade"
else
  pass_msg "(6b) codex_mcp_reachable is never fail-grade"
fi

# ===========================================================================
# Regression — the full doctor run under harness=codex must still exit 0 when
# every Codex check is pass/warn (no fail). Confirms the codex gate composes
# with the rest of the doctor summary/exit logic.
# ===========================================================================
echo "Case Z: full codex-mode run, all checks satisfied → doctor exit 0"
ROOT=$(fresh_fx fx-z-allgreen codex)
write_repo_hooks "$ROOT/proj"
cat > "$ROOT/codex-home/config.toml" <<'TOML'
[features]
multi_agent = true

[mcp_servers.playwright]
command = "npx"
TOML
echo '{"trusted": true}' > "$ROOT/codex-home/trusted_hooks.json"
(
  cd "$ROOT/proj"
  env PATH="$TMP/bin:$PATH" \
      CLAUDE_PLUGIN_ROOT="$ROOT/plugin" \
      CODEX_HOME="$ROOT/codex-home" \
      PIPELINE_CODEX_CONFIG="$ROOT/codex-home/config.toml" \
      bash "$DOCTOR"
) > "$ROOT/out" 2>&1
z_rc=$?
out="$(cat "$ROOT/out")"
# No codex_* check should be fail when fully configured.
if grep -qE '^CHECK: codex_[a-z_]+ status=fail' <<<"$out"; then
  fail_msg "(Z) no codex_* check should fail when fully configured"
  echo "$out" | grep -E '^CHECK: codex_.* status=fail' | sed 's/^/    /' || true
else
  pass_msg "(Z) all codex_* checks pass/warn when fully configured"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
