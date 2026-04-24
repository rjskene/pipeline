#!/bin/bash
set -euo pipefail

# Tests for .claude-pipeline/hooks/enforce-base-branch.py.template.
# Verifies the rendered hook reads EXPECTED_BASE from
# $CLAUDE_PROJECT_DIR/.claude/base-branch at invocation time, falling
# back to PIPELINE_BASE_BRANCH when the metadata file is missing,
# empty, or unreadable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../hooks/enforce-base-branch.py.template"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Render the template with PIPELINE_BASE_BRANCH=pipeline so the fallback
# default is a known string.
HOOK="$WORKDIR/enforce-base-branch.py"
PIPELINE_BASE_BRANCH="pipeline" \
  envsubst '$PIPELINE_BASE_BRANCH' < "$TEMPLATE" > "$HOOK"

# Run the hook with a payload and a CLAUDE_PROJECT_DIR. Echoes the
# exit code on stdout; writes stderr/stdout to $WORKDIR/out, $WORKDIR/err.
run_hook() {
  local payload="$1"
  local project_dir="$2"
  set +e
  echo "$payload" | env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$project_dir" \
    python3 "$HOOK" >"$WORKDIR/out" 2>"$WORKDIR/err"
  local rc=$?
  set -e
  echo "$rc"
}

payload_base() {
  # Emit a tool_input JSON payload for `gh pr create --base <arg>`.
  local base_arg="$1"
  printf '{"tool_input":{"command":"gh pr create --base %s --title t --body b"}}' "$base_arg"
}

# --- Case A: metadata=next, command --base next -> allow (rc 0) ---
echo "Case A: metadata=next allows --base next"
inc
PROJ="$WORKDIR/projA"
mkdir -p "$PROJ/.claude"
printf 'next\n' > "$PROJ/.claude/base-branch"
rc=$(run_hook "$(payload_base next)" "$PROJ")
if [ "$rc" = "0" ]; then
  pass_msg "Case A: allowed --base next"
else
  fail_msg "Case A: expected rc=0, got rc=$rc (stderr: $(cat "$WORKDIR/err"))"
fi

# --- Case B: metadata=next, command --base pipeline -> block (rc 1) ---
echo "Case B: metadata=next blocks --base pipeline"
inc
PROJ="$WORKDIR/projB"
mkdir -p "$PROJ/.claude"
printf 'next\n' > "$PROJ/.claude/base-branch"
rc=$(run_hook "$(payload_base pipeline)" "$PROJ")
if [ "$rc" = "1" ] && grep -q "next" "$WORKDIR/err"; then
  pass_msg "Case B: blocked --base pipeline with message naming 'next'"
else
  fail_msg "Case B: expected rc=1 and 'next' in stderr, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Case C: metadata missing -> falls back to PIPELINE_BASE_BRANCH ---
echo "Case C: missing metadata falls back to 'pipeline'"
inc
PROJ="$WORKDIR/projC"
mkdir -p "$PROJ/.claude"   # no base-branch file
rc=$(run_hook "$(payload_base pipeline)" "$PROJ")
if [ "$rc" = "0" ]; then
  pass_msg "Case C: missing metadata -> allowed --base pipeline"
else
  fail_msg "Case C: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi
inc
rc=$(run_hook "$(payload_base next)" "$PROJ")
if [ "$rc" = "1" ]; then
  pass_msg "Case C: missing metadata -> blocked --base next"
else
  fail_msg "Case C: expected rc=1, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Case D: metadata empty -> falls back to PIPELINE_BASE_BRANCH ---
echo "Case D: empty metadata falls back to 'pipeline'"
inc
PROJ="$WORKDIR/projD"
mkdir -p "$PROJ/.claude"
: > "$PROJ/.claude/base-branch"
rc=$(run_hook "$(payload_base pipeline)" "$PROJ")
if [ "$rc" = "0" ]; then
  pass_msg "Case D: empty metadata -> allowed --base pipeline"
else
  fail_msg "Case D: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

# --- Case E: metadata path is a directory (OSError) -> falls back ---
echo "Case E: directory-at-metadata-path falls back to 'pipeline'"
inc
PROJ="$WORKDIR/projE"
mkdir -p "$PROJ/.claude/base-branch"   # directory, not file
rc=$(run_hook "$(payload_base pipeline)" "$PROJ")
if [ "$rc" = "0" ]; then
  pass_msg "Case E: directory-at-path -> allowed --base pipeline (fail-open)"
else
  fail_msg "Case E: expected rc=0, got rc=$rc, stderr: $(cat "$WORKDIR/err")"
fi

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
