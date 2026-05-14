#!/bin/bash
set -euo pipefail

# Tests for scripts/migrate-from-subtree.sh — the consumer-facing migration
# script that removes pipeline-managed files installed via the legacy subtree
# + install.sh path.
#
# Each test builds an isolated $PROJ fixture under a per-test mktemp dir,
# invokes the migration script from that dir, and asserts on filesystem
# state, stdout, and stderr.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$MIGRATE_SH" ]; then
  echo "ERROR: migrate-from-subtree.sh not found at $MIGRATE_SH" >&2
  exit 1
fi
chmod +x "$MIGRATE_SH"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Test "absent": no .claude-pipeline/, no markers, no .claude/agents — script
# is a no-op. Snapshot fs state, run, snapshot again, require identical.
# ---------------------------------------------------------------------------
echo "Test 'absent': no-op when nothing pipeline-managed exists"

PROJ_ABSENT="$WORKDIR/proj-absent"
mkdir -p "$PROJ_ABSENT"
# Some user content so the dir isn't trivially empty
echo "hello" > "$PROJ_ABSENT/README.md"
mkdir -p "$PROJ_ABSENT/.claude"
echo '{"hooks": []}' > "$PROJ_ABSENT/.claude/settings.json"

BEFORE=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)
STDERR_LOG="$WORKDIR/absent.stderr"
STDOUT_LOG="$WORKDIR/absent.stdout"
(cd "$PROJ_ABSENT" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?
AFTER=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)

inc
if [ "$EXIT" -eq 0 ]; then
  pass_msg "absent: exit 0"
else
  fail_msg "absent: exit $EXIT"
fi

inc
if [ "$BEFORE" = "$AFTER" ]; then
  pass_msg "absent: filesystem unchanged"
else
  fail_msg "absent: filesystem changed"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
fi

inc
if grep -qi 'nothing to migrate' "$STDERR_LOG"; then
  pass_msg "absent: stderr mentions 'nothing to migrate'"
else
  fail_msg "absent: stderr missing 'nothing to migrate'"
  echo "    stderr:"
  sed 's/^/      /' "$STDERR_LOG"
fi

# ---------------------------------------------------------------------------
# Test "clean": every pipeline-managed surface present — script removes the
# managed files end-to-end, leaves user-authored siblings untouched, prints
# the post-migration instructions.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'clean': end-to-end removal of pipeline-managed surfaces"

PROJ_CLEAN="$WORKDIR/proj-clean"
mkdir -p "$PROJ_CLEAN/.claude-pipeline/scripts" "$PROJ_CLEAN/.claude-pipeline/hooks"
touch "$PROJ_CLEAN/.claude-pipeline/install.sh"
touch "$PROJ_CLEAN/.claude-pipeline/pipeline.config.example"

# Pipeline manifest under .claude-pipeline/ — names the migration script
# enumerates to identify managed scripts/hooks.
touch "$PROJ_CLEAN/.claude-pipeline/scripts/spawn-claude.sh.template"
touch "$PROJ_CLEAN/.claude-pipeline/hooks/log-tool-use.sh"

# Installed surfaces
mkdir -p "$PROJ_CLEAN/.claude/skills/run" \
         "$PROJ_CLEAN/.claude/skills/userwritten" \
         "$PROJ_CLEAN/.claude/agents" \
         "$PROJ_CLEAN/.claude/scripts" \
         "$PROJ_CLEAN/.claude/hooks"

# Skills: one managed (marker), one user-authored
echo "managed skill" > "$PROJ_CLEAN/.claude/skills/run/SKILL.md"
touch "$PROJ_CLEAN/.claude/skills/run/.pipeline-managed"
echo "user skill" > "$PROJ_CLEAN/.claude/skills/userwritten/SKILL.md"

# Agents: one managed (per-file marker), one user-authored
echo "managed agent" > "$PROJ_CLEAN/.claude/agents/tdd-implementer.md"
touch "$PROJ_CLEAN/.claude/agents/.tdd-implementer.pipeline-managed"
echo "user agent" > "$PROJ_CLEAN/.claude/agents/handwritten.md"

