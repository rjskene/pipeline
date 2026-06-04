#!/bin/bash
set -uo pipefail

# Tests for issue #918 — doctor's agent_resource_caps capability check.
#
# The check verifies that per-agent systemd-run --user scopes are available so
# spawned agents run under a MemoryMax/TasksMax cgroup ceiling. When
# `systemd-run --user` works it records `pass` (naming the resolved caps); when
# unavailable it records `warn` (surfacing the recommended host seatbelt). WARN
# never fails the doctor run (only `fail` flips exit 1) — mirrors the
# stdin_read_timeout_guards / settings_residual severity contract.
#
# Driven by a stubbed-present vs stubbed-absent `systemd-run` on PATH, so the
# check runs hermetically and never creates a real scope. Mirrors the fixture
# shape of test-doctor-stdin-guards.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — make all early gh checks pass.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo '{"name":"repo"}'; exit 0 ;;
  "label list") exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# A NOOP systemd-run that ALWAYS succeeds (smoke probe passes) without ever
# creating a real scope — drives the `pass` branch.
cat > "$TMP/bin/systemd-run-ok" <<'SR'
#!/bin/bash
exit 0
SR
chmod +x "$TMP/bin/systemd-run-ok"

# A systemd-run that FAILS the smoke probe (binary present, no user manager) —
# drives the `warn` branch even on a host with a real systemd-run.
cat > "$TMP/bin/systemd-run-fail" <<'SR'
#!/bin/bash
echo "Failed to connect to bus: No such file or directory" >&2
exit 1
SR
chmod +x "$TMP/bin/systemd-run-fail"

# Build a minimal plugin root so doctor's plugin checks don't hard-error.
PLUGIN_ROOT="$TMP/plugin-root"
mkdir -p "$PLUGIN_ROOT/skills/classify-issue" "$PLUGIN_ROOT/hooks" \
         "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/agents" "$PLUGIN_ROOT/.claude-plugin"
touch "$PLUGIN_ROOT/skills/classify-issue/SKILL.md"
touch "$PLUGIN_ROOT/scripts/doctor.sh"
touch "$PLUGIN_ROOT/agents/tdd-implementer.md"
echo '{}' > "$PLUGIN_ROOT/.claude-plugin/plugin.json"

