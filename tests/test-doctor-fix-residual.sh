#!/bin/bash
set -uo pipefail

# Tests for `scripts/doctor.sh --fix residual` — interactive remediation of
# the three residual-state checks (skill_files_residual, settings_residual,
# claude_md_residual). The mutating actions are gated behind a [y/N] prompt;
# DOCTOR_FIX_NONINTERACTIVE=1 auto-answers "n" for every prompt.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — never invoked under --fix residual but kept for safety.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
exit 0
GH
chmod +x "$TMP/bin/gh"

# Build a fake plugin root so skill_files_residual / settings_residual can
# resolve plugin-shipped basenames.
mk_plugin_root() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/skills/classify-issue" "$root/hooks" "$root/scripts" "$root/agents"
  touch "$root/skills/classify-issue/SKILL.md"
  touch "$root/hooks/restrict_paths.py"
  touch "$root/scripts/doctor.sh"
  touch "$root/agents/tdd-implementer.md"
}

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

PLUGIN_ROOT="$TMP/plugin-root"
mk_plugin_root "$PLUGIN_ROOT"

run_fix() {
  local fx="$1" plugin_root="$2"; shift 2
  local stdin_input="${STDIN_INPUT:-}"
  (
    cd "$fx"
    if [ -n "$stdin_input" ]; then
      PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$plugin_root" "$@" \
        bash "$HELPER" --fix residual <<<"$stdin_input"
    else
      PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$plugin_root" "$@" \
        bash "$HELPER" --fix residual </dev/null
    fi
  ) >"$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

# ---------------------------------------------------------------------------
# Case 1: clean state, no findings → exit 0, no prompts shown.
# ---------------------------------------------------------------------------
echo "Case 1: clean state — no findings, no prompts"
FX=$(fresh_fx fx-clean)
STDIN_INPUT="" run_fix "$FX" "$PLUGIN_ROOT" DOCTOR_FIX_NONINTERACTIVE=1
rc="$(cat "$FX/rc")"
[ "$rc" = "0" ] && pass_msg "clean: exit 0" || { fail_msg "clean: exit $rc"; sed 's/^/    /' "$FX/out"; }
if grep -qE '\[y/N\]' "$FX/out"; then
  fail_msg "clean: prompt rendered despite no findings"
  sed 's/^/    /' "$FX/out"
else
  pass_msg "clean: no prompts shown"
fi

# ---------------------------------------------------------------------------
# Case 2: one duplicate skill file, DOCTOR_FIX_NONINTERACTIVE=1 → prompt
# rendered, file NOT deleted, exit 0.
# ---------------------------------------------------------------------------
echo "Case 2: dup skill file, non-interactive auto-N — prompt rendered, file kept"
FX=$(fresh_fx fx-noninteractive)
mkdir -p "$FX/.claude/skills/classify-issue"
echo "stale" > "$FX/.claude/skills/classify-issue/SKILL.md"
STDIN_INPUT="" run_fix "$FX" "$PLUGIN_ROOT" DOCTOR_FIX_NONINTERACTIVE=1
rc="$(cat "$FX/rc")"
[ "$rc" = "0" ] && pass_msg "noninteractive: exit 0" || { fail_msg "noninteractive: exit $rc"; sed 's/^/    /' "$FX/out"; }
if grep -qE '\[y/N\]' "$FX/out"; then
  pass_msg "noninteractive: prompt rendered"
else
  fail_msg "noninteractive: no prompt rendered"
  sed 's/^/    /' "$FX/out"
fi
if [ -f "$FX/.claude/skills/classify-issue/SKILL.md" ]; then
  pass_msg "noninteractive: duplicate file preserved (auto-N)"
else
  fail_msg "noninteractive: duplicate file deleted despite auto-N"
fi

# ---------------------------------------------------------------------------
# Case 3: one duplicate, simulate "y" via stdin → file IS deleted, exit 0.
# ---------------------------------------------------------------------------
echo "Case 3: dup skill, answer y → file deleted"
FX=$(fresh_fx fx-y)
mkdir -p "$FX/.claude/skills/classify-issue"
echo "stale" > "$FX/.claude/skills/classify-issue/SKILL.md"
STDIN_INPUT="y" run_fix "$FX" "$PLUGIN_ROOT"
rc="$(cat "$FX/rc")"
[ "$rc" = "0" ] && pass_msg "y: exit 0" || { fail_msg "y: exit $rc"; sed 's/^/    /' "$FX/out"; }
if [ ! -e "$FX/.claude/skills/classify-issue/SKILL.md" ]; then
  pass_msg "y: duplicate file deleted"
else
  fail_msg "y: duplicate file still present"
  sed 's/^/    /' "$FX/out"
fi

# ---------------------------------------------------------------------------
# Case 4: settings_residual finding, answer y → migrate-from-subtree.sh is
# invoked with `--patch settings`. We assert via a PATH-earlier shim that
# records the invocation.
# ---------------------------------------------------------------------------
echo "Case 4: settings finding, answer y → migrate-from-subtree.sh --patch settings invoked"
FX=$(fresh_fx fx-settings)
# Plant a settings.json that references a pipeline-owned hook basename.
mkdir -p "$FX/.claude"
cat > "$FX/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "*", "hooks": [
        {"type": "command", "command": "python3 .claude/hooks/restrict_paths.py"}
      ]}
    ]
  }
}
JSON
# Shim that replaces migrate-from-subtree.sh in the plugin root. The doctor
# script invokes it via ${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR}/scripts/migrate-from-subtree.sh.
SHIM_LOG="$FX/migrate-shim.log"
cat > "$PLUGIN_ROOT/scripts/migrate-from-subtree.sh" <<MIGRATE
#!/bin/bash
echo "\$@" >> "$SHIM_LOG"
exit 0
MIGRATE
chmod +x "$PLUGIN_ROOT/scripts/migrate-from-subtree.sh"

