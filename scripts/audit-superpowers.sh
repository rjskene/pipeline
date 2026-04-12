#!/bin/bash
set -euo pipefail

# audit-superpowers.sh — Cross-reference DISPATCH claims in session logs
# against Skill invocations in tool-use logs, with session-level filtering.
#
# Usage: bash .claude-pipeline/scripts/audit-superpowers.sh <issue-number> [worktree-path]
# Exit: 0 = pass (or no data), 1 = unverified claims found

if [ -z "${1:-}" ]; then
  echo "Usage: bash .claude-pipeline/scripts/audit-superpowers.sh <issue-number> [worktree-path]"
  exit 1
fi

ISSUE_NUM="$1"
WORKTREE_PATH="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"

LOG_DIR="${WORKTREE_PATH}/.claude/logs"
SESSION_LOG=$(ls -t "$LOG_DIR"/issue-"${ISSUE_NUM}"-*.log 2>/dev/null | head -1 || true)
TOOL_USE_LOG="${LOG_DIR}/tool-use.log"

# Also check for consolidated per-issue tool-use log
if [ ! -f "$TOOL_USE_LOG" ]; then
  TOOL_USE_LOG="${LOG_DIR}/tool-use-issue-${ISSUE_NUM}.log"
fi

# --- Helpers ---

strip_ansi() {
  # Strip ANSI/terminal control sequences:
  # - SGR sequences (\e[...m)
  # - CSI sequences beyond SGR (\e[...X where X is any letter)
  # - OSC sequences (\e]...BEL)
  # - Character set switches (\e(X, \e)X)
  # - Carriage returns
  # Known limitation: does not handle APC, PM, or SOS sequences.
  sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b\][^\x07]*\x07//g; s/\x1b[()][0-9A-B]//g; s/\r//g'
}

# --- Check for session log ---

if [ -z "$SESSION_LOG" ] || [ ! -f "$SESSION_LOG" ]; then
  echo "NODATA: No session log found for issue #${ISSUE_NUM}"
  echo ""
  echo "Audit: 0 dispatched (0 verified, 0 unverified), 0 skipped"
  exit 0
fi

# --- Extract claims and skips from session log ---

CLEANED=$(cat "$SESSION_LOG" | strip_ansi)

echo "$CLEANED" | grep -o '\[superpowers\] DISPATCH: superpowers:[a-z-]*' \
  | sed 's/\[superpowers\] DISPATCH: //' | sort -u > /tmp/sp-claims.txt 2>/dev/null || true

echo "$CLEANED" | grep -o '\[superpowers\] SKIP: superpowers:[a-z-]*' \
  | sed 's/\[superpowers\] SKIP: //' | sort -u > /tmp/sp-skips.txt 2>/dev/null || true

DISPATCH_COUNT=$(wc -l < /tmp/sp-claims.txt 2>/dev/null | tr -d ' ')
SKIP_COUNT=$(wc -l < /tmp/sp-skips.txt 2>/dev/null | tr -d ' ')

# --- Try to extract session ID from ## Superpowers block ---

SESSION_ID=$(echo "$CLEANED" | grep -oP 'Session: \K\S+' | head -1 || true)

# --- Cross-reference against tool-use log ---

VERIFIED=0
UNVERIFIED=0
UNANNOUNCED=0

if [ -f "$TOOL_USE_LOG" ]; then
  # Extract Skill invocations, optionally filtered by session
  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "unknown" ]; then
    grep "Skill:.*superpowers:.*session=${SESSION_ID}" "$TOOL_USE_LOG" 2>/dev/null \
      | grep -oP 'skill=\Ksuperpowers:[a-z-]*' | sort -u > /tmp/sp-evidence.txt 2>/dev/null || true
  else
    grep 'Skill:.*skill=superpowers:' "$TOOL_USE_LOG" 2>/dev/null \
      | grep -oP 'skill=\Ksuperpowers:[a-z-]*' | sort -u > /tmp/sp-evidence.txt 2>/dev/null || true
  fi

  # Claims without evidence
  comm -23 /tmp/sp-claims.txt /tmp/sp-evidence.txt > /tmp/sp-unverified.txt 2>/dev/null || true
  # Evidence without claims
  comm -13 /tmp/sp-claims.txt /tmp/sp-evidence.txt > /tmp/sp-unannounced.txt 2>/dev/null || true

  # Report DISPATCH results
  while IFS= read -r skill; do
    if grep -qx "$skill" /tmp/sp-evidence.txt 2>/dev/null; then
      echo "PASS: $skill — dispatched and verified in tool-use log"
      VERIFIED=$((VERIFIED + 1))
    else
      echo "FAIL: $skill — DISPATCH claimed but no Skill invocation found"
      UNVERIFIED=$((UNVERIFIED + 1))
    fi
  done < /tmp/sp-claims.txt

  # Report unannounced invocations
  while IFS= read -r skill; do
    echo "INFO: $skill — invoked via Skill tool but no DISPATCH announcement"
    UNANNOUNCED=$((UNANNOUNCED + 1))
  done < /tmp/sp-unannounced.txt

  # Session ID warning
  if [ -z "$SESSION_ID" ] || [ "$SESSION_ID" = "unknown" ]; then
    echo "WARN: session ID unavailable — audit is best-effort"
  fi
else
  # No tool-use log — report all claims as NODATA
  while IFS= read -r skill; do
    echo "NODATA: $skill — no tool-use log available"
  done < /tmp/sp-claims.txt
fi

# Report SKIP results
while IFS= read -r skill; do
  echo "OK: $skill — SKIP announced"
done < /tmp/sp-skips.txt

# --- Summary ---

echo ""
echo "Audit: ${DISPATCH_COUNT} dispatched (${VERIFIED} verified, ${UNVERIFIED} unverified), ${SKIP_COUNT} skipped"

# --- Cleanup ---

rm -f /tmp/sp-claims.txt /tmp/sp-skips.txt /tmp/sp-evidence.txt /tmp/sp-unverified.txt /tmp/sp-unannounced.txt

# Exit 1 if unverified claims found
if [ "$UNVERIFIED" -gt 0 ]; then
  exit 1
fi
exit 0
