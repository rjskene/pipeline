#!/usr/bin/env bash
set -euo pipefail

# setup-dogfood-local.sh — one-shot per-host bootstrap that registers this
# working tree as a LOCAL Claude Code marketplace named "claude-pipeline-local".
#
# After this script runs, the operator must complete a manual step:
#   /plugin install pipeline@claude-pipeline-local
# The /plugin CLI is interactive-only and cannot be driven from bash.
#
# known_marketplaces.json schema written by this script:
#   {
#     "claude-pipeline-local": {
#       "source": {"source": "local", "path": "<absolute-repo-root>"},
#       "installLocation": "<absolute-repo-root>",
#       "lastUpdated": "<ISO-8601 timestamp>"
#     }
#   }
#
# installLocation is the absolute path to the repo working tree itself (NOT a
# cache subdir). That is what makes ${CLAUDE_PLUGIN_ROOT} resolve to the live
# tree whenever a pipeline command resolves CLAUDE_PLUGIN_ROOT.
#
# Idempotence: when an entry with matching .installLocation and .source already
# exists, the script preserves .lastUpdated so re-runs produce a byte-identical
# known_marketplaces.json. tests/test-setup-dogfood-local.sh pins this.
#
# Three-step idempotent flow:
#   1. Merge / refresh the claude-pipeline-local entry in known_marketplaces.json.
#   2. Remove any pipeline@claude-pipeline entries from installed_plugins.json
#      so the operator's next /plugin install resolves to the local marketplace.
#   3. chmod +x the sibling mode-swap scripts and print the next manual command.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$REPO_ROOT/.git" ] && [ ! -f "$REPO_ROOT/.git" ]; then
  echo "setup-dogfood-local: $REPO_ROOT does not look like a git repo" >&2
  exit 1
fi

# Defensive source — never hard-fail if pipeline.config is missing or noisy.
if [ -f "$REPO_ROOT/pipeline.config" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/pipeline.config" 2>/dev/null || true
fi

KM_PATH="${HOME}/.claude/plugins/known_marketplaces.json"
IP_PATH="${HOME}/.claude/plugins/installed_plugins.json"

mkdir -p "$(dirname "$KM_PATH")"
if [ ! -f "$KM_PATH" ]; then
  printf '{}' > "$KM_PATH"
fi

# Step 1: merge the claude-pipeline-local entry. Preserve lastUpdated when the
# entry already exists so the file is byte-identical across re-runs.
TMP_KM="$(mktemp)"
jq --arg root "$REPO_ROOT" '
  .["claude-pipeline-local"] = {
    source: {source: "local", path: $root},
    installLocation: $root,
    lastUpdated: (.["claude-pipeline-local"].lastUpdated // (now | strftime("%Y-%m-%dT%H:%M:%SZ")))
  }
' "$KM_PATH" > "$TMP_KM"
mv "$TMP_KM" "$KM_PATH"

# Step 2: scrub any github-marketplace pipeline entries from installed_plugins.json
# so the next /plugin install resolves through the local marketplace. Filter by
# .projectPath to limit the blast radius to the current repo only (avoids nuking
# pipeline@claude-pipeline installs in unrelated consumer projects on a multi-
# project host). When the filtered array is empty, drop the key entirely so the
# post-state is byte-identical to the legacy single-project behavior.
if [ -f "$IP_PATH" ]; then
  TMP_IP="$(mktemp)"
  if jq --arg repo_root "$REPO_ROOT" '
    if has("plugins") and (.plugins | has("pipeline@claude-pipeline")) then
      .plugins["pipeline@claude-pipeline"] = (
        .plugins["pipeline@claude-pipeline"] // []
        | map(select(.projectPath != $repo_root))
      )
      | if (.plugins["pipeline@claude-pipeline"] | length) == 0
          then .plugins |= del(.["pipeline@claude-pipeline"])
          else .
        end
    else . end
  ' "$IP_PATH" > "$TMP_IP" 2>/dev/null; then
    mv "$TMP_IP" "$IP_PATH"
  else
    rm -f "$TMP_IP"
  fi
fi

# Step 3: make sibling mode-swap scripts executable (idempotent).
chmod +x "$REPO_ROOT/scripts/dogfood-mode.sh" "$REPO_ROOT/scripts/consumer-mode.sh" 2>/dev/null || true

echo "setup-dogfood-local: registered claude-pipeline-local -> $REPO_ROOT"
echo "setup-dogfood-local: next manual step (interactive CLI):"
echo "    /plugin install pipeline@claude-pipeline-local"
echo "setup-dogfood-local: (the /plugin CLI is interactive-only; cannot be driven from bash)"
