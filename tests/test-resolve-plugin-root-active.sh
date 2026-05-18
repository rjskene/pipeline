#!/bin/bash
# tests/test-resolve-plugin-root-active.sh — exercises
# scripts/_resolve-plugin-root.sh in `active-project` mode.
#
# In active-project mode the resolver should read
# ~/.claude/plugins/installed_plugins.json (or $PIPELINE_INSTALLED_PLUGINS_FILE
# under test) and export CLAUDE_PLUGIN_ROOT to the installPath of the
# pipeline@* entry whose projectPath matches $PWD — NOT the highest-version
# entry in the marketplace cache.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/../scripts/_resolve-plugin-root.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# Build two fake plugin install dirs and a fake installed_plugins.json.
mkdir -p "$TMP/active-install" "$TMP/other-install" "$TMP/proj"
ACTIVE_INSTALL="$TMP/active-install"
OTHER_INSTALL="$TMP/other-install"
PROJ="$TMP/proj"

PLUGINS_FILE="$TMP/installed_plugins.json"
cat > "$PLUGINS_FILE" <<JSON
{
  "version": 2,
  "plugins": {
    "pipeline@claude-pipeline": [
      {
        "scope": "local",
        "projectPath": "$TMP/some-other-project",
        "installPath": "$OTHER_INSTALL",
        "version": "0.7.2"
      }
    ],
    "pipeline@claude-pipeline-dev": [
      {
        "scope": "local",
        "projectPath": "$PROJ",
        "installPath": "$ACTIVE_INSTALL",
        "version": "0.8.0-rc.2"
      }
    ]
  }
}
JSON

# --------------------------------------------------------------------------
# Case 1: active-project mode picks the entry whose projectPath==$PWD,
# NOT the highest-version cache entry.
# --------------------------------------------------------------------------
echo "Case 1: active-project resolution from installed_plugins.json"

# Point the cache fallback at a tmp dir containing a HIGHER-version entry
# than the active-project pick so we can prove the resolver did not fall
# back to the cache scan.
CACHE_DIR="$TMP/cache"
mkdir -p "$CACHE_DIR/9.9.9"
[ -d "$ACTIVE_INSTALL" ]   # sanity

out_root="$(
  cd "$PROJ"
  unset CLAUDE_PLUGIN_ROOT
  PIPELINE_RESOLVE_MODE=active-project \
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PLUGIN_CACHE_DIR="$CACHE_DIR" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"

if [ "$out_root" = "$ACTIVE_INSTALL" ]; then
  pass_msg "active-project resolution returned matching installPath ($out_root)"
else
  fail_msg "expected $ACTIVE_INSTALL, got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 2: pre-set CLAUDE_PLUGIN_ROOT short-circuits the resolver (unchanged).
# --------------------------------------------------------------------------
echo "Case 2: pre-set CLAUDE_PLUGIN_ROOT honored, no override"
out_root="$(
  cd "$PROJ"
  CLAUDE_PLUGIN_ROOT="/already/set" \
  PIPELINE_RESOLVE_MODE=active-project \
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "/already/set" ]; then
  pass_msg "pre-set CLAUDE_PLUGIN_ROOT preserved"
else
  fail_msg "pre-set CLAUDE_PLUGIN_ROOT clobbered: got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 3: default mode (env unset) — cache scan still works.
# --------------------------------------------------------------------------
echo "Case 3: default mode falls back to cache scan"
CACHE_DEFAULT="$TMP/cache-default"
mkdir -p "$CACHE_DEFAULT/0.7.2" "$CACHE_DEFAULT/0.6.0"
out_root="$(
  cd "$PROJ"
  unset CLAUDE_PLUGIN_ROOT
  unset PIPELINE_RESOLVE_MODE
  PIPELINE_PLUGIN_CACHE_DIR="$CACHE_DEFAULT" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "$CACHE_DEFAULT/0.7.2" ]; then
  pass_msg "default mode resolved highest-version cache entry"
else
  fail_msg "default mode expected $CACHE_DEFAULT/0.7.2, got '$out_root'"
fi

# --------------------------------------------------------------------------
# Case 4: active-project mode falls through to cache when no entry matches.
# --------------------------------------------------------------------------
echo "Case 4: active-project mode falls back to cache when no project match"
NOMATCH_PROJ="$TMP/no-match-proj"
mkdir -p "$NOMATCH_PROJ"
out_root="$(
  cd "$NOMATCH_PROJ"
  unset CLAUDE_PLUGIN_ROOT
  PIPELINE_RESOLVE_MODE=active-project \
  PIPELINE_INSTALLED_PLUGINS_FILE="$PLUGINS_FILE" \
  PIPELINE_PLUGIN_CACHE_DIR="$CACHE_DEFAULT" \
    bash -c "source \"$RESOLVER\"; echo \"\${CLAUDE_PLUGIN_ROOT:-}\""
)"
if [ "$out_root" = "$CACHE_DEFAULT/0.7.2" ]; then
  pass_msg "active-project mode fell back to cache when no projectPath match"
else
  fail_msg "active-project fallback expected $CACHE_DEFAULT/0.7.2, got '$out_root'"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
