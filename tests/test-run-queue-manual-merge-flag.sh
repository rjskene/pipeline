#!/bin/bash
# Lint the canonical plugin-source scripts for --manual-merge wiring.
# After #215 the plugin ships these scripts directly (no .template suffix);
# .claude/scripts/*.sh in this dogfood repo are residue from the legacy
# subtree installer and are not under test here.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RQ="${ROOT}/scripts/run-queue.sh"
SC="${ROOT}/scripts/spawn-claude.sh"
FAILED=0

want() {
  local file="$1" name="$2" pat="$3"
  if grep -qE -- "$pat" "$file"; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name (pattern not found in $file: $pat)"
    FAILED=$((FAILED+1))
  fi
}

echo "=== run-queue.sh ==="
want "$RQ" "MANUAL_MERGE_FLAG initializer"           'MANUAL_MERGE_FLAG='
want "$RQ" "--manual-merge case in parser"           '--manual-merge\)'
# Post-#685 there is a single, unified dispatch site (the poll-loop launch_agent);
# the former single-issue short-circuit dispatch was removed, so its `"$WT_PATH"`
# assertion is gone — a 1-issue queue now flows through this same loop dispatch.
want "$RQ" "propagated to spawn-claude (loop)"       'spawn-claude\.sh.*\$MANUAL_MERGE_FLAG.*"\$wt_path"'

echo "=== spawn-claude.sh ==="
want "$SC" "--manual-merge case in parser"           '--manual-merge\)'
want "$SC" "exports MANUAL_MERGE=1 to child"         'export MANUAL_MERGE=1'
want "$SC" "appends --manual-merge to skill args"    'MANUAL_MERGE_DIRECTIVE|--manual-merge'

echo "=== argv ordering (dry-run via auto-merge-gate parser) ==="
# We reuse the canonical parser from auto-merge-gate.sh, which is the
# loop-based pattern the templates implement. This proves the pattern
# accepts --manual-merge from any argv position; the templates' own
# parsers are linted above for the case-arm presence.
# shellcheck disable=SC1091
source "${ROOT}/scripts/auto-merge-gate.sh"
for argv in "--manual-merge 122 123" "122 123 --manual-merge" "122 --manual-merge 123"; do
  unset MANUAL_MERGE
  TMP=$(mktemp)
  # shellcheck disable=SC2086
  parse_manual_merge_argv $argv > "$TMP"
  if [ "${MANUAL_MERGE:-0}" = "1" ]; then
    echo "  PASS: parser MANUAL_MERGE=1 for [$argv]"
  else
    echo "  FAIL: parser MANUAL_MERGE not set for [$argv]"
    FAILED=$((FAILED+1))
  fi
  rm -f "$TMP"
done

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: --manual-merge wiring matches contract"
