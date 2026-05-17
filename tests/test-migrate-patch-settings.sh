#!/bin/bash
set -uo pipefail

# Tests for the --patch settings CLI mode of scripts/migrate-from-subtree.sh.
#
# Asserts:
#  - `--patch settings` runs ONLY the settings-detection + report/patch
#    emission block, then exits 0.
#  - `--patch settings` does NOT touch .claude-pipeline/ even if present.
#  - Plain invocation (no args) still runs the full migration (regression).

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
# Test 'patch-settings-mode': --patch settings runs ONLY the settings block.
# ---------------------------------------------------------------------------
echo "Test 'patch-settings-mode': --patch settings emits report, leaves .claude-pipeline/ untouched"

PROJ="$WORKDIR/proj-patch-settings"
mkdir -p "$PROJ/.claude-pipeline/hooks" "$PROJ/.claude"
# Two pipeline hook entries.
touch "$PROJ/.claude-pipeline/hooks/log-tool-use.sh"
touch "$PROJ/.claude-pipeline/hooks/restrict_paths.py"
cat > "$PROJ/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/restrict_paths.py"}]}
    ]
  }
}
EOF
# Sentinel content under .claude-pipeline/ that --patch settings must NOT delete.
echo "sentinel" > "$PROJ/.claude-pipeline/sentinel.txt"

STDOUT_LOG="$WORKDIR/patch.stdout"
STDERR_LOG="$WORKDIR/patch.stderr"
(cd "$PROJ" && bash "$MIGRATE_SH" --patch settings >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "patch-settings: exit 0"; else fail_msg "patch-settings: exit $EXIT"; fi

inc
if [ -f "$PROJ/.claude/settings.json.pipeline-migration-report.txt" ]; then
  pass_msg "patch-settings: report file created"
else
  fail_msg "patch-settings: report file missing"
fi

inc
if [ -d "$PROJ/.claude-pipeline" ] && [ -f "$PROJ/.claude-pipeline/sentinel.txt" ]; then
  pass_msg "patch-settings: .claude-pipeline/ untouched"
else
  fail_msg "patch-settings: .claude-pipeline/ was mutated by --patch settings"
fi

# ---------------------------------------------------------------------------
# Test 'no-arg full migration': plain invocation still runs full migration.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'no-arg full migration': plain invocation still removes .claude-pipeline/"

PROJ2="$WORKDIR/proj-full"
mkdir -p "$PROJ2/.claude-pipeline/hooks" "$PROJ2/.claude"
touch "$PROJ2/.claude-pipeline/hooks/log-tool-use.sh"
echo '{"hooks": []}' > "$PROJ2/.claude/settings.json"

(cd "$PROJ2" && bash "$MIGRATE_SH" >/dev/null 2>&1)
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "full: exit 0"; else fail_msg "full: exit $EXIT"; fi

inc
if [ ! -d "$PROJ2/.claude-pipeline" ]; then
  pass_msg "full: .claude-pipeline/ removed by full migration"
else
  fail_msg "full: .claude-pipeline/ still present after full migration"
fi

# ---------------------------------------------------------------------------
# Test 'patch-settings-mixed': pipeline hooks removed, consumer hooks intact,
# backup written, filtered JSON valid + sorted-key.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch-settings-mixed': rewrite removes pipeline hooks, preserves consumer hooks"

PROJ3="$WORKDIR/proj-mixed"
mkdir -p "$PROJ3/.claude"
cat > "$PROJ3/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [
        {"type": "command", "command": ".claude/hooks/log-tool-use.sh"},
        {"type": "command", "command": "./my/consumer-hook.sh"}
      ]}
    ],
    "PreToolUse": [
      {"hooks": [
        {"type": "command", "command": "python3 .claude/hooks/restrict_paths.py"},
        {"type": "command", "command": ".claude/hooks/enforce-base-branch.py"},
        {"type": "command", "command": "/usr/local/bin/my-other-consumer.py"}
      ]}
    ]
  },
  "permissions": {"allow": ["Bash(ls)"]}
}
EOF
ORIG_BYTES="$(wc -c < "$PROJ3/.claude/settings.json")"
cp "$PROJ3/.claude/settings.json" "$WORKDIR/proj-mixed.orig.json"

