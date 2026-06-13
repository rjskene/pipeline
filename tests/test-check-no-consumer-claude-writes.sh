#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO_ROOT/scripts/check-no-consumer-claude-writes.sh"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# ------------------------------------------------------------------------------
# Sandbox helper: spin up a minimal repo-like tree, copy the lint into it, and
# return the path. Caller is responsible for `rm -rf "$dir"` on cleanup.
# ------------------------------------------------------------------------------
make_sandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/scripts" "$dir/hooks" "$dir/agents" "$dir/.claude-plugin" \
           "$dir/tests" "$dir/docs" "$dir/.claude/scripts"
  cp "$LINT" "$dir/scripts/check-no-consumer-claude-writes.sh"
  chmod +x "$dir/scripts/check-no-consumer-claude-writes.sh"
  : > "$dir/tests/no-consumer-claude-writes.allow"
  echo "$dir"
}

# ------------------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------------------

assert "lint script exists and is executable" "[ -x \"$LINT\" ]"

assert "runs cleanly on the current repo" \
  "bash \"$LINT\" >/dev/null 2>&1"

# Clean empty sandbox — no source files matching the pattern => exit 0.
SB1=$(make_sandbox); trap 'rm -rf "$SB1"' EXIT
assert "runs cleanly on an empty sandbox" \
  "(cd \"$SB1\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"

# Inject a forbidden reference under scripts/ in the sandbox => exit 1.
SB2=$(make_sandbox)
echo 'cp foo .claude/skills/probe/' > "$SB2/scripts/_lint_probe.sh"
assert "rejects injected .claude/skills/ write" \
  "(cd \"$SB2\" && ! bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB2"

# Exclusion 1: tests/ injection should be ignored (tests legitimately simulate
# consumer .claude/ layouts).
SB3=$(make_sandbox)
echo 'echo .claude/hooks/x' > "$SB3/tests/foo.sh"
assert "ignores tests/ injection" \
  "(cd \"$SB3\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB3"

# Exclusion 2: .claude/ directory itself is the consumer-owned namespace and
# is not scanned (a stray reference inside .claude/scripts/ describes existing
# state, not a regression).
SB4=$(make_sandbox)
echo 'echo .claude/skills/x' > "$SB4/.claude/scripts/foo.sh"
assert "ignores .claude/ directory injection" \
  "(cd \"$SB4\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB4"

# Allow-list semantics: runtime paths (.claude/logs/, .claude/worktrees/) are
# explicitly NOT in the forbidden regex, so a script referencing them passes.
SB5=$(make_sandbox)
cat > "$SB5/scripts/foo.sh" <<'SH'
echo "writing to .claude/logs/tool-use.log"
echo "checkout .claude/worktrees/wt-1"
SH
assert "allows .claude/logs/ and .claude/worktrees/ references" \
  "(cd \"$SB5\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB5"

# Plugin-rooted references (${CLAUDE_PLUGIN_ROOT}/...) are the correct
# replacement target and must never trip the lint.
SB6=$(make_sandbox)
echo 'bash ${CLAUDE_PLUGIN_ROOT}/skills/run/SKILL.md' > "$SB6/scripts/foo.sh"
assert "allows \${CLAUDE_PLUGIN_ROOT}/skills/ references" \
  "(cd \"$SB6\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB6"

# Generated-path exclusion: a compiled-bytecode artifact under
# hooks/__pycache__/ is generated, not source. Its binary content embeds the
# literal `.claude/settings.json` / `.claude/hooks/` strings from the compiled
# Python hook, so an un-excluded scan false-positives on it. Python materializes
# these `.pyc` files whenever a hook is imported at runtime — they appear in any
# live worktree even though they are gitignored. The lint MUST skip them.
SB7=$(make_sandbox)
mkdir -p "$SB7/hooks/__pycache__"
printf 'noise .claude/settings.json noise\n' > "$SB7/hooks/__pycache__/restrict_paths.cpython-312.pyc"
assert "ignores generated hooks/__pycache__/*.pyc artifacts" \
  "(cd \"$SB7\" && bash scripts/check-no-consumer-claude-writes.sh >/dev/null 2>&1)"
rm -rf "$SB7"

assert ".github/workflows/ci.yml exists and references the lint" \
  "grep -qF 'check-no-consumer-claude-writes.sh' \"$REPO_ROOT/.github/workflows/ci.yml\""

assert "CLAUDE.md documents namespace discipline" \
  "grep -qF 'Namespace discipline' \"$REPO_ROOT/CLAUDE.md\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