STDIN_INPUT="y" run_fix "$FX" "$PLUGIN_ROOT"
rc="$(cat "$FX/rc")"
[ "$rc" = "0" ] && pass_msg "settings: exit 0" || { fail_msg "settings: exit $rc"; sed 's/^/    /' "$FX/out"; }
if [ -s "$SHIM_LOG" ] && grep -q -- "--patch settings" "$SHIM_LOG"; then
  pass_msg "settings: migrate-from-subtree.sh invoked with --patch settings"
else
  fail_msg "settings: migrate-from-subtree.sh not invoked correctly"
  echo "    shim log:"; [ -f "$SHIM_LOG" ] && sed 's/^/      /' "$SHIM_LOG" || echo "      (missing)"
  sed 's/^/    /' "$FX/out"
fi
# Restore real migrate-from-subtree.sh contents (empty stub fine for later cases).
touch "$PLUGIN_ROOT/scripts/migrate-from-subtree.sh"

# ---------------------------------------------------------------------------
# Case 5: re-run on already-clean state → no-op, exit 0 (idempotency).
# ---------------------------------------------------------------------------
echo "Case 5: idempotent re-run on clean state"
FX=$(fresh_fx fx-idem)
STDIN_INPUT="" run_fix "$FX" "$PLUGIN_ROOT" DOCTOR_FIX_NONINTERACTIVE=1
rc1="$(cat "$FX/rc")"
STDIN_INPUT="" run_fix "$FX" "$PLUGIN_ROOT" DOCTOR_FIX_NONINTERACTIVE=1
rc2="$(cat "$FX/rc")"
[ "$rc1" = "0" ] && [ "$rc2" = "0" ] && pass_msg "idempotent: both runs exit 0" \
  || { fail_msg "idempotent: rc1=$rc1 rc2=$rc2"; sed 's/^/    /' "$FX/out"; }
if grep -qE '\[y/N\]' "$FX/out"; then
  fail_msg "idempotent: prompt rendered on clean re-run"
  sed 's/^/    /' "$FX/out"
else
  pass_msg "idempotent: no prompts on clean re-run"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
