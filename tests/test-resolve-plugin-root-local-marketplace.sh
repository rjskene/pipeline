#!/bin/bash
# tests/test-resolve-plugin-root-local-marketplace.sh — exercises the
# default-mode local-marketplace tie-break in scripts/_resolve-plugin-root.sh
# (#625).
#
# On a dogfood host the live source is the pipeline@claude-pipeline-local
# install whose installPath is a symlink → the repo working tree. A published
# copy at the SAME version sits under the scanned cache dir and would otherwise
# win the default-mode cache scan, so the orchestrator runs stale scripts.
#
# The resolver's DEFAULT mode (CLAUDE_PLUGIN_ROOT unset, PIPELINE_RESOLVE_MODE
# unset) must prefer the enabled local-marketplace install over the published
# cache copy, and fall through to the cache scan when the local install is
# disabled / absent / not matched for $PWD, leaving the pre-set short-circuit
# untouched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/../scripts/_resolve-plugin-root.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# --------------------------------------------------------------------------
# Hermetic fixture: a fake repo working tree, a published cache copy, and a
# local-marketplace install that is a symlink → the repo working tree, both at
# the SAME version 1.2.3 (proves the tie-break, not a version comparison).
# --------------------------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO/scripts" "$REPO/.claude"

PUB="$TMP/cache/claude-pipeline/pipeline/1.2.3"
mkdir -p "$PUB"

mkdir -p "$TMP/cache/claude-pipeline-local/pipeline"
LOCAL_INSTALL="$TMP/cache/claude-pipeline-local/pipeline/1.2.3"
ln -s "$REPO" "$LOCAL_INSTALL"

PLUGINS_FILE="$TMP/installed_plugins.json"
cat > "$PLUGINS_FILE" <<JSON
{
  "version": 2,
  "plugins": {
    "pipeline@claude-pipeline": [
      {
        "scope": "local",
        "projectPath": "$REPO",
        "installPath": "$PUB",
        "version": "1.2.3"
      }
    ],
    "pipeline@claude-pipeline-local": [
      {
        "scope": "local",
        "projectPath": "$REPO",
        "installPath": "$LOCAL_INSTALL",
        "version": "1.2.3"
      }
    ]
  }
}
JSON

SETTINGS="$REPO/.claude/settings.local.json"
cat > "$SETTINGS" <<JSON
{"enabledPlugins":{"pipeline@claude-pipeline":false,"pipeline@claude-pipeline-local":true}}
JSON

# --------------------------------------------------------------------------
# Case 1: local-marketplace install wins when enabled (default mode).
# --------------------------------------------------------------------------
echo "Case 1: enabled local-marketplace install wins over published cache copy"
out_root="$(
  cd "$REPO"
  unset CLAUDE_PLUGIN_ROOT
  unset PIPELINE_RESOLVE_MODE
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PLUGIN_CACHE_DIR="$TMP/cache/claude-pipeline/pipeline" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
# The resolver exports the symlink installPath; readlink -f resolves to $REPO.
if [ "$(readlink -f "$out_root")" = "$(readlink -f "$REPO")" ]; then
  pass_msg "local-marketplace install resolved to repo working tree ($out_root)"
else
  fail_msg "expected resolution to $REPO, got '$out_root' (-> $(readlink -f "$out_root" 2>/dev/null))"
fi

# --------------------------------------------------------------------------
# Case 2: local-marketplace DISABLED → fall through to cache scan.
# --------------------------------------------------------------------------
echo "Case 2: disabled local-marketplace falls through to cache scan"
SETTINGS_OFF="$TMP/settings-off.json"
cat > "$SETTINGS_OFF" <<JSON
{"enabledPlugins":{"pipeline@claude-pipeline-local":false}}
JSON
out_root="$(
  cd "$REPO"
  unset CLAUDE_PLUGIN_ROOT
  unset PIPELINE_RESOLVE_MODE
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PROJECT_SETTINGS_FILE="$SETTINGS_OFF" \
  PIPELINE_PLUGIN_CACHE_DIR="$TMP/cache/claude-pipeline/pipeline" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "$PUB" ]; then
  pass_msg "disabled local-marketplace fell through to published cache copy"
else
  fail_msg "expected fall-through to $PUB, got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 3: settings file absent → fall through to cache scan.
# --------------------------------------------------------------------------
echo "Case 3: missing settings file falls through to cache scan"
out_root="$(
  cd "$REPO"
  unset CLAUDE_PLUGIN_ROOT
  unset PIPELINE_RESOLVE_MODE
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PROJECT_SETTINGS_FILE="$TMP/does-not-exist.json" \
  PIPELINE_PLUGIN_CACHE_DIR="$TMP/cache/claude-pipeline/pipeline" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "$PUB" ]; then
  pass_msg "missing settings file fell through to published cache copy"
else
  fail_msg "expected fall-through to $PUB, got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 4: pre-set CLAUDE_PLUGIN_ROOT short-circuits — new branch must not run.
# --------------------------------------------------------------------------
echo "Case 4: pre-set CLAUDE_PLUGIN_ROOT preserved (new branch does not run)"
out_root="$(
  cd "$REPO"
  unset PIPELINE_RESOLVE_MODE
  CLAUDE_PLUGIN_ROOT="/already/set" \
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PROJECT_SETTINGS_FILE="$SETTINGS" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "/already/set" ]; then
  pass_msg "pre-set CLAUDE_PLUGIN_ROOT preserved"
else
  fail_msg "pre-set CLAUDE_PLUGIN_ROOT clobbered: got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 5: $PWD does not match any projectPath → fall through to cache scan.
# --------------------------------------------------------------------------
echo "Case 5: no projectPath match falls through to cache scan"
NOMATCH="$TMP/no-match-proj"
mkdir -p "$NOMATCH/.claude"
cat > "$NOMATCH/.claude/settings.local.json" <<JSON
{"enabledPlugins":{"pipeline@claude-pipeline-local":true}}
JSON
out_root="$(
  cd "$NOMATCH"
  unset CLAUDE_PLUGIN_ROOT
  unset PIPELINE_RESOLVE_MODE
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PLUGIN_CACHE_DIR="$TMP/cache/claude-pipeline/pipeline" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "$PUB" ]; then
  pass_msg "no projectPath match fell through to published cache copy"
else
  fail_msg "expected fall-through to $PUB, got '$out_root'"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