# fresh_fx: a consumer fixture with git + a valid pipeline.config.
fresh_fx() {
  local name="$1"
  local fx="$TMP/$name"
  rm -rf "$fx"
  mkdir -p "$fx"
  (
    cd "$fx"
    git init -q
    git config user.email t@t
    git config user.name t
    git commit --allow-empty -q -m init
    git branch -q staging 2>/dev/null || git checkout -q -b staging
  ) >/dev/null 2>&1
  cat > "$fx/pipeline.config" <<CFG
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

# Run doctor with a curated PATH. $1=fixture, $2=systemd-run stub source (or
# empty for ABSENT). Remaining args become extra env (e.g. cap overrides).
run_doctor() {
  local fx="$1" sr_src="$2"; shift 2
  local binshim="$TMP/binshim"
  rm -rf "$binshim"; mkdir -p "$binshim"
  cp "$TMP/bin/gh" "$binshim/gh"
  if [ -n "$sr_src" ]; then
    cp "$TMP/bin/$sr_src" "$binshim/systemd-run"
  fi
  (
    cd "$fx"
    env PATH="$binshim:$PATH" "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" "$@" \
      bash "$HELPER" </dev/null
  ) >"$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

# When ABSENT, we must shadow any real /usr/bin/systemd-run. Use a PATH that is
# ONLY the binshim (gh) plus a curated coreutils dir lacking systemd-run.
COREUTILS="$TMP/coreutils"
mkdir -p "$COREUTILS"
# Include jq (a hard pre-flight dependency that early-exits doctor if absent) so
# the curated PATH reaches the agent_resource_caps check — but deliberately NOT
# systemd-run, which is what this case exercises.
for b in bash sh env cat date dirname realpath mktemp tr command grep sed head tail printf rm mkdir chmod uname find sleep ls sort cut awk git jq; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$COREUTILS/$b" 2>/dev/null
done
run_doctor_absent() {
  local fx="$1"; shift
  local binshim="$TMP/binshim-absent"
  rm -rf "$binshim"; mkdir -p "$binshim"
  cp "$TMP/bin/gh" "$binshim/gh"
  (
    cd "$fx"
    env PATH="$binshim:$COREUTILS" "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" "$@" \
      bash "$HELPER" </dev/null
  ) >"$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

caps_status() {
  grep -E '^CHECK: agent_resource_caps ' "$1" \
    | sed -nE 's/.*status=([a-z]+).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Case 1: systemd-run --user works → status=pass naming the resolved caps.
# ---------------------------------------------------------------------------
echo "Case 1: systemd-run works → status=pass naming caps"
FX=$(fresh_fx fx-pass)
run_doctor "$FX" systemd-run-ok
st="$(caps_status "$FX/out")"
[ "$st" = "pass" ] && pass_msg "case1: status=pass" || { fail_msg "case1: status='$st' (want pass)"; grep -i agent_resource "$FX/out" | sed 's/^/    /'; }
if grep -E '^CHECK: agent_resource_caps ' "$FX/out" | grep -q 'MemoryMax=2G' \
   && grep -E '^CHECK: agent_resource_caps ' "$FX/out" | grep -q 'TasksMax=512'; then
  pass_msg "case1: pass detail names the resolved caps (MemoryMax=2G TasksMax=512)"
else
  fail_msg "case1: pass detail does not name the resolved caps"
  grep -i agent_resource "$FX/out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 1b: caps honor PIPELINE_AGENT_MEMORY_MAX / PIPELINE_AGENT_TASKS_MAX.
# ---------------------------------------------------------------------------
echo "Case 1b: cap overrides reflected in the pass detail"
FX=$(fresh_fx fx-pass-override)
run_doctor "$FX" systemd-run-ok PIPELINE_AGENT_MEMORY_MAX=8G PIPELINE_AGENT_TASKS_MAX=42
if grep -E '^CHECK: agent_resource_caps ' "$FX/out" | grep -q 'MemoryMax=8G' \
   && grep -E '^CHECK: agent_resource_caps ' "$FX/out" | grep -q 'TasksMax=42'; then
  pass_msg "case1b: cap overrides (8G/42) reflected in detail"
else
  fail_msg "case1b: cap overrides not reflected"
  grep -i agent_resource "$FX/out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 2: systemd-run smoke probe fails → status=warn surfacing the seatbelt.
# ---------------------------------------------------------------------------
echo "Case 2: systemd-run smoke fails → status=warn naming the seatbelt"
FX=$(fresh_fx fx-warn)
run_doctor "$FX" systemd-run-fail
st="$(caps_status "$FX/out")"
[ "$st" = "warn" ] && pass_msg "case2: status=warn" || { fail_msg "case2: status='$st' (want warn)"; grep -i agent_resource "$FX/out" | sed 's/^/    /'; }
if grep -E '^CHECK: agent_resource_caps ' "$FX/out" | grep -Eqi 'UNBOUNDED|seatbelt|swap'; then
  pass_msg "case2: warn detail surfaces the unbounded condition / recommended host seatbelt"
else
  fail_msg "case2: warn detail does not surface the seatbelt"
  grep -i agent_resource "$FX/out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 2b: systemd-run ABSENT from PATH → status=warn.
# ---------------------------------------------------------------------------
echo "Case 2b: systemd-run absent from PATH → status=warn"
FX=$(fresh_fx fx-absent)
run_doctor_absent "$FX"
st="$(caps_status "$FX/out")"
[ "$st" = "warn" ] && pass_msg "case2b: status=warn when systemd-run absent" || { fail_msg "case2b: status='$st' (want warn)"; grep -i agent_resource "$FX/out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: the check is WARN-only — it never flips doctor's exit to 1 on its own.
# The warn fixture's exit is governed by OTHER checks; assert this check's
# severity stays warn (not fail).
# ---------------------------------------------------------------------------
echo "Case 3: WARN severity (never fail the run on its own)"
FX=$(fresh_fx fx-warnonly)
run_doctor "$FX" systemd-run-fail
st="$(caps_status "$FX/out")"
[ "$st" = "warn" ] && pass_msg "case3: severity warn (not fail)" || { fail_msg "case3: status='$st' (want warn)"; grep -i agent_resource "$FX/out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 4: the check appears in the Summary table.
# ---------------------------------------------------------------------------
echo "Case 4: agent_resource_caps appears in the Summary table"
FX=$(fresh_fx fx-summary)
run_doctor "$FX" systemd-run-ok
if awk '/=== Summary ===/{s=1} s && /agent_resource_caps/{found=1} END{exit !found}' "$FX/out"; then
  pass_msg "case4: agent_resource_caps row in Summary table"
else
  fail_msg "case4: agent_resource_caps row missing from Summary table"
  sed -n '/=== Summary ===/,$p' "$FX/out" | sed 's/^/    /'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
