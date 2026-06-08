#!/bin/bash
set -euo pipefail

# Codex gate-enforcement test (issue #981).
#
# Proves each ported enforcement gate still BLOCKS when fed a *Codex* PreToolUse
# / Stop payload. Codex stdin is a SUPERSET of Claude Code: same
# tool_name / tool_input / hook_event_name, plus model / turn_id / tool_use_id
# (which the hooks ignore). Each script is driven directly (the same script
# .codex/config.toml wires via hooks/_run.sh) with a payload carrying those
# extra Codex keys, and we assert the block contract (exit code + a BLOCKED
# stderr substring).
#
# Per-hook block contracts (mirrored from the existing CC suites):
#   - block_deletions.py        exit 1 (mirrors tests/test_block_deletions.py)
#   - enforce-base-branch.py    exit 1 (mirrors tests/test-enforce-base-branch.sh)
#   - restrict_paths.py         exit 2 (mirrors tests/test-restrict-paths-hook.sh)
#   - enforce-path-c-delegation exit 2 (mirrors tests/test-enforce-path-c-delegation.sh)
#   - enforce-ci-wait.py        exit 2 (mirrors tests/test-enforce-ci-wait.sh)
#
# The apply_patch tool_input shape is pinned against the REAL contract in
# hooks/_tool_input.py: the patch text lives under tool_input["input"] and the
# V4A envelope uses `*** Add/Update/Delete File:` (+ `*** Move to:`) headers.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$REPO_ROOT/hooks"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# Control-file path fragment, assembled so this test script's own invocation is
# never flagged by the live restrict_paths Bash-command scan when it sees our
# command line. (We only ever put the literal in JSON built INSIDE a python -c.)
DOTCLAUDE=".claude"
SETTINGS_REL="$DOTCLAUDE/settings.json"

# Build a Codex-superset PreToolUse payload as JSON. Args:
#   $1 tool_name  $2 tool_input-as-python-dict-literal
# The python builder injects the Codex-only keys model/turn_id/tool_use_id so we
# prove the hooks tolerate (ignore) them.
codex_pretool_payload() {
  local tool_name="$1"; local tool_input_py="$2"
  python3 - "$tool_name" "$tool_input_py" <<'PY'
import json, sys, ast
tool_name = sys.argv[1]
tool_input = ast.literal_eval(sys.argv[2])
payload = {
    "hook_event_name": "PreToolUse",
    "tool_name": tool_name,
    "tool_input": tool_input,
    # Codex-only superset keys the hooks must ignore:
    "model": "gpt-5-codex",
    "turn_id": "turn-abc",
    "tool_use_id": "tu-123",
    "session_id": "codex-sess",
}
sys.stdout.write(json.dumps(payload))
PY
}

# ---------------------------------------------------------------------------
# Gate 1 — block_deletions.py (PreToolUse :: Bash). Destructive command blocks.
# Mirrors a blocked case from tests/test_block_deletions.py (rm -rf). Real
# contract is exit 1 + "BLOCKED:" stderr.
# ---------------------------------------------------------------------------
echo "Gate 1: block_deletions.py blocks a destructive Bash command under Codex payload"
inc
PAYLOAD="$(codex_pretool_payload Bash "{'command': 'rm -rf build'}")"
TMP_ERR="$(mktemp)"
set +e
printf '%s' "$PAYLOAD" | env -i PATH="$PATH" python3 "$HOOKS/block_deletions.py" >/dev/null 2>"$TMP_ERR"
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
if [ "$RC" = "1" ] && printf '%s' "$ERR" | grep -q "BLOCKED: destructive deletion"; then
  pass_msg "exit 1 + BLOCKED stderr (Codex superset keys ignored)"
else
  fail_msg "block_deletions" "expected exit 1 + BLOCKED stderr; got rc=$RC stderr='$ERR'"
fi

# ---------------------------------------------------------------------------
# Gate 2 — enforce-base-branch.py (PreToolUse :: Bash). Wrong --base blocks.
# Mirrors tests/test-enforce-base-branch.sh Case B (gh pr create --base main)
# incl. the project-dir/base-branch env+cwd setup. Real contract exit 1.
# ---------------------------------------------------------------------------
echo "Gate 2: enforce-base-branch.py blocks a wrong-base gh pr create under Codex payload"
inc
BB_PROJ="$(mktemp -d)"
mkdir -p "$BB_PROJ/$DOTCLAUDE"
printf 'staging\n' > "$BB_PROJ/$DOTCLAUDE/base-branch"
printf 'PIPELINE_BASE_BRANCH="staging"\n' > "$BB_PROJ/pipeline.config"
PAYLOAD="$(codex_pretool_payload Bash "{'command': 'gh pr create --base main --title T --body B'}")"
TMP_ERR="$(mktemp)"
set +e
printf '%s' "$PAYLOAD" | env -i HOME="$HOME" PATH="/usr/bin:/bin" \
  CLAUDE_PROJECT_DIR="$BB_PROJ" python3 "$HOOKS/enforce-base-branch.py" >/dev/null 2>"$TMP_ERR"
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
rm -rf "$BB_PROJ"
if [ "$RC" = "1" ] && printf '%s' "$ERR" | grep -q "BLOCKED:"; then
  pass_msg "exit 1 + BLOCKED stderr (wrong base)"
