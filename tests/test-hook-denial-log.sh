#!/bin/bash
set -euo pipefail

# Contract test for the hook-denial log (issue #1352).
#
# Every guard hook that denies (exit 2) must append exactly ONE JSONL record
# to $CLAUDE_PROJECT_DIR/.claude/logs/hook-denials.jsonl, gated on
# PIPELINE_LOGS_ENABLED=true (the same gate and allow-listed path family as
# tool-use.log / agent-costs.jsonl). Record shape:
#
#   {"ts","hook","tool","session","reason","command"}
#
# Cases:
#   (a) gate ON  — one well-formed record per denied hook, `hook` == file stem
#   (b) gate OFF — no hook-denials.jsonl is created at all (unset and =false)
#   (c) exit code is still 2 in BOTH gate states, for every hook (CONTROL —
#       pinned to the PRE-change value; this row must stay green throughout)
#   (d) secret masking (hooks/command_mask.py) + 512-char truncation
#   (e) fail-open — an unwritable log path (the jsonl made a DIRECTORY) still
#       denies with byte-identical stderr
#   (f) allow-path purity — allowed calls under gate ON write ZERO records
#
# Hermeticity: HOME and CLAUDE_PROJECT_DIR are redirected into a mktemp dir.
# This is MANDATORY — the repo's live pipeline.config sets
# PIPELINE_LOGS_ENABLED=true, so a test that leaves CLAUDE_PROJECT_DIR unset
# would write into the real repo .claude/logs/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/hooks"
LOG_REL=".claude/logs/hook-denials.jsonl"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORK=$(mktemp -d)
PROJ="$WORK/project"
STUB_DIR="$WORK/stub"
GWORK=""
cleanup() {
  rm -rf "$WORK" "${GWORK:-}"
  rm -f /tmp/claude-path-c-denylog-*.cache
}
trap cleanup EXIT

mkdir -p "$WORK/home" "$STUB_DIR" "$PROJ/.claude/logs/subagents" "$PROJ/web"
export HOME="$WORK/home"

# pipeline.config deliberately does NOT set PIPELINE_LOGS_ENABLED — the gate is
# driven per-run through the process env (which wins when set).
printf 'PIPELINE_BASE_BRANCH="staging"\nPIPELINE_REPO="fake/repo"\n' > "$PROJ/pipeline.config"
printf 'staging\n' > "$PROJ/.claude/base-branch"

# Stub gh (shape copied from tests/test-enforce-ci-wait.sh +
# tests/test-enforce-path-c-delegation.sh).
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
if [ "${STUB_GH_FAIL:-0}" = "1" ]; then exit 1; fi
args="$*"
case "$args" in
  *"[.statusCheckRollup"*) printf '%s' "${STUB_GH_FAIL_COUNT:-0}" ;;
  *". | length"*)          printf '%s' "${STUB_GH_ROLLUP_LEN:-1}" ;;
  *"issue edit"*|*"pr comment"*) : ;;
  *)                       printf '%s\n' "${STUB_LABELS:-}" ;;
esac
EOF
chmod +x "$STUB_DIR/gh"

for h in block_deletions.py check-ci-skip-markers.py enforce-base-branch.py \
         enforce-comment-trust.py restrict_paths.py enforce-ci-wait.py \
         enforce-path-c-delegation.py; do
  if [ ! -f "$HOOKS_DIR/$h" ]; then
    echo "ERROR: hook not found at $HOOKS_DIR/$h" >&2
    exit 1
  fi
done

# --- helpers ---------------------------------------------------------------

# run_hook <hook-file> <payload-json> [KEY=VAL ...] -> echoes exit code
run_hook() {
  local hook="$1"; shift
  local payload="$1"; shift
  set +e
  printf '%s' "$payload" | env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    CLAUDE_PROJECT_DIR="$PROJ" \
    "$@" \
    python3 "$HOOKS_DIR/$hook" >"$WORK/out" 2>"$WORK/err"
  local rc=$?
  set -e
  echo "$rc"
}

