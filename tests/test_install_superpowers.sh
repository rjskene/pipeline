#!/bin/bash
set -euo pipefail

# Tests for the superpowers plugin detection logic in install.sh
#
# Overrides HOME to a temp dir so we can control the presence/absence
# of ~/.claude/plugins/installed_plugins.json without touching real config.

PASS=0
FAIL=0
TESTS=0

assert_contains() {
  local label="$1" output="$2" expected="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -qF "$expected"; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $expected"
    echo "    got: $output"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  TESTS=$((TESTS + 1))
  if echo "$output" | grep -qF "$unexpected"; then
    echo "  FAIL: $label"
    echo "    expected NOT to contain: $unexpected"
    echo "    got: $output"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  fi
}

# Helper: run the superpowers detection snippet in isolation.
# We extract the logic into a small function to avoid running the full install.sh
# (which needs pipeline.config, envsubst, etc.)
run_detection() {
  local fake_home="$1"
  # This mirrors the detection logic from install.sh
  bash -c '
    HOME="'"$fake_home"'"
    SUPERPOWERS_INSTALLED=false
    SUPERPOWERS_MANIFEST="$HOME/.claude/plugins/installed_plugins.json"
    if [ -f "$SUPERPOWERS_MANIFEST" ]; then
      if grep -q "\"superpowers" "$SUPERPOWERS_MANIFEST" 2>/dev/null; then
        SUPERPOWERS_INSTALLED=true
        echo "  [ok]   superpowers plugin detected"
      fi
    fi

    if [ "$SUPERPOWERS_INSTALLED" = false ]; then
      echo "  [warn] superpowers plugin not found"
      echo ""
      echo "  Pipeline skills can compose with superpowers for enhanced planning,"
      echo "  TDD, and brainstorming. Install from Claude Code:"
      echo ""
      echo "      /plugin install superpowers@claude-plugins-official"
      echo ""
      echo "  Skills fall back to inline behavior when superpowers is absent."
    fi
  ' 2>&1
}

# --- Test 1: superpowers installed ---
echo "Test 1: superpowers plugin is installed"
TMPDIR1=$(mktemp -d)
mkdir -p "$TMPDIR1/.claude/plugins"
cat > "$TMPDIR1/.claude/plugins/installed_plugins.json" <<'EJSON'
[{"name":"superpowers","version":"5.0.7","source":"claude-plugins-official"}]
EJSON

OUTPUT=$(run_detection "$TMPDIR1")
assert_contains "shows [ok] message" "$OUTPUT" "[ok]   superpowers plugin detected"
assert_not_contains "does not show [warn]" "$OUTPUT" "[warn] superpowers plugin not found"
rm -rf "$TMPDIR1"

# --- Test 2: no manifest file at all ---
echo "Test 2: no installed_plugins.json"
TMPDIR2=$(mktemp -d)
# No .claude/plugins directory at all

OUTPUT=$(run_detection "$TMPDIR2")
assert_contains "shows [warn] message" "$OUTPUT" "[warn] superpowers plugin not found"
assert_contains "shows install instructions" "$OUTPUT" "/plugin install superpowers@claude-plugins-official"
assert_not_contains "does not show [ok]" "$OUTPUT" "[ok]   superpowers plugin detected"
rm -rf "$TMPDIR2"

# --- Test 3: manifest exists but no superpowers entry ---
echo "Test 3: manifest exists but superpowers not in it"
TMPDIR3=$(mktemp -d)
mkdir -p "$TMPDIR3/.claude/plugins"
cat > "$TMPDIR3/.claude/plugins/installed_plugins.json" <<'EJSON'
[{"name":"some-other-plugin","version":"1.0.0","source":"marketplace"}]
EJSON

OUTPUT=$(run_detection "$TMPDIR3")
assert_contains "shows [warn] message" "$OUTPUT" "[warn] superpowers plugin not found"
assert_not_contains "does not show [ok]" "$OUTPUT" "[ok]   superpowers plugin detected"
rm -rf "$TMPDIR3"

# --- Test 4: malformed JSON (no crash, shows warn) ---
echo "Test 4: malformed JSON in manifest"
TMPDIR4=$(mktemp -d)
mkdir -p "$TMPDIR4/.claude/plugins"
echo "this is not valid json {{{" > "$TMPDIR4/.claude/plugins/installed_plugins.json"

OUTPUT=$(run_detection "$TMPDIR4")
assert_contains "shows [warn] for malformed JSON" "$OUTPUT" "[warn] superpowers plugin not found"
assert_not_contains "does not show [ok]" "$OUTPUT" "[ok]   superpowers plugin detected"
rm -rf "$TMPDIR4"

# --- Test 5: empty manifest file ---
echo "Test 5: empty manifest file"
TMPDIR5=$(mktemp -d)
mkdir -p "$TMPDIR5/.claude/plugins"
touch "$TMPDIR5/.claude/plugins/installed_plugins.json"

OUTPUT=$(run_detection "$TMPDIR5")
assert_contains "shows [warn] for empty file" "$OUTPUT" "[warn] superpowers plugin not found"
assert_not_contains "does not show [ok]" "$OUTPUT" "[ok]   superpowers plugin detected"
rm -rf "$TMPDIR5"

# --- Summary ---
echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