else
  fail_msg "enforce-base-branch" "expected exit 1 + BLOCKED stderr; got rc=$RC stderr='$ERR'"
fi

# ---------------------------------------------------------------------------
# Gate 3 — restrict_paths.py via apply_patch (PreToolUse :: *). Two cases:
#   (a) apply_patch targeting an OUT-OF-BOUNDARY path (/etc/passwd) -> blocked.
#   (b) apply_patch targeting a PROTECTED control file (.claude/settings.json)
#       -> blocked.
# Both prove _tool_input_paths wired apply_patch into restrict_paths. Env mirror
# of tests/test-restrict-paths-hook.sh: CLAUDE_PLUGIN_ROOT + CLAUDE_PROJECT_DIR.
# Real contract exit 2.
# ---------------------------------------------------------------------------
run_restrict() {
  # $1 desc  $2 payload  $3 stderr-grep
  local desc="$1"; local payload="$2"; local grep_for="$3"
  local tmp_err rc stderr
  tmp_err="$(mktemp)"
  set +e
  printf '%s' "$payload" | env -i PATH="$PATH" \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    python3 "$HOOKS/restrict_paths.py" >/dev/null 2>"$tmp_err"
  rc=$?
  set -e
  stderr="$(cat "$tmp_err")"; rm -f "$tmp_err"
  if [ "$rc" = "2" ] && printf '%s' "$stderr" | grep -q -- "$grep_for"; then
    pass_msg "$desc"
  else
    fail_msg "$desc" "expected exit 2 + '$grep_for'; got rc=$rc stderr='$stderr'"
  fi
}

echo "Gate 3a: restrict_paths.py blocks apply_patch targeting /etc/passwd (out of boundary)"
inc
# V4A patch updating an out-of-boundary file. tool_input.input holds the text.
OOB_PATCH="*** Begin Patch
*** Update File: /etc/passwd
@@
-root
+pwned
*** End Patch
"
PAYLOAD="$(codex_pretool_payload apply_patch "{'input': $(python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' <<<"$OOB_PATCH")}")"
run_restrict "apply_patch /etc/passwd blocked (out of boundary)" "$PAYLOAD" "BLOCKED: path outside project boundary"

echo "Gate 3b: restrict_paths.py blocks apply_patch targeting a protected control file"
inc
# Protected: a patch that ADDS the repo-local .claude/settings.json. After
# realpath, is_protected matches the .claude/settings.json$ pattern. Path built
# from $REPO_ROOT + the assembled SETTINGS_REL fragment.
PROT_TARGET="$REPO_ROOT/$SETTINGS_REL"
PROT_PATCH="*** Begin Patch
*** Add File: $PROT_TARGET
+{}
*** End Patch
"
PAYLOAD="$(codex_pretool_payload apply_patch "{'input': $(python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))' <<<"$PROT_PATCH")}")"
run_restrict "apply_patch protected control file blocked" "$PAYLOAD" "BLOCKED: cannot modify protected file"

# ---------------------------------------------------------------------------
# Gate 4 — enforce-path-c-delegation.py via apply_patch (PreToolUse). A patch
# touching a NON-allowlisted impl file under a PATH-C (multi-task) issue with NO
# authorizing target=<dir> dispatch -> blocked (exit 2). Harness/setup mirrors
# tests/test-enforce-path-c-delegation.sh (issue-number env, gh label stub,
# subagent-log dir). Proves apply_patch flows through _tool_input_paths here too.
# ---------------------------------------------------------------------------
echo "Gate 4: enforce-path-c-delegation.py blocks apply_patch of impl file with no dispatch (PATH C)"
inc
PCD_PROJ="$(mktemp -d)"
mkdir -p "$PCD_PROJ/$DOTCLAUDE/logs/subagents" "$PCD_PROJ/web"
printf 'PIPELINE_REPO="fake/repo"\n' > "$PCD_PROJ/pipeline.config"
PCD_STUB="$(mktemp -d)"
cat > "$PCD_STUB/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${STUB_LABELS:-}"
EOF
chmod +x "$PCD_STUB/gh"
# apply_patch updating web/foo.ts (a non-allowlisted impl file).
PCD_PATCH="*** Begin Patch
*** Update File: web/foo.ts
@@
-a
+b
*** End Patch
"
PAYLOAD="$(python3 - "$PCD_PATCH" <<'PY'
import json, sys
patch = sys.argv[1]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "tool_name": "apply_patch",
    "tool_input": {"input": patch},
    "model": "gpt-5-codex", "turn_id": "turn-pcd", "tool_use_id": "tu-pcd",
    "session_id": "codex-pcd-sess",
}))
PY
)"
TMP_ERR="$(mktemp)"
set +e
( cd "$PCD_PROJ" && printf '%s' "$PAYLOAD" | env -i \
    HOME="$HOME" PATH="$PCD_STUB:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PCD_PROJ" \
    CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS="multi-task" \
    python3 "$HOOKS/enforce-path-c-delegation.py" >/dev/null 2>"$TMP_ERR" )
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
rm -rf "$PCD_PROJ" "$PCD_STUB"
# Sweep the /tmp cache this run wrote so we don't leak state across runs.
rm -f /tmp/claude-path-c-codex-pcd-sess-999.cache 2>/dev/null || true
if [ "$RC" = "2" ] && printf '%s' "$ERR" | grep -q "BLOCKED: PATH C"; then
  pass_msg "exit 2 + BLOCKED stderr (apply_patch impl file, no dispatch)"