log_lines() {
  if [ -f "$PROJ/$LOG_REL" ]; then
    grep -c . "$PROJ/$LOG_REL" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

reset_log() { rm -rf "${PROJ:?}/$LOG_REL"; }

# payload_for <hook-stem> <session-id>
payload_for() {
  local stem="$1" sid="$2"
  case "$stem" in
    block_deletions)
      printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"rm -rf /some/path"}}' "$sid" ;;
    check-ci-skip-markers)
      printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"git commit -m \\"fix [skip ci] handling\\""}}' "$sid" ;;
    enforce-base-branch)
      printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh pr create --title T --body B"}}' "$sid" ;;
    enforce-comment-trust)
      printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"gh issue view 1 --json comments"}}' "$sid" ;;
    restrict_paths)
      printf '{"tool_name":"Write","session_id":"%s","tool_input":{"file_path":"/etc/shadow"}}' "$sid" ;;
    enforce-ci-wait)
      printf '{"session_id":"%s","cwd":"%s"}' "$sid" "$PROJ" ;;
    enforce-path-c-delegation)
      printf '{"tool_name":"Edit","session_id":"%s","tool_input":{"file_path":"web/foo.ts"}}' "$sid" ;;
  esac
}

# tool_for <hook-stem> — the `tool` field the record must carry.
tool_for() {
  case "$1" in
    restrict_paths)            printf 'Write' ;;
    enforce-ci-wait)           printf 'Stop' ;;
    enforce-path-c-delegation) printf 'Edit' ;;
    *)                         printf 'Bash' ;;
  esac
}

# prepare_fixture <hook-stem> <session-id> — per-hook preconditions.
prepare_fixture() {
  case "$1" in
    enforce-ci-wait)
      rm -rf "$PROJ/.claude/logs/enforce-ci-wait-state"
      rm -f "$PROJ/.claude/logs/tool-use.log"
      printf '2026-05-14T10:00:00Z\tpost\tBash\tsession=%s\tgh pr view 123 --repo fake/repo --json statusCheckRollup\n' \
        "$2" >> "$PROJ/.claude/logs/tool-use.log" ;;
    enforce-path-c-delegation)
      rm -f "/tmp/claude-path-c-$2-999.cache" ;;
  esac
}

# drive_deny <hook-stem> <session-id> [KEY=VAL ...] -> echoes exit code
drive_deny() {
  local stem="$1"; shift
  local sid="$1"; shift
  prepare_fixture "$stem" "$sid"
  local extra=()
  case "$stem" in
    enforce-ci-wait)
      extra=(CLAUDE_PIPELINE_SKILL=evaluate-issue-pr STUB_GH_ROLLUP_LEN=1) ;;
    enforce-path-c-delegation)
      extra=(CLAUDE_PIPELINE_ISSUE_NUMBER=999 STUB_LABELS=multi-task) ;;
  esac
  run_hook "$stem.py" "$(payload_for "$stem" "$sid")" \
    CLAUDE_SESSION_ID="$sid" "${extra[@]+"${extra[@]}"}" "$@"
}

# assert_record <expected-hook> <expected-tool> <expected-session> <stderr-file>
# Validates the LAST record in the log. Echoes "OK" or a diagnostic.
assert_record() {
  python3 - "$PROJ/$LOG_REL" "$1" "$2" "$3" "$4" <<'PY'
import json
import sys

path, want_hook, want_tool, want_session, errfile = sys.argv[1:6]
try:
    with open(path) as fh:
        lines = [ln for ln in fh.read().splitlines() if ln.strip()]
except OSError as exc:
    print("log not readable: %s" % exc)
    sys.exit(0)
if not lines:
    print("log is empty")
    sys.exit(0)
try:
    rec = json.loads(lines[-1])
except ValueError as exc:
    print("last line is not JSON (%s): %r" % (exc, lines[-1][:120]))
    sys.exit(0)
if not isinstance(rec, dict):
    print("record is not a JSON object: %r" % (rec,))
    sys.exit(0)

want_keys = {"ts", "hook", "tool", "session", "reason", "command"}
missing = want_keys - set(rec)
extra = set(rec) - want_keys
if missing:
    print("record missing keys %s: %r" % (sorted(missing), rec))
    sys.exit(0)
if extra:
    print("record has unexpected keys %s: %r" % (sorted(extra), rec))
    sys.exit(0)

problems = []
if rec["hook"] != want_hook:
    problems.append("hook=%r want %r" % (rec["hook"], want_hook))
if rec["tool"] != want_tool:
    problems.append("tool=%r want %r" % (rec["tool"], want_tool))
if rec["session"] != want_session:
    problems.append("session=%r want %r" % (rec["session"], want_session))

with open(errfile) as fh:
    stderr = fh.read()
first = stderr.splitlines()[0] if stderr.splitlines() else ""
if rec["reason"] != first:
    problems.append("reason=%r want first stderr line %r" % (rec["reason"], first))
if "\n" in rec["reason"]:
    problems.append("reason spans multiple lines")

ts = rec["ts"]
if not isinstance(ts, str) or len(ts) != 20 or not ts.endswith("Z") or ts[10] != "T":
    problems.append("ts=%r is not YYYY-MM-DDTHH:MM:SSZ" % (ts,))
if not isinstance(rec["command"], str):
    problems.append("command is not a string: %r" % (rec["command"],))
elif len(rec["command"]) > 512:
    problems.append("command longer than 512 chars (%d)" % len(rec["command"]))

print("OK" if not problems else "; ".join(problems))
PY
}

