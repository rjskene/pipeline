#!/bin/bash
# Cage invariant (#1304) — hooks/enforce-ci-wait.py must DENY a Stop when the
# PR under review has CI configured but the session never waited on it.
#
# Characterization test for a guardrail the harness relies on. It pins the
# DENY CONTRACT, not an exit code: Claude Code treats a hook as blocking when
# it exits 2 OR when stdout carries
# `hookSpecificOutput.permissionDecision == "deny"`. Nothing here pins rc == 1.
#
# NOTE ON EVENT SHAPE: this is a **Stop** hook (matcher `*`), not PreToolUse.
# The event payload is the Stop event ({"session_id", "cwd"}), and the fact
# under test lives in .claude/logs/tool-use.log — not in a tool_input.
#
# Fixture shape copied from tests/test-enforce-ci-wait.sh; harness shape from
# tests/test-restrict-paths-hook.sh. All fixture state lives under the mktemp
# dir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

# gh stub: `--jq '. | length'` reports how many checks the rollup carries, so
# STUB_GH_ROLLUP_LEN=1 means "CI is configured".
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'SHIM'
#!/bin/bash
args="$*"
case "$args" in
  *"[.statusCheckRollup"*) printf '%s' "${STUB_GH_FAIL_COUNT:-0}" ;;
  *". | length"*)          printf '%s' "${STUB_GH_ROLLUP_LEN:-1}" ;;
  *)                       printf '%s' "${STUB_GH_OUT:-}" ;;
esac
SHIM
chmod +x "$STUB_DIR/gh"

OUT_FILE="$WORKDIR/out.txt"
ERR_FILE="$WORKDIR/err.txt"

# Always-allow stub. Used by the permanent teeth check below: if the guarded
# payload is classified "denied" against a hook that does nothing, the
# assertion is vacuous and the invariant has no teeth.
STUB="$WORKDIR/noop-hook.py"
cat > "$STUB" <<'PY'
import sys
sys.stdin.read()
sys.exit(0)
PY

HOOK_NAME="enforce-ci-wait.py"
HOOK="$REPO_ROOT/hooks/$HOOK_NAME"
# hooks/enforce-ci-wait.py is contract-compliant today (it exits 2), so the
# #1294 known-red branch is OFF here: an rc of 1 is a hard FAIL.
KNOWN_RED=0

PASS=0
FAIL=0
SKIP=0
RC=0
VERDICT=""

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
skip_msg() {
  echo "SKIP: KNOWN-RED #1294 — $HOOK_NAME exits 1 on BLOCKED (contract: exit 2 or permissionDecision deny)"
  SKIP=$((SKIP + 1))
}

# A deleted or renamed hook makes `python3 <missing>` exit 2, which the deny
# contract would otherwise read as a block — the exact weakening this
# invariant exists to catch. Fail loudly instead.
if [ ! -f "$HOOK" ]; then
  echo "  FAIL: hook not found at $HOOK — python3 exits 2 on a missing file, which would be misread as a deny"
  echo "RESULT: 0 passed, 1 failed, 0 skipped"
  exit 1
fi

# True when the captured stdout parses as JSON carrying the Claude Code
# deny decision.
stdout_deny() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
sys.exit(0 if isinstance(h, dict) and h.get("permissionDecision") == "deny" else 1)' "$1"
}

# Append one row to the session tool-use log.
# TSV columns: timestamp \t phase \t tool \t session=<sid> \t summary
seed_log_row() {
  printf '%s\tpost\tBash\tsession=%s\t%s\n' "$1" "$2" "$3" \
    >> "$PROJ/.claude/logs/tool-use.log"
}

reset_log() { : > "$PROJ/.claude/logs/tool-use.log"; }

