#!/bin/bash
set -uo pipefail

# Regression guard for issue #215: an already-migrated consumer (no
# .claude-pipeline/ dir, but stale .claude/scripts/<name>.sh copies from
# the old subtree installer that were preserved across the move to the
# plugin model) should have those stale copies removed when re-running
# migrate-from-subtree.sh under a resolved CLAUDE_PLUGIN_ROOT.
#
# Pre-#215 behavior: migrate-from-subtree.sh enumerates only from
# .claude-pipeline/scripts/. When that dir is gone, the cleanup short-
# circuits with "nothing to migrate" and the stale .claude/scripts/
# copies are leaked indefinitely (rjskene/rjs canonical case).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

# --- Build a fake plugin root that ships the renamed scripts ---
PLUGIN_ROOT="$TMP/plugin-root"
mkdir -p "$PLUGIN_ROOT/scripts" "$PLUGIN_ROOT/skills/dummy"
touch "$PLUGIN_ROOT/skills/dummy/SKILL.md"
for n in spawn-claude run-queue cleanup-worktree setup-worktree sync-worktrees retarget-pr; do
  cat > "$PLUGIN_ROOT/scripts/$n.sh" <<'EOF'
#!/bin/bash
echo "from-plugin: $0"
EOF
  chmod +x "$PLUGIN_ROOT/scripts/$n.sh"
done

# --- Build a fake consumer with stale .claude/scripts/ copies and NO .claude-pipeline/ ---
CONSUMER="$TMP/consumer"
mkdir -p "$CONSUMER/.claude/scripts" "$CONSUMER/scripts"
# Stale copies (mimic preserved subtree-era files)
echo "stale spawn-claude" > "$CONSUMER/.claude/scripts/spawn-claude.sh"
echo "stale run-queue"   > "$CONSUMER/.claude/scripts/run-queue.sh"
# Required sibling helpers that migrate-from-subtree.sh sources/calls
cp "$SCRIPT_DIR/../scripts/_advisory-text.sh" "$CONSUMER/scripts/_advisory-text.sh"
cp "$SCRIPT_DIR/../scripts/scan-preservation-refs.sh" "$CONSUMER/scripts/scan-preservation-refs.sh"
cp "$SCRIPT_DIR/../scripts/migration-cleanup-claudemd.sh" "$CONSUMER/scripts/migration-cleanup-claudemd.sh" 2>/dev/null || true

# Copy the helper under test into the consumer (so its SCRIPT_DIR
# resolution points at our sibling helpers, not the dogfood repo's).
cp "$HELPER" "$CONSUMER/scripts/migrate-from-subtree.sh"
chmod +x "$CONSUMER/scripts/migrate-from-subtree.sh"

run_in_consumer() {
  ( cd "$CONSUMER" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash scripts/migrate-from-subtree.sh --assume-yes )
}

echo "=== plugin-only cleanup removes stale consumer scripts ==="
if run_in_consumer > "$TMP/run.log" 2>&1; then
  pass_msg "migrate-from-subtree.sh exited 0"
else
  fail_msg "migrate-from-subtree.sh exited non-zero (see $TMP/run.log)"
  sed 's/^/    /' "$TMP/run.log"
fi

if [ -f "$CONSUMER/.claude/scripts/spawn-claude.sh" ]; then
  fail_msg ".claude/scripts/spawn-claude.sh still present after migration"
else
  pass_msg ".claude/scripts/spawn-claude.sh removed"
fi

if [ -f "$CONSUMER/.claude/scripts/run-queue.sh" ]; then
  fail_msg ".claude/scripts/run-queue.sh still present after migration"
else
  pass_msg ".claude/scripts/run-queue.sh removed"
fi

# --- Second-run idempotence: nothing-to-migrate exit 0 ---
echo
echo "=== second run is a no-op ==="
if run_in_consumer > "$TMP/run2.log" 2>&1; then
  pass_msg "second run exited 0 (idempotent)"
else
  fail_msg "second run exited non-zero"
  sed 's/^/    /' "$TMP/run2.log"
fi

echo
echo "Result: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