# ---------------------------------------------------------------------------
# Case (a) — gate ON: exactly one well-formed record per denied hook.
# ---------------------------------------------------------------------------
echo "Case (a): gate ON -> one well-formed record per denied hook"
HOOK_STEMS=(block_deletions check-ci-skip-markers enforce-base-branch \
            enforce-comment-trust restrict_paths enforce-ci-wait \
            enforce-path-c-delegation)

declare -A STDERR_SNAPSHOT=()

for stem in "${HOOK_STEMS[@]}"; do
  inc
  reset_log
  sid="denylog-a-$stem"
  rc=$(drive_deny "$stem" "$sid" PIPELINE_LOGS_ENABLED=true)
  cp "$WORK/err" "$WORK/err-$stem"
  STDERR_SNAPSHOT["$stem"]="$WORK/err-$stem"
  lines=$(log_lines)
  if [ "$rc" != "2" ]; then
    fail_msg "(a) $stem: expected exit 2, got $rc (stderr: $(head -c 120 "$WORK/err"))"
    continue
  fi
  if [ "$lines" != "1" ]; then
    fail_msg "(a) $stem: expected exactly 1 record in $LOG_REL, found $lines"
    continue
  fi
  verdict=$(assert_record "$stem" "$(tool_for "$stem")" "$sid" "$WORK/err-$stem")
  if [ "$verdict" = "OK" ]; then
    pass_msg "(a) $stem: one well-formed denial record"
  else
    fail_msg "(a) $stem: $verdict"
  fi
done

# ---------------------------------------------------------------------------
# Case (b) — gate OFF: nothing is written, for either spelling of "off".
# ---------------------------------------------------------------------------
echo "Case (b): gate OFF -> no hook-denials.jsonl is created"
for gate_env in "UNSET" "PIPELINE_LOGS_ENABLED=false"; do
  for stem in "${HOOK_STEMS[@]}"; do
    inc
    reset_log
    sid="denylog-b-$stem"
    if [ "$gate_env" = "UNSET" ]; then
      rc=$(drive_deny "$stem" "$sid")
    else
      rc=$(drive_deny "$stem" "$sid" "$gate_env")
    fi
    if [ "$rc" = "2" ] && [ ! -e "$PROJ/$LOG_REL" ]; then
      pass_msg "(b)/(c) $stem [$gate_env]: exit 2, no log file created"
    else
      fail_msg "(b)/(c) $stem [$gate_env]: rc=$rc, log exists=$([ -e "$PROJ/$LOG_REL" ] && echo yes || echo no)"
    fi
  done
done

# ---------------------------------------------------------------------------
# Case (c) — CONTROL: stderr is byte-identical between gate ON and gate OFF,
# and the exit code is 2 in both (the gate-ON exit codes were asserted in (a),
# the gate-OFF exit codes in (b)).
# ---------------------------------------------------------------------------
echo "Case (c): denial stderr unchanged between gate states (CONTROL)"
for stem in "${HOOK_STEMS[@]}"; do
  inc
  reset_log
  sid="denylog-a-$stem"   # same session id as case (a) so stderr is comparable
  rc=$(drive_deny "$stem" "$sid")
  if [ "$rc" = "2" ] && diff -q "$WORK/err" "${STDERR_SNAPSHOT[$stem]}" >/dev/null 2>&1; then
    pass_msg "(c) $stem: exit 2 + identical stderr with the gate off"
  else
    fail_msg "(c) $stem: rc=$rc, stderr differs from the gate-ON run"
  fi