# Scripts: one matches pipeline manifest (managed), one does not (user)
echo "managed" > "$PROJ_CLEAN/.claude/scripts/spawn-claude.sh"
echo "user" > "$PROJ_CLEAN/.claude/scripts/custom.sh"

# Hooks: one matches manifest, one does not
echo "managed" > "$PROJ_CLEAN/.claude/hooks/log-tool-use.sh"
echo "user" > "$PROJ_CLEAN/.claude/hooks/custom-hook.sh"

STDERR_LOG="$WORKDIR/clean.stderr"
STDOUT_LOG="$WORKDIR/clean.stdout"
(cd "$PROJ_CLEAN" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "clean: exit 0"; else fail_msg "clean: exit $EXIT"; fi

inc
if [ ! -d "$PROJ_CLEAN/.claude-pipeline" ]; then
  pass_msg "clean: .claude-pipeline/ removed"
else
  fail_msg "clean: .claude-pipeline/ still present"
fi

inc
if [ ! -d "$PROJ_CLEAN/.claude/skills/run" ]; then
  pass_msg "clean: managed skill dir removed"
else
  fail_msg "clean: managed skill dir still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/skills/userwritten/SKILL.md" ]; then
  pass_msg "clean: user-authored skill preserved"
else
  fail_msg "clean: user-authored skill was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/agents/tdd-implementer.md" ] && \
   [ ! -f "$PROJ_CLEAN/.claude/agents/.tdd-implementer.pipeline-managed" ]; then
  pass_msg "clean: managed agent + marker removed"
else
  fail_msg "clean: managed agent or marker still present"
  ls -la "$PROJ_CLEAN/.claude/agents/" | sed 's/^/    /'
fi

inc
if [ -f "$PROJ_CLEAN/.claude/agents/handwritten.md" ]; then
  pass_msg "clean: user-authored agent preserved"
else
  fail_msg "clean: user-authored agent was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/scripts/spawn-claude.sh" ]; then
  pass_msg "clean: managed script removed"
else
  fail_msg "clean: managed script still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/scripts/custom.sh" ]; then
  pass_msg "clean: user-authored script preserved"
else
  fail_msg "clean: user-authored script was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/hooks/log-tool-use.sh" ]; then
  pass_msg "clean: managed hook removed"
else
  fail_msg "clean: managed hook still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/hooks/custom-hook.sh" ]; then
  pass_msg "clean: user-authored hook preserved"
else
  fail_msg "clean: user-authored hook was deleted"
fi

inc
if grep -qF 'Install the plugin: claude plugin install hts-collab-org/claude-pipeline' "$STDOUT_LOG"; then
  pass_msg "clean: install instructions printed to stdout"
else
  fail_msg "clean: install instructions missing from stdout"
  echo "    stdout:"
  sed 's/^/      /' "$STDOUT_LOG"
fi

# ---------------------------------------------------------------------------
# Test "partial": marker present but no .claude-pipeline/. Migration should
# still remove the marker + its agent and exit 0.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'partial': managed marker without .claude-pipeline/"

PROJ_PARTIAL="$WORKDIR/proj-partial"
mkdir -p "$PROJ_PARTIAL/.claude/agents"
echo "managed agent" > "$PROJ_PARTIAL/.claude/agents/tdd-implementer.md"
touch "$PROJ_PARTIAL/.claude/agents/.tdd-implementer.pipeline-managed"

STDERR_LOG="$WORKDIR/partial.stderr"
STDOUT_LOG="$WORKDIR/partial.stdout"
(cd "$PROJ_PARTIAL" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "partial: exit 0"; else fail_msg "partial: exit $EXIT"; fi

inc
if [ ! -f "$PROJ_PARTIAL/.claude/agents/tdd-implementer.md" ] && \
   [ ! -f "$PROJ_PARTIAL/.claude/agents/.tdd-implementer.pipeline-managed" ]; then
  pass_msg "partial: managed agent + marker removed"
else
  fail_msg "partial: managed agent or marker still present"
  ls -la "$PROJ_PARTIAL/.claude/agents/" | sed 's/^/    /'
fi

inc
if grep -qF 'Install the plugin: claude plugin install hts-collab-org/claude-pipeline' "$STDOUT_LOG"; then
  pass_msg "partial: install instructions printed"
else
  fail_msg "partial: install instructions missing"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