(cd "$PROJ3" && bash "$MIGRATE_SH" --patch settings --assume-yes >"$WORKDIR/mixed.stdout" 2>"$WORKDIR/mixed.stderr")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "mixed: exit 0"; else fail_msg "mixed: exit $EXIT (stderr: $(cat "$WORKDIR/mixed.stderr"))"; fi

inc
if [ -f "$PROJ3/.claude/settings.json.bak" ]; then
  pass_msg "mixed: backup .bak written"
else
  fail_msg "mixed: backup .bak missing"
fi

inc
if cmp -s "$PROJ3/.claude/settings.json.bak" "$WORKDIR/proj-mixed.orig.json"; then
  pass_msg "mixed: backup matches original byte-for-byte"
else
  fail_msg "mixed: backup diverges from original"
fi

inc
if jq -e . "$PROJ3/.claude/settings.json" >/dev/null 2>&1; then
  pass_msg "mixed: filtered JSON is valid"
else
  fail_msg "mixed: filtered JSON is invalid"
fi

inc
# Stable key order: re-running `jq -S .` on the file must be byte-identical to its current state.
if diff -q <(jq -S . "$PROJ3/.claude/settings.json") "$PROJ3/.claude/settings.json" >/dev/null 2>&1; then
  pass_msg "mixed: filtered JSON has stable (sorted) key ordering"
else
  fail_msg "mixed: filtered JSON keys not in sorted order"
fi

inc
if jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$PROJ3/.claude/settings.json" | grep -qE '(log-tool-use\.sh|restrict_paths\.py|enforce-base-branch\.py)$'; then
  fail_msg "mixed: pipeline hook still present after rewrite"
else
  pass_msg "mixed: pipeline hooks removed"
fi

inc
if jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$PROJ3/.claude/settings.json" | grep -q 'consumer-hook\.sh' \
   && jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$PROJ3/.claude/settings.json" | grep -q 'my-other-consumer\.py'; then
  pass_msg "mixed: consumer hooks intact"
else
  fail_msg "mixed: consumer hooks lost in rewrite"
fi

inc
if jq -e '.permissions.allow == ["Bash(ls)"]' "$PROJ3/.claude/settings.json" >/dev/null 2>&1; then
  pass_msg "mixed: unrelated top-level keys preserved"
else
  fail_msg "mixed: unrelated top-level keys mutated"
fi

inc
if grep -q 'removed 3 pipeline hook' "$WORKDIR/mixed.stdout"; then
  pass_msg "mixed: summary line reports 3 removals"
else
  fail_msg "mixed: summary line missing or wrong count (stdout: $(cat "$WORKDIR/mixed.stdout"))"
fi

# ---------------------------------------------------------------------------
# Test 'patch-settings-dry-run': --dry-run prints diff, leaves file untouched.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch-settings-dry-run': --dry-run prints diff, no mutation, no backup"

PROJ4="$WORKDIR/proj-dry"
mkdir -p "$PROJ4/.claude"
cat > "$PROJ4/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [
        {"type": "command", "command": ".claude/hooks/log-tool-use.sh"},
        {"type": "command", "command": "./my/consumer-hook.sh"}
      ]}
    ]
  }
}
EOF
DRY_ORIG_SHA="$(sha256sum "$PROJ4/.claude/settings.json" | awk '{print $1}')"

(cd "$PROJ4" && bash "$MIGRATE_SH" --patch settings --dry-run >"$WORKDIR/dry.stdout" 2>"$WORKDIR/dry.stderr")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "dry-run: exit 0"; else fail_msg "dry-run: exit $EXIT"; fi

inc
DRY_NEW_SHA="$(sha256sum "$PROJ4/.claude/settings.json" | awk '{print $1}')"
if [ "$DRY_ORIG_SHA" = "$DRY_NEW_SHA" ]; then
  pass_msg "dry-run: settings.json byte-identical pre/post"
else
  fail_msg "dry-run: settings.json mutated despite --dry-run"
fi

inc
if [ ! -e "$PROJ4/.claude/settings.json.bak" ]; then
  pass_msg "dry-run: no backup written"
else
  fail_msg "dry-run: backup written despite --dry-run"
fi

inc
if grep -q 'log-tool-use\.sh' "$WORKDIR/dry.stdout"; then
  pass_msg "dry-run: stdout contains the would-be-removed hook entry"
else
  fail_msg "dry-run: diff missing from stdout"
fi