done

# ---------------------------------------------------------------------------
# Case (d) — the command field is masked and truncated.
# ---------------------------------------------------------------------------
echo "Case (d): command masked (command_mask.py) and truncated to 512 chars"

inc
reset_log
SECRET='s3cr3t-value-1352'
SECRET_CMD="gh pr create --title T --body B --token \"$SECRET\""
SECRET_PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":"denylog-d","tool_input":{"command":sys.argv[1]}}))' "$SECRET_CMD")
rc=$(run_hook enforce-base-branch.py "$SECRET_PAYLOAD" \
      CLAUDE_SESSION_ID=denylog-d PIPELINE_LOGS_ENABLED=true)
if [ "$rc" != "2" ]; then
  fail_msg "(d) masking: expected exit 2 from enforce-base-branch, got $rc"
elif [ ! -f "$PROJ/$LOG_REL" ]; then
  fail_msg "(d) masking: no $LOG_REL written"
else
  verdict=$(python3 - "$PROJ/$LOG_REL" "$SECRET" <<'PY'
import json
import sys

path, secret = sys.argv[1:3]
with open(path) as fh:
    lines = [ln for ln in fh.read().splitlines() if ln.strip()]
rec = json.loads(lines[-1])
cmd = rec.get("command", "")
problems = []
if secret in cmd:
    problems.append("secret leaked into command=%r" % (cmd,))
if secret in lines[-1]:
    problems.append("secret leaked elsewhere in the record: %r" % (lines[-1],))
if "gh pr create" not in cmd:
    problems.append("command text lost, expected the masked gh pr create form: %r" % (cmd,))
print("OK" if not problems else "; ".join(problems))
PY
)
  if [ "$verdict" = "OK" ]; then
    pass_msg "(d) quoted secret masked out of the command field"
  else
    fail_msg "(d) $verdict"
  fi
fi

inc
reset_log
LONG_CMD="rm -rf /some/$(python3 -c 'print("a"*900)')"
LONG_PAYLOAD=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":"denylog-d2","tool_input":{"command":sys.argv[1]}}))' "$LONG_CMD")
rc=$(run_hook block_deletions.py "$LONG_PAYLOAD" \
      CLAUDE_SESSION_ID=denylog-d2 PIPELINE_LOGS_ENABLED=true)
if [ "$rc" != "2" ]; then
  fail_msg "(d) truncation: expected exit 2 from block_deletions, got $rc"
elif [ ! -f "$PROJ/$LOG_REL" ]; then
  fail_msg "(d) truncation: no $LOG_REL written"
else
  verdict=$(python3 - "$PROJ/$LOG_REL" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    lines = [ln for ln in fh.read().splitlines() if ln.strip()]
rec = json.loads(lines[-1])
cmd = rec.get("command", "")
if len(cmd) > 512:
    print("command not truncated: %d chars" % len(cmd))
elif not cmd.startswith("rm -rf /some/"):
    print("truncation dropped the command head: %r" % (cmd[:60],))
else:
    print("OK")
PY
)
  if [ "$verdict" = "OK" ]; then
    pass_msg "(d) long command truncated to 512 chars, head preserved"
  else
    fail_msg "(d) $verdict"
  fi
fi

# ---------------------------------------------------------------------------
# Case (e) — fail-open: an unwritable log path never changes the decision.
# The jsonl path is created as a DIRECTORY so every open() for append raises.
# ---------------------------------------------------------------------------
echo "Case (e): unwritable log path -> still exit 2 with unchanged stderr"
for stem in block_deletions restrict_paths enforce-comment-trust; do
  inc
  reset_log
  mkdir -p "$PROJ/$LOG_REL"
  sid="denylog-a-$stem"   # reuse case (a) session id so stderr is comparable
  rc=$(drive_deny "$stem" "$sid" PIPELINE_LOGS_ENABLED=true)
  if [ "$rc" = "2" ] && diff -q "$WORK/err" "${STDERR_SNAPSHOT[$stem]}" >/dev/null 2>&1; then
    pass_msg "(e) $stem: fail-open — exit 2, stderr byte-identical"
  else
    fail_msg "(e) $stem: rc=$rc, stderr=$(head -c 160 "$WORK/err")"
  fi
  rm -rf "${PROJ:?}/$LOG_REL"
