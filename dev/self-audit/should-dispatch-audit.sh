#!/usr/bin/env bash
# should-dispatch-audit.sh — gate helper. Prints `dispatch:<transcript>:<uuid>`
# to stdout when (a) the most-recent *.jsonl under AUDIT_CLAUDE_PROJECTS_DIR
# has mtime newer than the latest index.jsonl row's `timestamp` OR the index
# is empty/missing, AND (b) the transcript has >=10 user/assistant turns.
# Otherwise prints `skip:<reason>`.
#
# Env knobs:
#   AUDIT_OUT_DIR              — default: dev/audits/
#   AUDIT_CLAUDE_PROJECTS_DIR  — default: ~/.claude/projects
#   AUDIT_TURN_THRESHOLD       — default: 10
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="${AUDIT_OUT_DIR:-$REPO_ROOT/dev/audits}"
PROJECTS_DIR="${AUDIT_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
THRESHOLD="${AUDIT_TURN_THRESHOLD:-10}"
INDEX="$OUT_DIR/index.jsonl"

# Locate most-recent transcript by mtime across all project-hash subdirs.
TRANSCRIPT=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
  | sort -n | tail -1 | awk '{print $2}')
if [ -z "${TRANSCRIPT:-}" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "skip:no-transcript-found"; exit 0
fi

# Compare transcript mtime against latest index.jsonl timestamp.
# If the index is missing or empty (first run), fall through — the empty-index
# branch of the spec ("OR no entry yet") proceeds to the turn-count check.
if [ -s "$INDEX" ]; then
  LAST_TS=$(tail -n 1 "$INDEX" | jq -r '.timestamp // ""' 2>/dev/null || true)
  if [ -n "$LAST_TS" ]; then
    LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || echo 0)
    TRANSCRIPT_EPOCH=$(stat -c '%Y' "$TRANSCRIPT" 2>/dev/null || echo 0)
    if [ "$TRANSCRIPT_EPOCH" -le "$LAST_EPOCH" ]; then
      echo "skip:no-newer-transcript"; exit 0
    fi
  fi
fi

# Count user/assistant turns. JSONL: one JSON object per line; count lines
# whose `type` field is `user` or `assistant`.
TURNS=$(grep -cE '"type":"(user|assistant)"' "$TRANSCRIPT" 2>/dev/null || echo 0)
if [ "$TURNS" -lt "$THRESHOLD" ]; then
  echo "skip:turn-count-below-threshold"; exit 0
fi

# Extract sessionId from first turn that carries it (fallback: filename stem).
UUID=$(grep -m1 -oE '"sessionId":"[^"]+"' "$TRANSCRIPT" | cut -d'"' -f4)
[ -n "${UUID:-}" ] || UUID=$(basename "$TRANSCRIPT" .jsonl)

echo "dispatch:${TRANSCRIPT}:${UUID}"
