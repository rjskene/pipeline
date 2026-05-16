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
# Case 2: Bucket F — local file with no plugin counterpart anywhere.
# ---------------------------------------------------------------------------
echo "Case 2: Bucket F (no plugin counterpart)"
ROOT=$(fresh_fx fx-f)
cat > "$ROOT/proj/.claude/hooks/project-specific-hook.py" <<'F'
print("consumer-owned only")
F

out="$(run_helper "$ROOT")"
echo "$out" | grep -qE '^\.claude/hooks/project-specific-hook\.py	F	' \
  && pass_msg "bucket F: row emitted for consumer-only file" \
  || { fail_msg "bucket F: missing row"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: Bucket D — basename only under plugin's $CLAUDE_PLUGIN_ROOT/.claude/ dogfood.
# Local placement is correct; not a duplicate of any shipped file.
# ---------------------------------------------------------------------------
echo "Case 3: Bucket D (plugin-dogfood-only)"
ROOT=$(fresh_fx fx-d)
cat > "$ROOT/plugin/.claude/hooks/log-tool-use.sh" <<'F'
#!/bin/bash
# plugin-author dogfood, not shipped
F
cat > "$ROOT/proj/.claude/hooks/log-tool-use.sh" <<'F'
#!/bin/bash
# consumer copy of dogfood hook
F

out="$(run_helper "$ROOT")"
echo "$out" | grep -qE '^\.claude/hooks/log-tool-use\.sh	D	' \
  && pass_msg "bucket D: row emitted for dogfood-only basename" \
  || { fail_msg "bucket D: missing row"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 4: diff line count emitted for files that differ from plugin.
# Tests the wiring of diff_lines; bucket assignment for non-A/D/F covered later.
# ---------------------------------------------------------------------------
echo "Case 4: diff line count emitted"
ROOT=$(fresh_fx fx-diff-count)
cat > "$ROOT/plugin/scripts/varies.sh" <<'F'
#!/bin/bash
echo a
echo b
echo c
F
cat > "$ROOT/proj/.claude/scripts/varies.sh" <<'F'
#!/bin/bash
echo a
echo X
echo Y
F
# diff -u0 across these files emits 2 changed lines on each side (b,c -> X,Y).

out="$(run_helper "$ROOT")"
# diff_lines is the 5th tab-separated field. Must be > 0 for a drifted file.
row="$(echo "$out" | grep -E '^\.claude/scripts/varies\.sh	')"
diff_lines="$(echo "$row" | awk -F'\t' '{print $5}')"
if [ -n "$diff_lines" ] && [ "$diff_lines" -gt 0 ] 2>/dev/null; then
  pass_msg "diff line count: emitted >0 ($diff_lines) for drifted file"
else
  fail_msg "diff line count: expected >0, got '$diff_lines'"
  echo "    row: $row"
fi

# ---------------------------------------------------------------------------
# Case 5: Bucket B — plugin sources pipeline.config; local has hardcoded value.
# Local's hardcoded literal matches the runtime PIPELINE_REPO (no B.bug subcase).
# ---------------------------------------------------------------------------
echo "Case 5: Bucket B (plugin more capable)"
ROOT=$(fresh_fx fx-b)
cat > "$ROOT/plugin/hooks/enforce-path-c-delegation.py" <<'F'
#!/usr/bin/env python3
# plugin reads PIPELINE_REPO from pipeline.config via shared helper
from _pipeline_config import PIPELINE_REPO
print(PIPELINE_REPO)
F
cat > "$ROOT/proj/.claude/hooks/enforce-path-c-delegation.py" <<'F'
#!/usr/bin/env python3
# stale local copy with hardcoded literal that matches the runtime config
PIPELINE_REPO = "owner/repo-correct"
print(PIPELINE_REPO)
F

out="$(run_helper "$ROOT")"
echo "$out" | grep -qE '^\.claude/hooks/enforce-path-c-delegation\.py	B	' \
  && pass_msg "bucket B: row emitted when plugin sources config and local doesn't" \
  || { fail_msg "bucket B: missing/wrong row"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