done

# ---------------------------------------------------------------------------
# Case (f) — allow-path purity: an ALLOWED call under gate ON logs nothing.
# Without this, an unguarded log_denial on a shared allow/deny return would
# silently pollute the audit trail with false denials.
# ---------------------------------------------------------------------------
echo "Case (f): allowed calls under gate ON write zero records"

inc
reset_log
rc=$(run_hook block_deletions.py \
      '{"tool_name":"Bash","session_id":"denylog-f1","tool_input":{"command":"ls -la"}}' \
      CLAUDE_SESSION_ID=denylog-f1 PIPELINE_LOGS_ENABLED=true)
if [ "$rc" = "0" ] && [ "$(log_lines)" = "0" ]; then
  pass_msg "(f) block_deletions allow (ls -la): exit 0, zero records"
else
  fail_msg "(f) block_deletions allow: rc=$rc, records=$(log_lines)"
fi

inc
reset_log
rc=$(run_hook enforce-base-branch.py \
      '{"tool_name":"Bash","session_id":"denylog-f2","tool_input":{"command":"gh pr create --base staging --title T --body B"}}' \
      CLAUDE_SESSION_ID=denylog-f2 PIPELINE_LOGS_ENABLED=true)
if [ "$rc" = "0" ] && [ "$(log_lines)" = "0" ]; then
  pass_msg "(f) enforce-base-branch allow (--base staging): exit 0, zero records"
else
  fail_msg "(f) enforce-base-branch allow: rc=$rc, records=$(log_lines)"
fi

inc
reset_log
rc=$(run_hook enforce-comment-trust.py \
      '{"tool_name":"Bash","session_id":"denylog-f3","tool_input":{"command":"git log --oneline -5"}}' \
      CLAUDE_SESSION_ID=denylog-f3 PIPELINE_LOGS_ENABLED=true)
if [ "$rc" = "0" ] && [ "$(log_lines)" = "0" ]; then
  pass_msg "(f) enforce-comment-trust allow (git log): exit 0, zero records"
else
  fail_msg "(f) enforce-comment-trust allow: rc=$rc, records=$(log_lines)"
fi

# ---------------------------------------------------------------------------
# Case (g) — worktree-aware resolution (#1380): CLAUDE_PROJECT_DIR set to a
# LINKED worktree resolves the log to the MAIN checkout, not the worktree.
# Cases (a)-(f) above already cover the git-absent fallback ($PROJ has no
# .git, so today's Path(project_dir) behavior stays exercised).
# ---------------------------------------------------------------------------
echo "Case (g): CLAUDE_PROJECT_DIR=<linked worktree> -> log lands in MAIN checkout"
inc
GWORK=$(mktemp -d)
git -c init.defaultBranch=main init -q "$GWORK/main"
git -C "$GWORK/main" config user.email t@t.t
git -C "$GWORK/main" config user.name t
git -C "$GWORK/main" config commit.gpgsign false
git -C "$GWORK/main" commit -q --allow-empty -m init
git -C "$GWORK/main" worktree add -q -b denylog-g-branch "$GWORK/wt" >/dev/null
set +e
printf '%s' '{"tool_name":"Bash","session_id":"denylog-g","tool_input":{"command":"rm -rf /some/path"}}' \
  | env -i HOME="$HOME" PATH="$STUB_DIR:/usr/bin:/bin" CLAUDE_PROJECT_DIR="$GWORK/wt" \
    PIPELINE_LOGS_ENABLED=true python3 "$HOOKS_DIR/block_deletions.py" >/dev/null 2>"$GWORK/err"
rc=$?
set -e
main_lines="$(grep -c . "$GWORK/main/$LOG_REL" 2>/dev/null || echo 0)"
if [ "$rc" = "2" ] && [ "$main_lines" = "1" ] && [ ! -e "$GWORK/wt/$LOG_REL" ]; then
  pass_msg "(g) worktree denial logs to MAIN checkout, no worktree-local file"
else
  fail_msg "(g) rc=$rc main-lines=$main_lines wt-file=$([ -e "$GWORK/wt/$LOG_REL" ] && echo yes || echo no)"
fi
rm -rf "$GWORK"
GWORK=""

echo ""
echo "================================"
echo "  $TESTS cases: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