# ---------------------------------------------------------------------------
# Test 'patch-settings-no-settings': missing .claude/settings.json → no-op exit 0.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch-settings-no-settings': missing settings.json is a clean no-op"

PROJ5="$WORKDIR/proj-no-settings"
mkdir -p "$PROJ5/.claude"
# No settings.json on disk.

(cd "$PROJ5" && bash "$MIGRATE_SH" --patch settings >"$WORKDIR/no.stdout" 2>"$WORKDIR/no.stderr")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "no-settings: exit 0"; else fail_msg "no-settings: exit $EXIT"; fi

inc
if [ ! -e "$PROJ5/.claude/settings.json.bak" ]; then
  pass_msg "no-settings: no backup written"
else
  fail_msg "no-settings: spurious backup written"
fi

inc
if grep -qE '(no .*settings\.json|nothing to patch)' "$WORKDIR/no.stdout"; then
  pass_msg "no-settings: stdout note present"
else
  fail_msg "no-settings: clear no-op note missing (stdout: $(cat "$WORKDIR/no.stdout"))"
fi

# ---------------------------------------------------------------------------
# Test 'patch-settings-backup-collision': existing .bak → suffix with ISO timestamp.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch-settings-backup-collision': existing .bak preserved, new backup ISO-suffixed"

PROJ6="$WORKDIR/proj-collision"
mkdir -p "$PROJ6/.claude"
cat > "$PROJ6/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ]
  }
}
EOF
echo 'PRE-EXISTING-SENTINEL' > "$PROJ6/.claude/settings.json.bak"
OLD_BAK_SHA="$(sha256sum "$PROJ6/.claude/settings.json.bak" | awk '{print $1}')"

(cd "$PROJ6" && bash "$MIGRATE_SH" --patch settings --assume-yes >"$WORKDIR/coll.stdout" 2>"$WORKDIR/coll.stderr")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "collision: exit 0"; else fail_msg "collision: exit $EXIT (stderr: $(cat "$WORKDIR/coll.stderr"))"; fi

inc
NEW_BAK_SHA="$(sha256sum "$PROJ6/.claude/settings.json.bak" | awk '{print $1}')"
if [ "$OLD_BAK_SHA" = "$NEW_BAK_SHA" ]; then
  pass_msg "collision: pre-existing .bak untouched"
else
  fail_msg "collision: pre-existing .bak was overwritten"
fi

inc
# An ISO-suffixed backup must exist alongside the untouched original.
if compgen -G "$PROJ6/.claude/settings.json.bak.*Z" >/dev/null 2>&1; then
  pass_msg "collision: ISO-suffixed backup written"
else
  fail_msg "collision: no ISO-suffixed backup found (ls: $(ls -la "$PROJ6/.claude/"))"
fi

# ---------------------------------------------------------------------------
# Test 'patch-settings-consumer-only': no pipeline hooks → no mutation, no backup.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'patch-settings-consumer-only': consumer-only settings is a clean no-op"

PROJ7="$WORKDIR/proj-consumer-only"
mkdir -p "$PROJ7/.claude"
cat > "$PROJ7/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": "./my/consumer-hook.sh"}]}
    ]
  }
}
EOF
CO_ORIG_SHA="$(sha256sum "$PROJ7/.claude/settings.json" | awk '{print $1}')"

(cd "$PROJ7" && bash "$MIGRATE_SH" --patch settings --assume-yes >"$WORKDIR/co.stdout" 2>"$WORKDIR/co.stderr")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "consumer-only: exit 0"; else fail_msg "consumer-only: exit $EXIT"; fi

inc
CO_NEW_SHA="$(sha256sum "$PROJ7/.claude/settings.json" | awk '{print $1}')"
if [ "$CO_ORIG_SHA" = "$CO_NEW_SHA" ]; then
  pass_msg "consumer-only: settings.json untouched"
else
  fail_msg "consumer-only: settings.json mutated despite no pipeline hooks"
fi

inc
if [ ! -e "$PROJ7/.claude/settings.json.bak" ]; then
  pass_msg "consumer-only: no backup written"
else
  fail_msg "consumer-only: spurious backup written"
fi

inc
if grep -qE '(nothing to remove|no pipeline hook)' "$WORKDIR/co.stdout"; then
  pass_msg "consumer-only: 'nothing to remove' note present"
else
  fail_msg "consumer-only: note missing (stdout: $(cat "$WORKDIR/co.stdout"))"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
