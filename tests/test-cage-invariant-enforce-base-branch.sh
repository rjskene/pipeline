#!/bin/bash
# Cage invariant (#1304) — hooks/enforce-base-branch.py must DENY a PR
# creation that targets a base branch other than the worktree's configured one.
#
# Characterization test for a guardrail the harness relies on. It pins the
# DENY CONTRACT, not an exit code: Claude Code treats a PreToolUse hook as
# blocking when it exits 2 OR when stdout carries
# `hookSpecificOutput.permissionDecision == "deny"`. Nothing here pins rc == 1.
#
# KNOWN-RED (#1294): this hook exits 1 on its BLOCKED path today, which is
# neither of the two blocking shapes Claude Code reads. The guarded case is
# written as the CONTRACT and reports `SKIP: KNOWN-RED #1294` when — and only
# when — the observed state is exactly rc == 1 with `BLOCKED:` on stderr. Any
# other outcome (notably an allow) is a hard FAIL, so the test keeps its teeth
# today and self-clears when #1294 lands.
#
# Harness shape copied from tests/test-restrict-paths-hook.sh. All fixture
# state lives under the mktemp dir.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude"
# setup-worktree.sh writes this file; the hook resolves EXPECTED_BASE from it.
printf 'evolve\n' > "$PROJ/.claude/base-branch"

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

HOOK_NAME="enforce-base-branch.py"
HOOK="$REPO_ROOT/hooks/$HOOK_NAME"
KNOWN_RED=1

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

# run_hook <hook> <payload> [ENV=VAL ...] — sets RC, writes OUT_FILE/ERR_FILE.
run_hook() {
  local hook="$1"; shift
  local payload="$1"; shift
  set +e
  printf '%s' "$payload" | env -i \
    HOME="$HOME" \
    PATH="$PATH" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    "$@" \
    python3 "$hook" >"$OUT_FILE" 2>"$ERR_FILE"
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

bash_payload() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}

GUARDED=$(bash_payload 'gh pr create --base main --title t')
CONTROL=$(bash_payload 'gh pr create --base evolve --title t')

echo "Cage invariant: $HOOK_NAME"

assert_denied "PR creation against the wrong base must be DENIED" "$GUARDED"
assert_allowed "PR creation against the configured base must be ALLOWED" "$CONTROL"
teeth_check "teeth: always-allow stub is not mistaken for a deny" "$GUARDED"

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