else
  fail_msg "enforce-path-c-delegation" "expected exit 2 + BLOCKED PATH C stderr; got rc=$RC stderr='$ERR'"
fi

# ---------------------------------------------------------------------------
# Gate 5 — enforce-ci-wait.py (Stop :: *). A Stop payload that should HOLD.
# Mirrors a blocking case from tests/test-enforce-ci-wait.sh (Test 3): CI present
# (rollup len 1) but NO `--watch` row recorded -> exit 2 on Stop.
# ---------------------------------------------------------------------------
echo "Gate 5: enforce-ci-wait.py blocks on Stop when CI present but --watch missing"
inc
CIW_PROJ="$(mktemp -d)"
mkdir -p "$CIW_PROJ/$DOTCLAUDE/logs"
printf 'PIPELINE_REPO="fake/repo"\n' > "$CIW_PROJ/pipeline.config"
CIW_STUB="$(mktemp -d)"
cat > "$CIW_STUB/gh" <<'EOF'
#!/bin/bash
args="$*"
case "$args" in
  *"[.statusCheckRollup"*) printf '%s' "${STUB_GH_FAIL_COUNT:-0}" ;;
  *". | length"*)          printf '%s' "${STUB_GH_ROLLUP_LEN:-1}" ;;
  *"issue edit"*|*"pr comment"*) : ;;
  *) printf '%s' "${STUB_GH_OUT:-}" ;;
esac
EOF
chmod +x "$CIW_STUB/gh"
# Seed a rollup-query row so the hook believes CI was queried for this session.
printf '%s\tpost\tBash\tsession=%s\t%s\n' \
  "2026-05-14T10:00:00Z" "codex-ciw-sess" \
  "gh pr view 123 --repo fake/repo --json statusCheckRollup" \
  >> "$CIW_PROJ/$DOTCLAUDE/logs/tool-use.log"
# Stop payload carries the Codex superset keys too.
PAYLOAD="$(python3 - "$CIW_PROJ" <<'PY'
import json, sys
proj = sys.argv[1]
print(json.dumps({
    "hook_event_name": "Stop",
    "session_id": "codex-ciw-sess",
    "cwd": proj,
    "model": "gpt-5-codex", "turn_id": "turn-ciw", "tool_use_id": "tu-ciw",
}))
PY
)"
TMP_ERR="$(mktemp)"
set +e
( cd "$CIW_PROJ" && printf '%s' "$PAYLOAD" | env -i \
    HOME="$HOME" PATH="$CIW_STUB:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$CIW_PROJ" \
    CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN="1" \
    python3 "$HOOKS/enforce-ci-wait.py" >/dev/null 2>"$TMP_ERR" )
RC=$?
set -e
ERR="$(cat "$TMP_ERR")"; rm -f "$TMP_ERR"
rm -rf "$CIW_PROJ" "$CIW_STUB"
if [ "$RC" = "2" ] && printf '%s' "$ERR" | grep -q "CI-wait gate: --watch invocation not found"; then
  pass_msg "exit 2 + CI-wait stderr (Stop held: --watch missing)"
else
  fail_msg "enforce-ci-wait" "expected exit 2 + CI-wait stderr on Stop; got rc=$RC stderr='$ERR'"
fi

echo ""
echo "================================"
echo "  $TESTS gates: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
