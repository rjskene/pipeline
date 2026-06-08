#!/bin/bash
set -uo pipefail

# Tests for the CODEX_HOME-gated branch in scripts/_resolve-plugin-root.sh
# (issue #980, Leg 1 of the Codex dual-target migration). The branch is slotted
# AFTER the existing CLAUDE_PLUGIN_ROOT early-return, so:
#   - under a simulated $CODEX_HOME bundle layout the resolver exports the highest
#     STABLE version dir (rc < stable), mirroring the Claude cache-scan semantics;
#   - with no CODEX_HOME, the existing Claude cache scan is byte-stable (regression);
#   - a pre-set CLAUDE_PLUGIN_ROOT short-circuits BOTH branches.
#
# The bundle glob defaults to ${CODEX_HOME}/plugins/claude-pipeline/pipeline and
# is overridable via PIPELINE_CODEX_BUNDLE_GLOB so a test can pin a deterministic
# layout without depending on the real default path.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/_resolve-plugin-root.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_msg "$label"
  else
    fail_msg "$label (expected='$expected' actual='$actual')"
  fi
}

# Build a fake Codex bundle layout under $1/plugins/claude-pipeline/pipeline with
# the version dirs given as $2.. ; echo the bundle glob root.
make_codex_bundle() {
  local home="$1"; shift
  local root="$home/plugins/claude-pipeline/pipeline"
  mkdir -p "$root"
  for v in "$@"; do
    mkdir -p "$root/$v"
  done
  echo "$root"
}

# Build a fake Claude cache under $1/.claude/plugins/cache/claude-pipeline/pipeline.
make_claude_cache() {
  local home="$1"; shift
  mkdir -p "$home/.claude/plugins/cache/claude-pipeline/pipeline"
  for v in "$@"; do
    mkdir -p "$home/.claude/plugins/cache/claude-pipeline/pipeline/$v"
  done
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Two resolver short-circuits sit ABOVE the Codex branch and must be neutralized
# so these subshells exercise the Codex branch / Claude cache scan hermetically
# regardless of the operator's env:
#   - PIPELINE_USE_LOCAL_PLUGIN=true (dogfood opt-in) → repo working tree.
#   - the #625/#878 dogfood tie-break, which reads installed_plugins.json +
#     project settings.local.json and, from a worktree, matches the main-repo
#     projectPath → repo working tree. Point its two override knobs
#     (PIPELINE_INSTALLED_PLUGINS_FILE / PIPELINE_PROJECT_SETTINGS_FILE) at
#     nonexistent paths so the tie-break finds nothing and falls through.
# Exported here so every `$(...)` subshell below inherits the neutralizers.
unset PIPELINE_USE_LOCAL_PLUGIN
export PIPELINE_INSTALLED_PLUGINS_FILE="$TMP/nonexistent-installed-plugins.json"
export PIPELINE_PROJECT_SETTINGS_FILE="$TMP/nonexistent-settings.local.json"

# ---------------- Case 1: CODEX_HOME bundle — stable beats rc ----------------
BUNDLE=$(make_codex_bundle "$TMP/c1" 0.7.2 0.8.0 0.8.0-rc.1 0.8.0-rc.2)
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  export CODEX_HOME="$TMP/c1"
  export PIPELINE_CODEX_BUNDLE_GLOB="$BUNDLE"
  export PIPELINE_PLUGIN_CACHE_DIR="$TMP/no-claude-cache"   # ensure Codex branch, not cache, resolves
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 1: Codex bundle resolves highest stable (0.8.0 beats 0.8.0-rc.N and 0.7.2)" \
  "$BUNDLE/0.8.0" "$ACTUAL"

# ---------------- Case 2: Codex bundle — only RCs → pick highest rc ----------------
BUNDLE=$(make_codex_bundle "$TMP/c2" 0.8.0-rc.2 0.8.0-rc.10)
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  export CODEX_HOME="$TMP/c2"
  export PIPELINE_CODEX_BUNDLE_GLOB="$BUNDLE"
  export PIPELINE_PLUGIN_CACHE_DIR="$TMP/no-claude-cache"   # ensure Codex branch, not cache, resolves
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 2: Codex bundle only RCs → 0.8.0-rc.10 beats 0.8.0-rc.2 (numeric rc order)" \
  "$BUNDLE/0.8.0-rc.10" "$ACTUAL"

# ---------------- Case 3: regression — no CODEX_HOME → Claude cache scan ----------------
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT CODEX_HOME PIPELINE_CODEX_BUNDLE_GLOB PIPELINE_USE_LOCAL_PLUGIN
  HOME="$TMP/c3"; make_claude_cache "$HOME" 0.3.1 0.4.0 0.4.0-rc.1
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 3: no CODEX_HOME → existing Claude cache scan still resolves (0.4.0)" \
  "$TMP/c3/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0" "$ACTUAL"

# ---------------- Case 4: pre-set CLAUDE_PLUGIN_ROOT short-circuits BOTH branches ----------------
# Even with CODEX_HOME set + a bundle present, a pre-set CLAUDE_PLUGIN_ROOT wins
# (the Codex branch is slotted AFTER the early-return).
BUNDLE=$(make_codex_bundle "$TMP/c4" 0.9.0)
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  export CLAUDE_PLUGIN_ROOT="/already/set"
  export CODEX_HOME="$TMP/c4"
  export PIPELINE_CODEX_BUNDLE_GLOB="$BUNDLE"
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "$CLAUDE_PLUGIN_ROOT"
)
assert_eq "Case 4: pre-set CLAUDE_PLUGIN_ROOT short-circuits the Codex branch" \
  "/already/set" "$ACTUAL"

# ---------------- Case 5: CODEX_HOME set but empty bundle → no-op (stays empty) ----------------
# Defensive: a CODEX_HOME with no matching version dirs must not export garbage;
# falls through, leaving CLAUDE_PLUGIN_ROOT unset (the Claude cache is also absent here).
BUNDLE="$TMP/c5/plugins/claude-pipeline/pipeline"; mkdir -p "$BUNDLE"
ACTUAL=$(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  export CODEX_HOME="$TMP/c5"
  export PIPELINE_CODEX_BUNDLE_GLOB="$BUNDLE"
  HOME="$TMP/c5home"; mkdir -p "$HOME"   # no claude cache either
  # shellcheck disable=SC1090
  source "$HELPER"
  echo "${CLAUDE_PLUGIN_ROOT:-<unset>}"
)
assert_eq "Case 5: CODEX_HOME set + empty bundle + no cache → stays unset" \
  "<unset>" "$ACTUAL"

# ---------------- Case 6: CODEX_HOME branch sourced under set -e stays exit 0 ----------------
# Empty bundle is the worst case (the version pick matches nothing); prove the
# resolver still returns 0 when sourced under `set -e` (it is sourced into
# spawn-claude.sh and friends which run `set -e`).
BUNDLE="$TMP/c6/plugins/claude-pipeline/pipeline"; mkdir -p "$BUNDLE"
set +e
(
  unset CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  export CODEX_HOME="$TMP/c6"
  export PIPELINE_CODEX_BUNDLE_GLOB="$BUNDLE"
  set -e
  # shellcheck disable=SC1090
  source "$HELPER"
)
RC=$?
set -e
assert_eq "Case 6: Codex branch sourced under 'set -e' (empty bundle) keeps exit 0" "0" "$RC"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
