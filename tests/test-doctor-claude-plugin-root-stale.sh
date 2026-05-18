#!/bin/bash
set -uo pipefail

# Regression for #286 follow-up: doctor's `claude_plugin_root` check must
# downgrade to `warn` when the env var resolves to a stale version that is
# older than the highest semver available in the plugin cache. Silent stale
# resolution is the worse failure mode.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Seed a hermetic plugin cache: stale 0.7.2 + correct 0.8.0-rc.5.
HHOME="$TMP/home"
CACHE="$HHOME/.claude/plugins/cache/claude-pipeline/pipeline"
mkdir -p "$CACHE/0.7.2" "$CACHE/0.8.0-rc.5"

OUT=$(
  cd "$REPO_ROOT"
  HOME="$HHOME" \
  CLAUDE_PLUGIN_ROOT="$CACHE/0.7.2" \
    bash scripts/doctor.sh 2>&1 || true
)

LINE=$(echo "$OUT" | grep -E '^CHECK: claude_plugin_root ' | tail -n 1)
case "$LINE" in
  *"status=warn"*"0.7.2"*"0.8.0-rc.5"*) pass_msg "stale env path → warn naming both paths" ;;
  *) fail_msg "expected warn referencing 0.7.2 and 0.8.0-rc.5; got: $LINE" ;;
esac

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
