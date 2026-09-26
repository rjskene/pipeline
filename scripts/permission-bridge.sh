#!/bin/bash
set -euo pipefail

# permission-bridge.sh — operator side of the headless permission bridge (#1421).
#
# hooks/permission-bridge.py writes `<queue>/<id>.json` for every escalated
# permission request in a headless (`claude -p`) session and then BLOCKS,
# polling `<queue>/<id>.answer`, until this script writes one or the deadline
# (PIPELINE_PERMISSION_BRIDGE_TIMEOUT, default 840 s) passes and the request is
# denied. The launching interactive session is the watcher; this is its CLI.
#
# Usage:
#   permission-bridge.sh pending                       # unanswered requests
#   permission-bridge.sh show <id>                     # the request verbatim
#   permission-bridge.sh answer <id> allow|deny [msg]  # decide
#   permission-bridge.sh prune                         # drop stale answered pairs
#
# Operator loop (docs/operational-notes.md § 15):
#   watch `pending` from the LAUNCHING repo in a persistent Monitor until-loop;
#   `show` anything you do not recognise; `answer` it. `pending` on an empty or
#   missing queue dir prints nothing and exits 0, so the loop never errors while
#   there is nothing to do.
#
# Queue dir: PIPELINE_PERMISSION_BRIDGE_DIR, else
# ${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/permission-queue — the
# LAUNCHING repo's gitignored scratch dir, which is on the pipeline runtime
# allow-list. Never the per-issue worktree: that is the child's cwd, not the
# directory the operator's session is sitting in.

PREVIEW_MAX=80
PRUNE_MIN_AGE_DAYS=1

QUEUE_DIR="${PIPELINE_PERMISSION_BRIDGE_DIR:-${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/permission-queue}"

usage() {
  cat >&2 <<'USAGE'
Usage: permission-bridge.sh <subcommand>
  pending                       list unanswered permission requests, one per line
  show <id>                     print the queued request verbatim
  answer <id> allow|deny [msg]  answer a request (msg is carried to the session)
  prune                         delete answered request/answer pairs older than 1 day
USAGE
}

die() { echo "permission-bridge: $*" >&2; exit 1; }

# require_queued <id> — the queue file must exist before show/answer act on it.
require_queued() {
  [ -n "${1:-}" ] || { usage; exit 2; }
  [ -f "$QUEUE_DIR/$1.json" ] \
    || die "no queued request with id '$1' in $QUEUE_DIR"
}

# preview_of <queue-file> — one-line, PREVIEW_MAX-capped rendering of
# tool_input. Compact JSON (or the bare `command` when there is one) so the
# HEAD of the actual command is what the operator sees; python because jq is
# not a hard dependency of this script's callers.
preview_of() {
  python3 -c '
import json, sys
maxlen = int(sys.argv[2])
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("<unreadable>")
    sys.exit(0)
ti = d.get("tool_input", {})
if isinstance(ti, dict) and isinstance(ti.get("command"), str):
    s = ti["command"]
elif isinstance(ti, str):
    s = ti
else:
    s = json.dumps(ti, sort_keys=True, separators=(",", ":"))
s = " ".join(str(s).split())
print(s[:maxlen])
' "$1" "$PREVIEW_MAX" 2>/dev/null || echo "<unreadable>"
}

field_of() { # <queue-file> <key> <fallback>
  python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    v = ""
print(v if isinstance(v, str) and v else sys.argv[3])
' "$1" "$2" "$3" 2>/dev/null || echo "$3"
}

cmd_pending() {
  [ -d "$QUEUE_DIR" ] || return 0
  local f id
  # `find | sort` rather than a glob: an empty dir must print nothing at all
  # (the watch loop greps this), and nullglob is not on by default.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(basename "$f" .json)"
    [ -e "$QUEUE_DIR/$id.answer" ] && continue
    printf '%s  issue=%s  tool=%s  input=%s\n' \
      "$id" "$(field_of "$f" issue -)" "$(field_of "$f" tool_name -)" \
      "$(preview_of "$f")"
  done < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | sort)
}

cmd_show() {
  require_queued "${1:-}"
  cat "$QUEUE_DIR/$1.json"
}

cmd_answer() {
  local id="${1:-}" verdict="${2:-}"
  shift 2 2>/dev/null || { usage; exit 2; }
  require_queued "$id"
  case "$verdict" in
    allow|deny) ;;
    *) die "verdict must be 'allow' or 'deny' (got '${verdict:-<empty>}') — nothing written" ;;
  esac
  local msg="$*"
  local tmp="$QUEUE_DIR/$id.answer.tmp"
  # tmp + mv, never a direct append: the hook polls this path every 2 s and a
  # partially-written file would be read as a malformed answer (-> deny).
  if [ -n "$msg" ]; then
    printf '%s\n%s\n' "$verdict" "$msg" > "$tmp"
  else
    printf '%s\n' "$verdict" > "$tmp"
  fi
  mv -f "$tmp" "$QUEUE_DIR/$id.answer"
  echo "permission-bridge: answered $id -> $verdict"
}

cmd_prune() {
  [ -d "$QUEUE_DIR" ] || return 0
  local f id n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(basename "$f" .json)"
    # ANSWERED only: an unanswered request is still an open question, however
    # old — the operator may yet want to see what the session asked for.
    [ -e "$QUEUE_DIR/$id.answer" ] || continue
    rm -f "$f" "$QUEUE_DIR/$id.answer"
    n=$((n + 1))
  done < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name '*.json' \
             -mtime "+$((PRUNE_MIN_AGE_DAYS - 1))" 2>/dev/null | sort)
  echo "permission-bridge: pruned $n answered request(s) older than ${PRUNE_MIN_AGE_DAYS}d from $QUEUE_DIR"
}

SUB="${1:-}"
shift || true
case "$SUB" in
  pending) cmd_pending "$@" ;;
  show)    cmd_show "$@" ;;
  answer)  cmd_answer "$@" ;;
  prune)   cmd_prune "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *)       usage; exit 2 ;;
esac
