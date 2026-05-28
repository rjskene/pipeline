#!/usr/bin/env bash
set -euo pipefail

# consumer-mode.sh — Swap back to the published GitHub marketplace install.
#
# Cleanly rolls back the dogfood marketplace registration:
#   1. Remove pipeline@claude-pipeline-local from installed_plugins.json
#   2. Remove claude-pipeline-local from known_marketplaces.json
#
# After this runs, the operator must finish the install interactively with:
#     /plugin install pipeline@claude-pipeline
# (the /plugin CLI is interactive-only; cannot be driven from bash).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

KM_PATH="${HOME}/.claude/plugins/known_marketplaces.json"
IP_PATH="${HOME}/.claude/plugins/installed_plugins.json"

# Step 1: scrub pipeline@claude-pipeline-local from installed_plugins.json.
if [ -f "$IP_PATH" ]; then
  TMP_IP="$(mktemp)"
  if jq 'if has("plugins") then .plugins |= (del(.["pipeline@claude-pipeline-local"])) else . end' \
       "$IP_PATH" > "$TMP_IP" 2>/dev/null; then
    mv "$TMP_IP" "$IP_PATH"
  else
    rm -f "$TMP_IP"
  fi
fi

# Step 2: remove claude-pipeline-local entry from known_marketplaces.json.
if [ -f "$KM_PATH" ]; then
  TMP_KM="$(mktemp)"
  if jq 'del(.["claude-pipeline-local"])' "$KM_PATH" > "$TMP_KM" 2>/dev/null; then
    mv "$TMP_KM" "$KM_PATH"
  else
    rm -f "$TMP_KM"
  fi
fi

echo "consumer-mode: removed claude-pipeline-local registration"
echo "consumer-mode: next manual step (interactive CLI):"
echo "    /plugin install pipeline@claude-pipeline"
echo "consumer-mode: (the /plugin CLI is interactive-only; cannot be driven from bash)"
echo "current install: github (pipeline@claude-pipeline pending operator /plugin install)"
