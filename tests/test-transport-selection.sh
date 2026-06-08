#!/bin/bash
set -euo pipefail

# Acceptance test for `scripts/dispatch-leaf.sh transport-script` — the
# harness-keyed transport-selection seam (issue #983). Truth table:
#
#   PIPELINE_HARNESS=codex          -> .../spawn-codex.sh
#   PIPELINE_HARNESS=claude         -> .../spawn-claude.sh
#   PIPELINE_HARNESS unset/empty    -> .../spawn-claude.sh  (safe CC default)
#
# The seam exists so run-queue.sh's launch_agent dispatch (and the PATH C
# fan-out) never hard-codes a harness. An EXPLICIT PIPELINE_HARNESS is the
# operator's authoritative choice and must win; an unset value falls back to
# the claude (Claude Code) transport — the codex transport requires the
# explicit opt-in.
#
# No network, no execution of the spawn scripts themselves: this asserts only
# the PATH that `transport-script` prints. Follows the pass_msg/fail_msg/inc +
# mktemp-d + trap-rm harness conventions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch-leaf.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$DISPATCH" ]; then
  echo "ERROR: dispatch-leaf.sh not found at $DISPATCH" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Run dispatch-leaf transport-script from a CLEAN cwd that has NO pipeline.config,
# with CODEX_HOME unset, so the unset-PIPELINE_HARNESS fallback chain in
# platform.sh deterministically resolves to the claude default (no host config /
# CODEX_HOME can leak in and flip the unset case to codex).
CLEAN="$WORKDIR/clean"
mkdir -p "$CLEAN"

# Expected absolute spawn-script paths (siblings of dispatch-leaf.sh).
RESOLVED_SCRIPT_DIR="$(cd "$SCRIPT_DIR/../scripts" && pwd)"
EXPECT_CODEX="$RESOLVED_SCRIPT_DIR/spawn-codex.sh"
EXPECT_CLAUDE="$RESOLVED_SCRIPT_DIR/spawn-claude.sh"

# transport-script with a given PIPELINE_HARNESS treatment. The first arg is a
# sentinel: "codex" / "claude" export the var; "unset" runs with it explicitly
# unset and CODEX_HOME also unset, from the clean cwd.
run_transport() {
  local harness="$1"
  case "$harness" in
    unset)
      ( cd "$CLEAN"
        env -u PIPELINE_HARNESS -u CODEX_HOME -u CLAUDE_PROJECT_DIR \
          bash "$DISPATCH" transport-script )
      ;;
    *)
      ( cd "$CLEAN"
        env -u CODEX_HOME -u CLAUDE_PROJECT_DIR PIPELINE_HARNESS="$harness" \
          bash "$DISPATCH" transport-script )
      ;;
  esac
}

# -------------------------------------------------------------------------
# Test 1: PIPELINE_HARNESS=codex -> spawn-codex.sh
# -------------------------------------------------------------------------
echo "Test 1: PIPELINE_HARNESS=codex selects spawn-codex.sh"
inc
GOT=$(run_transport codex)
if [ "$GOT" = "$EXPECT_CODEX" ]; then
  pass_msg "codex -> $GOT"
else
  fail_msg "codex: expected '$EXPECT_CODEX', got '$GOT'"
fi

# -------------------------------------------------------------------------
# Test 2: PIPELINE_HARNESS=claude -> spawn-claude.sh
# -------------------------------------------------------------------------
echo "Test 2: PIPELINE_HARNESS=claude selects spawn-claude.sh"
inc
GOT=$(run_transport claude)
if [ "$GOT" = "$EXPECT_CLAUDE" ]; then
  pass_msg "claude -> $GOT"
else
  fail_msg "claude: expected '$EXPECT_CLAUDE', got '$GOT'"
fi

# -------------------------------------------------------------------------
# Test 3: PIPELINE_HARNESS unset -> spawn-claude.sh (safe CC default)
# -------------------------------------------------------------------------
echo "Test 3: PIPELINE_HARNESS unset falls back to spawn-claude.sh"
inc
GOT=$(run_transport unset)
if [ "$GOT" = "$EXPECT_CLAUDE" ]; then
  pass_msg "unset -> $GOT (safe claude default)"
else
  fail_msg "unset: expected '$EXPECT_CLAUDE', got '$GOT'"
fi

# -------------------------------------------------------------------------
# Test 4: the unset fallback can NEVER select codex (the codex transport is
#         opt-in only). Guard against a regression that defaults to codex.
# -------------------------------------------------------------------------
echo "Test 4: unset fallback never selects the codex transport"
inc
GOT=$(run_transport unset)
# Compare on basename so the guard fires regardless of how SCRIPT_DIR resolves:
# a regression that defaults the unset arm to ANY spawn-codex.sh path is caught.
if [ "$(basename "$GOT")" != "spawn-codex.sh" ]; then
  pass_msg "unset did not select a spawn-codex.sh transport"
else
  fail_msg "unset WRONGLY selected spawn-codex.sh — codex must be opt-in"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
