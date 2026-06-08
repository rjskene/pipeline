#!/bin/bash
# Tests for scripts/check-no-consumer-codex-writes.sh — the Codex twin of the
# check-no-consumer-claude-writes namespace guard. Mirrors
# tests/test-check-no-consumer-claude-writes.sh.
#
# The Codex per-user namespace is ~/.codex/ / $CODEX_HOME (NOT a project
# .claude/-style dir), so the forbidden regex targets ~/.codex/{hooks,prompts,
# agents}/ and ~/.codex/config.toml. The repo-local .codex/ (the committed
# manifest, Leg 2/3) is the pipeline's OWN artifact and is NOT forbidden.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT="$REPO_ROOT/scripts/check-no-consumer-codex-writes.sh"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# ------------------------------------------------------------------------------
# Sandbox helper: spin up a minimal repo-like tree, copy the lint into it, and
# return the path. Caller is responsible for `rm -rf "$dir"` on cleanup.
# ------------------------------------------------------------------------------
make_sandbox() {
  local dir
  dir=$(mktemp -d)
  mkdir -p "$dir/scripts" "$dir/hooks" "$dir/agents" "$dir/.codex-plugin" \
           "$dir/tests" "$dir/docs" "$dir/.codex"
  cp "$LINT" "$dir/scripts/check-no-consumer-codex-writes.sh"
  chmod +x "$dir/scripts/check-no-consumer-codex-writes.sh"
  : > "$dir/tests/no-consumer-codex-writes.allow"
  echo "$dir"
}

# ------------------------------------------------------------------------------
# Assertions
# ------------------------------------------------------------------------------

# (a) lint script exists and is executable
assert "lint script exists and is executable" "[ -x \"$LINT\" ]"

# (b) runs cleanly on the current repo
assert "runs cleanly on the current repo" \
  "bash \"$LINT\" >/dev/null 2>&1"

# (c) clean empty sandbox — no source files matching the pattern => exit 0
SB1=$(make_sandbox); trap 'rm -rf "$SB1"' EXIT
assert "runs cleanly on an empty sandbox" \
  "(cd \"$SB1\" && bash scripts/check-no-consumer-codex-writes.sh >/dev/null 2>&1)"

# (d) inject a forbidden reference under scripts/ in the sandbox => exit 1
SB2=$(make_sandbox)
echo 'cp foo ~/.codex/hooks/probe.py' > "$SB2/scripts/_lint_probe.sh"
assert "rejects injected ~/.codex/hooks/ write" \
  "(cd \"$SB2\" && ! bash scripts/check-no-consumer-codex-writes.sh >/dev/null 2>&1)"
rm -rf "$SB2"

# (e) tests/ injection should be ignored (tests legitimately simulate consumer
#     ~/.codex/ layouts).
SB3=$(make_sandbox)
echo 'echo ~/.codex/prompts/x' > "$SB3/tests/foo.sh"
assert "ignores tests/ injection" \
  "(cd \"$SB3\" && bash scripts/check-no-consumer-codex-writes.sh >/dev/null 2>&1)"
rm -rf "$SB3"

# (f) repo-local .codex/ directory itself is the pipeline's OWN committed
#     artifact (the Codex manifest bundle) and is not scanned — a reference
#     inside .codex/ describes existing state, not a regression.
SB4=$(make_sandbox)
echo 'echo .codex/config.toml' > "$SB4/.codex/probe.sh"
assert "ignores repo-local .codex/ directory injection" \
  "(cd \"$SB4\" && bash scripts/check-no-consumer-codex-writes.sh >/dev/null 2>&1)"
rm -rf "$SB4"

# (g) allow-file mechanism: a documented allow-entry exempts an otherwise-
#     forbidden reference. Add a sandbox allow-entry for the probe file and
#     confirm the matching file passes.
SB5=$(make_sandbox)
echo 'cp foo ~/.codex/hooks/probe.py' > "$SB5/scripts/_allow_probe.sh"
echo 'scripts/_allow_probe.sh' > "$SB5/tests/no-consumer-codex-writes.allow"
assert "allow-file exempts a documented forbidden reference" \
  "(cd \"$SB5\" && bash scripts/check-no-consumer-codex-writes.sh >/dev/null 2>&1)"
rm -rf "$SB5"

# (h) .github/workflows/ci.yml exists and references the lint
assert ".github/workflows/ci.yml references the codex lint" \
  "grep -qF 'check-no-consumer-codex-writes.sh' \"$REPO_ROOT/.github/workflows/ci.yml\""

# (i) CLAUDE.md documents the codex namespace guard
assert "CLAUDE.md documents the codex namespace guard" \
  "grep -qF 'check-no-consumer-codex-writes.sh' \"$REPO_ROOT/CLAUDE.md\""

# (j) Codex dogfood guide exists and covers the bootstrap keywords.
assert "docs/codex-dogfood-setup.md exists" \
  "[ -f \"$REPO_ROOT/docs/codex-dogfood-setup.md\" ]"
assert "codex-dogfood-setup.md covers multi_agent" \
  "grep -qF 'multi_agent' \"$REPO_ROOT/docs/codex-dogfood-setup.md\""
assert "codex-dogfood-setup.md covers the /hooks re-trust step" \
  "grep -qF '/hooks' \"$REPO_ROOT/docs/codex-dogfood-setup.md\""
assert "codex-dogfood-setup.md covers mcp_servers" \
  "grep -qF 'mcp_servers' \"$REPO_ROOT/docs/codex-dogfood-setup.md\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
