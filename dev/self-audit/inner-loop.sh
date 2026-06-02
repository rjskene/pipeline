#!/usr/bin/env bash
# inner-loop.sh — generate a per-run audit digest covering work merged
# since the last audit. Writes a markdown digest + a one-line JSONL entry
# to index.jsonl. Fires outer-loop after every 3 new inner entries.
#
# Env knobs:
#   AUDIT_OUT_DIR              — output dir (default: dev/audits/)
#   AUDIT_LOGS_DIR             — observability logs (default: .claude/logs/)
#   AUDIT_CLAUDE_PROJECTS_DIR  — orchestrator transcript dir
#                                (default: ~/.claude/projects)
#   AUDIT_OUTER_LOOP_DISABLED  — set to 1 to skip outer-loop fire (used in tests)
#   AUDIT_OUTER_THRESHOLD      — default 3
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

OUT_DIR="${AUDIT_OUT_DIR:-$REPO_ROOT/dev/audits}"
LOGS_DIR="${AUDIT_LOGS_DIR:-$REPO_ROOT/.claude/logs}"
PROJECTS_DIR="${AUDIT_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
OUTER_THRESHOLD="${AUDIT_OUTER_THRESHOLD:-3}"

mkdir -p "$OUT_DIR"
INDEX="$OUT_DIR/index.jsonl"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DIGEST="$OUT_DIR/inner-${NOW_ISO//:/}.md"

# shellcheck source=/dev/null
source "$REPO_ROOT/dev/self-audit/redact.sh"

SINCE=""
if [ -s "$INDEX" ]; then
  SINCE=$(tail -n 1 "$INDEX" | jq -r '.timestamp // ""' 2>/dev/null || true)
fi

PR_JSON="[]"
if command -v gh >/dev/null 2>&1; then
  PR_JSON=$(gh pr list --state merged --base "${PIPELINE_BASE_BRANCH:-staging}" \
    --search "merged:>${SINCE:-2000-01-01T00:00:00Z}" \
    --json number,title,mergedAt,headRefName --limit 50 2>/dev/null \
    | jq '[.[] | select(.headRefName | startswith("feature/"))]' 2>/dev/null \
    || echo "[]")
fi
PR_COUNT=$(printf '%s' "$PR_JSON" | jq 'length' 2>/dev/null || echo 0)

{
  cat <<MD
# Inner audit — $NOW_ISO

**Window:** ${SINCE:-genesis} → $NOW_ISO
**Merged feature PRs in window:** $PR_COUNT

## Compliance
MD

  if [ "$PR_COUNT" -gt 0 ]; then
    printf '%s\n' "$PR_JSON" | jq -r '.[] | "- PR #\(.number) — \(.title) (branch \(.headRefName))"' \
      | redact
  else
    echo "- No merged feature PRs in window."
  fi
  cat <<'MD'
- TDD pattern check: MVP heuristic — does each PR's commit history show a test commit before an impl commit? (Inspect git log of feature branch.) Surfaces deviations only.
- Wave-prioritization adherence: TODO (depends on runs.log path-tier annotation).
- PATH-tier dispatch routing: TODO (depends on #80).
- Hook trip counts: TODO (depends on per-hook log files).

## Interaction
MD

  # Derive prior session UUID + one-liner from runs.log (most recent row).
  # The subagent classifier (dispatched during a /pipeline:status session) finds
  # the placeholder line via exact-string match and replaces it via Edit.
  PRIOR_LINE=$(tail -n 1 "$LOGS_DIR/runs.log" 2>/dev/null || true)
  if [ -n "$PRIOR_LINE" ]; then
    PRIOR_UUID=$(printf '%s' "$PRIOR_LINE" | grep -oE 'session=[a-zA-Z0-9_-]+' | head -1 | cut -d= -f2)
    PRIOR_PATH=$(printf '%s' "$PRIOR_LINE" | grep -oE 'path=[ABC]' | head -1 | cut -d= -f2)
    PRIOR_SKILL=$(printf '%s' "$PRIOR_LINE" | grep -oE 'skill=[a-zA-Z0-9_-]+' | head -1 | cut -d= -f2)
    PRIOR_ISSUE=$(printf '%s' "$PRIOR_LINE" | grep -oE 'issue=[0-9]+' | head -1 | cut -d= -f2)
    echo "- prior session: issue=#${PRIOR_ISSUE:-?} path=${PRIOR_PATH:-?} skill=${PRIOR_SKILL:-?} (session ${PRIOR_UUID:-unknown})"
    echo "- _pending subagent classification — session ${PRIOR_UUID:-unknown}_"
  else
    echo "- prior session: (runs.log empty)"
    echo "- _pending subagent classification — session unknown_"
  fi

  cat <<'MD'

## Pattern → defaults
- Cross-session signal detection lives in outer-loop.sh; this inner digest reports per-run noise.

## Efficiency
- Total tokens per issue: TODO (sum from .claude/logs/subagents/*.json).
- Wall clock per issue: TODO.
- Re-plan loop count per issue: TODO.
- Eval-Revise verdict frequency: TODO.

## Data quality
MD
  for src in \
    "subagents:$LOGS_DIR/subagents" \
    "tool-use:$LOGS_DIR/tool-use.log" \
    "runs:$LOGS_DIR/runs.log" \
    "transcripts:$PROJECTS_DIR"; do
    name="${src%%:*}"
    path="${src#*:}"
    if [ -e "$path" ]; then
      echo "- $name: present ($path)"
    else
      echo "- $name: MISSING ($path)"
    fi
  done
} > "$DIGEST"

jq -nc \
  --arg ts   "$NOW_ISO" \
  --arg dig  "$(basename "$DIGEST")" \
  --argjson n "$PR_COUNT" \
  '{timestamp:$ts, digest:$dig, merged_prs:$n}' \
  >> "$INDEX"

if [ "${AUDIT_OUTER_LOOP_DISABLED:-0}" != "1" ]; then
  OUTER="$REPO_ROOT/dev/self-audit/outer-loop.sh"
  NEW_COUNT=$(wc -l < "$INDEX")
  if [ "$NEW_COUNT" -ge "$OUTER_THRESHOLD" ] \
     && [ $(( NEW_COUNT % OUTER_THRESHOLD )) -eq 0 ] \
     && [ -x "$OUTER" ]; then
    ( nohup setsid bash "$OUTER" >>"$OUT_DIR/outer.log" 2>&1 & ) >/dev/null 2>&1 || true
  fi
fi

exit 0
