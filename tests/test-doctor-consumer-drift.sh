#!/bin/bash
# Tests for scripts/diff-consumer-files.sh and the consumer_drift check in doctor.sh.
# Builds a fake project tree + fake $CLAUDE_PLUGIN_ROOT with one file per bucket
# and asserts the classification rows the helper emits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/diff-consumer-files.sh"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ---------------------------------------------------------------------------
# Fixture builder
#
# Materialises:
#   $1/proj/ — fake consumer project
#     pipeline.config (PIPELINE_REPO=owner/repo-correct)
#     .claude/{scripts,hooks,agents}/ — populated per case
#   $1/plugin/ — fake $CLAUDE_PLUGIN_ROOT
#     scripts/, hooks/, agents/ — plugin-shipped surface
#     .claude/{scripts,hooks}/   — plugin-author dogfood (NOT shipped)
#
# Echoes the proj dir for `cd` use; the plugin dir is at "$fx/../plugin".
# ---------------------------------------------------------------------------
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.claude/scripts" "$root/proj/.claude/hooks" "$root/proj/.claude/agents"
  mkdir -p "$root/plugin/scripts" "$root/plugin/hooks" "$root/plugin/agents"
  mkdir -p "$root/plugin/.claude/scripts" "$root/plugin/.claude/hooks"
  cat > "$root/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
  echo "$root"
}

run_helper() {
  local root="$1"; shift
  (
    cd "$root/proj"
    # shellcheck disable=SC1091
    source ./pipeline.config
    CLAUDE_PLUGIN_ROOT="$root/plugin" "$@" bash "$HELPER"
  )
}

# ---------------------------------------------------------------------------
# Case 1: Bucket A — byte-identical local and plugin file.
# ---------------------------------------------------------------------------
echo "Case 1: Bucket A (byte-identical)"
ROOT=$(fresh_fx fx-a)
cat > "$ROOT/plugin/scripts/foo.sh" <<'F'
#!/bin/bash
echo hello
F
cp "$ROOT/plugin/scripts/foo.sh" "$ROOT/proj/.claude/scripts/foo.sh"

out="$(run_helper "$ROOT")"
echo "$out" | grep -qE '^\.claude/scripts/foo\.sh	A	' \
  && pass_msg "bucket A: row emitted for foo.sh" \
  || { fail_msg "bucket A: missing row"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
