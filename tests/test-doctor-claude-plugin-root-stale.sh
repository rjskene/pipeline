#!/bin/bash
set -uo pipefail

# Regression for #286 follow-up: doctor's `claude_plugin_root` check must
# downgrade to `warn` when the env var resolves to a stale version that is
# older than the highest semver available in the plugin cache. Silent stale
# resolution is the worse failure mode.
#
# HERMETICITY (#1274 scope 7c) — the temp CWD below is LOAD-BEARING. doctor.sh
# does `source ./pipeline.config` relative to its working directory, so running
# it from $REPO_ROOT lets the host's gitignored live config reach this fixture.
# On a --plugin-dir dogfood clone that config carries PIPELINE_USE_LOCAL_PLUGIN=true,
# the expected-root recompute then resolves to the checkout working tree, and the
# warn names the checkout basename instead of `0.8.0-rc.5` — the #1199 false-green
# class. Neutralising the knob in the ENV alone does NOT work: doctor re-sources
# ./pipeline.config after the initial resolve, reinstating it. Run from a temp
# project dir with a knob-free fixture config instead; the assertion below is
# unchanged and is itself the leak detector.

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

# Hermetic project dir: a fixture pipeline.config carrying NO plugin knob, and
# a cwd that is deliberately not a git working tree.
PROJ="$TMP/proj"
mkdir -p "$PROJ"
cat > "$PROJ/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG

OUT=$(
  cd "$PROJ"
  HOME="$HHOME" \
  CLAUDE_PLUGIN_ROOT="$CACHE/0.7.2" \
    bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
)

LINE=$(echo "$OUT" | grep -E '^CHECK: claude_plugin_root ' | tail -n 1)
case "$LINE" in
  *"status=warn"*"0.7.2"*"0.8.0-rc.5"*) pass_msg "stale env path → warn naming both paths" ;;
  *) fail_msg "expected warn referencing 0.7.2 and 0.8.0-rc.5; got: $LINE" ;;
esac

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