# run_hook <hook> <payload> [ENV=VAL ...] — sets RC, writes OUT_FILE/ERR_FILE.
run_hook() {
  local hook="$1"; shift
  local payload="$1"; shift
  set +e
  printf '%s' "$payload" | (cd "$PROJ" && env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:$PATH" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    CLAUDE_PIPELINE_SKILL=evaluate-issue-pr \
    STUB_GH_ROLLUP_LEN=1 \
    "$@" \
    python3 "$hook") >"$OUT_FILE" 2>"$ERR_FILE"
  RC=$?
  set -e
}

# classify_deny <hook> <payload> [ENV=VAL ...] — sets VERDICT to one of
# deny | known-red | other.
classify_deny() {
  run_hook "$@"
  if [ "$RC" = "2" ]; then VERDICT="deny"; return 0; fi
  if stdout_deny "$OUT_FILE"; then VERDICT="deny"; return 0; fi
  if [ "$RC" = "1" ] && grep -q 'BLOCKED:' "$ERR_FILE"; then VERDICT="known-red"; return 0; fi
  VERDICT="other"
}

assert_denied() {
  local desc="$1"; shift
  classify_deny "$HOOK" "$@"
  case "$VERDICT" in
    deny) pass_msg "$desc" ;;
    known-red)
      if [ "$KNOWN_RED" = "1" ]; then
        skip_msg
      else
        fail_msg "$desc" "expected deny (rc 2 or permissionDecision deny), got rc=$RC; stderr=$(cat "$ERR_FILE")"
      fi
      ;;
    *) fail_msg "$desc" "expected deny (rc 2 or permissionDecision deny), got rc=$RC; stderr=$(cat "$ERR_FILE")" ;;
  esac
}

assert_allowed() {
  local desc="$1"; shift
  run_hook "$HOOK" "$@"
  if [ "$RC" != "0" ]; then
    fail_msg "$desc" "expected allow (rc 0), got rc=$RC; stderr=$(cat "$ERR_FILE")"
    return
  fi
  if stdout_deny "$OUT_FILE"; then
    fail_msg "$desc" "expected allow, but stdout carried a deny decision"
    return
  fi
  pass_msg "$desc"
}

# teeth_check <desc> <payload> [ENV=VAL ...] — the same guarded payload run
# against the always-allow stub must NOT classify as denied.
teeth_check() {
  local desc="$1"; shift
  classify_deny "$STUB" "$@"
  if [ "$VERDICT" = "other" ] && [ "$RC" = "0" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc" "always-allow stub classified '$VERDICT' (rc=$RC) — the deny assertion is vacuous"
  fi
}

stop_payload() {
  printf '{"session_id":"%s","cwd":"%s"}' "$1" "$PROJ"
}

ROLLUP="gh pr view 123 --repo fake/repo --json statusCheckRollup"
WATCH="timeout 600 gh pr checks 123 --repo fake/repo --watch --fail-fast --interval 30"

echo "Cage invariant: $HOOK_NAME"

# Guarded: a rollup query proves CI is configured, but no --watch row exists.
reset_log
seed_log_row "2026-05-14T10:00:00Z" "cage-ci-wait-denied" "$ROLLUP"
assert_denied "Stop with CI configured and no --watch must be DENIED" \
  "$(stop_payload cage-ci-wait-denied)"

# Control: the full rollup -> --watch -> rollup sequence was recorded.
reset_log
seed_log_row "2026-05-14T10:00:00Z" "cage-ci-wait-allowed" "$ROLLUP"
seed_log_row "2026-05-14T10:01:00Z" "cage-ci-wait-allowed" "$WATCH"
seed_log_row "2026-05-14T10:02:00Z" "cage-ci-wait-allowed" "$ROLLUP --jq '.statusCheckRollup'"
assert_allowed "Stop after the full rollup/watch/rollup sequence must be ALLOWED" \
  "$(stop_payload cage-ci-wait-allowed)"

# Teeth: the guarded fixture against an always-allow stub must not read as deny.
reset_log
seed_log_row "2026-05-14T10:00:00Z" "cage-ci-wait-teeth" "$ROLLUP"
teeth_check "teeth: always-allow stub is not mistaken for a deny" \
  "$(stop_payload cage-ci-wait-teeth)"

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
