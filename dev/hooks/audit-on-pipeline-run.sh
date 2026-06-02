#!/usr/bin/env bash
# audit-on-pipeline-run.sh — UserPromptSubmit hook entrypoint.
#
# Contract:
#   - Reads JSON {"prompt": "..."} from stdin.
#   - If the prompt (after stripping leading whitespace) starts with
#     "/pipeline:status" (canonical) or "/pipeline:run" (deprecated alias),
#     backgrounds the audit inner-loop and returns.
#   - Otherwise: no-op.
#   - MUST return in <200ms so it never blocks the user's prompt.
#   - Errors are swallowed (fail-open) — the audit is best-effort.
#
# Env knobs (mostly for tests):
#   AUDIT_INNER_LOOP  — path to inner-loop script
#                       (default: dev/self-audit/inner-loop.sh next to this file)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
INNER="${AUDIT_INNER_LOOP:-$REPO_ROOT/dev/self-audit/inner-loop.sh}"
LOG_DIR="$REPO_ROOT/dev/audits"
LOG_FILE="$LOG_DIR/hook.log"

# Fail-open everywhere.
{ mkdir -p "$LOG_DIR"; } 2>/dev/null || true

# Read stdin (the Claude Code hook contract).
INPUT=$(cat 2>/dev/null || true)

# Extract prompt with jq if available; otherwise grep+sed fallback. Errors
# produce empty string (hook becomes no-op).
PROMPT=""
if command -v jq >/dev/null 2>&1; then
  PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null || true)
else
  PROMPT=$(printf '%s' "$INPUT" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
fi

# Strip leading whitespace.
PROMPT_STRIPPED="${PROMPT#"${PROMPT%%[![:space:]]*}"}"

case "$PROMPT_STRIPPED" in
  /pipeline:status|/pipeline:status\ *|/pipeline:run|/pipeline:run\ *)
    if [ -x "$INNER" ]; then
      (
        nohup setsid bash "$INNER" >>"$LOG_FILE" 2>&1 &
      ) >/dev/null 2>&1 || true
    fi
    ;;
  *) : ;;
esac

exit 0
