#!/bin/bash
set -uo pipefail

# #625: doctor's `dogfood_plugin_root` check must WARN when the
# pipeline@claude-pipeline-local install is ENABLED for the project but the
# effective CLAUDE_PLUGIN_ROOT is NOT that install (e.g. a published cache copy
# won the resolution) — meaning orchestrator bash steps run stale published
# scripts. It must PASS when the resolved root is the local-marketplace symlink,
# and emit NO check line on consumer hosts (local install absent/disabled).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Hermetic HOME with both a published copy and a local-marketplace symlink at
# the same version. The local symlink targets the real repo so doctor's other
# plugin-manifest checks resolve.
HHOME="$TMP/home"
mkdir -p "$HHOME/.claude/plugins"
PUB="$HHOME/.claude/plugins/cache/claude-pipeline/pipeline/1.2.3"
mkdir -p "$PUB"
mkdir -p "$HHOME/.claude/plugins/cache/claude-pipeline-local/pipeline"
LOCAL="$HHOME/.claude/plugins/cache/claude-pipeline-local/pipeline/1.2.3"
ln -s "$REPO_ROOT" "$LOCAL"

IPFILE="$TMP/installed_plugins.json"
cat > "$IPFILE" <<JSON
{
  "version": 2,
  "plugins": {
    "pipeline@claude-pipeline": [
      {
        "scope": "local",
        "projectPath": "$REPO_ROOT",
        "installPath": "$PUB",
        "version": "1.2.3"
      }
    ],
    "pipeline@claude-pipeline-local": [
      {
        "scope": "local",
        "projectPath": "$REPO_ROOT",
        "installPath": "$LOCAL",
        "version": "1.2.3"
      }
    ]
  }
}
JSON

SETTINGS_ON="$TMP/settings-on.json"
cat > "$SETTINGS_ON" <<JSON
{"enabledPlugins":{"pipeline@claude-pipeline-local":true}}
JSON

# --------------------------------------------------------------------------
# Case A: local install enabled but resolved root is the published copy → warn.
# --------------------------------------------------------------------------
echo "Case A: enabled local-marketplace but resolved root is published copy → warn"
OUT=$(
  cd "$REPO_ROOT"
  HOME="$HHOME" \
  CLAUDE_PLUGIN_ROOT="$PUB" \
  PIPELINE_INSTALLED_PLUGINS_FILE="$IPFILE" \
  PIPELINE_PROJECT_SETTINGS_FILE="$SETTINGS_ON" \
    bash scripts/doctor.sh 2>&1 || true
)
LINE=$(echo "$OUT" | grep -E '^CHECK: dogfood_plugin_root ' | tail -n 1)
case "$LINE" in
  *"status=warn"*"claude-pipeline-local"*) pass_msg "mismatch → warn naming local-marketplace" ;;
  *) fail_msg "expected warn referencing claude-pipeline-local; got: $LINE" ;;
esac

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
