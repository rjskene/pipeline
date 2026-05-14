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

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
