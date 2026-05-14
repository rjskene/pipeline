#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
# Render templates into a temp dir using install.sh --self, then diff against
# the committed .claude/skills/ tree. Asserts that the rendered SKILL.md files
# checked into the repo track the source templates.
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
# Copy repo state into TMP. Need a pipeline.config (gitignored) so install.sh
# can render templates; fall back to the example config if the parent repo's
# config isn't reachable.
cp -a "$REPO_ROOT"/. "$TMP"/
if [ -f "$REPO_ROOT/pipeline.config" ]; then
  cp "$REPO_ROOT/pipeline.config" "$TMP/pipeline.config"
elif [ -f "$REPO_ROOT/../../pipeline.config" ]; then
  cp "$REPO_ROOT/../../pipeline.config" "$TMP/pipeline.config"
else
  # Synthesize a minimal config from the example for sandboxed runs.
  cp "$REPO_ROOT/pipeline.config.example" "$TMP/pipeline.config"
  sed -i 's|PIPELINE_REPO=.*|PIPELINE_REPO="HTS-COLLAB-ORG/claude-pipeline"|' "$TMP/pipeline.config"
fi
cd "$TMP"
bash install.sh --self >/dev/null
DIFF=$(diff -ruN "$REPO_ROOT/.claude/skills" "$TMP/.claude/skills" || true)
if [ -n "$DIFF" ]; then
  echo "FAIL: committed .claude/skills/ is out of sync with templates:"
  echo "$DIFF" | head -100
  exit 1
fi
# Verify the post-rename layout: run/ exists, pipeline/ does not.
[ -d "$TMP/.claude/skills/run" ] || { echo "FAIL: .claude/skills/run/ missing after install"; exit 1; }
[ ! -d "$TMP/.claude/skills/pipeline" ] || { echo "FAIL: stale .claude/skills/pipeline/ should be pruned"; exit 1; }
echo "PASS: rendered skills in sync with templates"
