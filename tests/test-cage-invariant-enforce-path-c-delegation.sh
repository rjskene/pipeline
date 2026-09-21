#!/bin/bash
# Cage invariant (#1304) — hooks/enforce-path-c-delegation.py must DENY an
# orchestrator Write to a non-allowlisted impl file on a PATH C issue when no
# covering tdd-implementer subagent has been dispatched.
#
# Characterization test for a guardrail the harness relies on. It pins the
# DENY CONTRACT, not an exit code: Claude Code treats a PreToolUse hook as
# blocking when it exits 2 OR when stdout carries
# `hookSpecificOutput.permissionDecision == "deny"`. Nothing here pins rc == 1.
#
# NOTE ON THE GUARDED PATH: the payload uses the repo-RELATIVE `web/app.js`,
# not an absolute path under the mktemp fixture. The hook allowlists `^/tmp/`
# outright, so an absolute fixture path lands on the allowlist and exits 0 —
# measured. tests/test-enforce-path-c-delegation.sh uses the same relative
# shape for the same reason.
#
# Fixture shape copied from tests/test-enforce-path-c-delegation.sh; harness
# shape from tests/test-restrict-paths-hook.sh. All fixture state lives under
# the mktemp dir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORKDIR=$(mktemp -d)
# The hook memoises the issue-label lookup in /tmp/claude-path-c-<sid>-<n>.cache
# (its own path, not the test's). Clean up the entries this run creates.
trap 'rm -rf "$WORKDIR"; rm -f /tmp/claude-path-c-cage-path-c-*-999.cache' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/logs/subagents" "$PROJ/web"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"

# gh stub: reports the issue's labels. `multi-task` is what makes the session
# PATH C, which is the precondition for the gate.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "multi-task"
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

HOOK_NAME="enforce-path-c-delegation.py"
HOOK="$REPO_ROOT/hooks/$HOOK_NAME"
# hooks/enforce-path-c-delegation.py is contract-compliant today (it exits 2),
# so the #1294 known-red branch is OFF here: an rc of 1 is a hard FAIL.
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
# PreToolUse deny decision.
stdout_deny() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
sys.exit(0 if isinstance(h, dict) and h.get("permissionDecision") == "deny" else 1)' "$1"
}

# Write a synthetic tdd-implementer dispatch record for a session.
write_dispatch() {
  python3 -c 'import json, sys
session_id, prompt_text, out = sys.argv[1:4]
with open(out, "w") as f:
    json.dump({
        "schema_version": 1,
        "timestamp_utc": "2026-09-07T00:00:00",
        "session_id": session_id,
        "agent_id": "abc12345-fake",
        "description": "cage invariant fixture",
        "subagent_type": "tdd-implementer",
        "prompt": prompt_text,
    }, f)' "$1" "$2" "$PROJ/.claude/logs/subagents/dispatch-$1.json"
}

reset_dispatches() { rm -f "$PROJ"/.claude/logs/subagents/*.json; }

# run_hook <hook> <payload> [ENV=VAL ...] — sets RC, writes OUT_FILE/ERR_FILE.
run_hook() {
  local hook="$1"; shift
  local payload="$1"; shift
  set +e
  printf '%s' "$payload" | (cd "$PROJ" && env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:$PATH" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    CLAUDE_PIPELINE_ISSUE_NUMBER=999 \
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

write_payload() {
  printf '{"tool_name":"Write","tool_input":{"file_path":"web/app.js"},"session_id":"%s"}' "$1"
}

echo "Cage invariant: $HOOK_NAME"

# The hook caches the label lookup under /tmp/claude-path-c-<session>-<issue>.
# Distinct session ids per case keep the cases independent; the cache files are
# swept by the hook's own TTL.
reset_dispatches
assert_denied "undelegated Write to an impl file on PATH C must be DENIED" \
  "$(write_payload cage-path-c-denied)"

reset_dispatches
write_dispatch "cage-path-c-allowed" "target=web/"
assert_allowed "Write covered by a target=web/ dispatch must be ALLOWED" \
  "$(write_payload cage-path-c-allowed)"

reset_dispatches
teeth_check "teeth: always-allow stub is not mistaken for a deny" \
  "$(write_payload cage-path-c-teeth)"

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
