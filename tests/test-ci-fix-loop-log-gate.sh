#!/usr/bin/env bash
# Tests that scripts/check-ci-fix-loop.sh gates the attempt-log on
# PIPELINE_LOGS_ENABLED. When disabled, the log routes to mktemp and
# no .claude/logs/ci-fix-* file is created. When enabled, the
# .claude/logs/ci-fix-*-attempt-*.log file IS created. In both cases
# the ACTION= line is still emitted on stdout.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-ci-fix-loop.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
inc()      { TESTS=$((TESTS+1)); }

make_shim() {
  local dir="$1"
  cat > "$dir/gh" <<'SHIM'
#!/usr/bin/env bash
STATE="${GH_FAKE_STATE:-/tmp/gh-state}"
declare -A S
if [ -f "$STATE" ]; then
  while IFS='=' read -r k v; do S[$k]="$v"; done < "$STATE"
fi
cmd="${1:-}"; sub="${2:-}"
case "$cmd $sub" in
  "issue view")
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == *"closedByPullRequestsReferences"* ]]; then
      echo "${S[pr]:-}"; exit 0
    fi
    if [[ "$json_flag" == *"comments"* ]]; then
      echo "${S[retries]:-0}"; exit 0
    fi
    exit 0 ;;
  "pr list") echo ""; exit 0 ;;
  "pr checks")
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == "conclusion" ]]; then
      echo "${S[conclusion]:-pending}"; exit 0
    fi
    if [[ "$json_flag" == "link" ]]; then
      echo "https://example.test/runs/${S[run_id]:-0}"; exit 0
    fi
    exit 0 ;;
  "run view") echo "${S[fail_log]:-stub failure log}"; exit 0 ;;
  "issue comment") exit 0 ;;
  "issue edit") exit 0 ;;
esac
exit 0
SHIM
  chmod +x "$dir/gh"
}

run_case() {
  local enabled="$1"
  local workdir
  workdir=$(mktemp -d)
  local stub="$workdir/stub"
  mkdir -p "$stub"
  make_shim "$stub"
  cat > "$stub/gh-state" <<EOF
conclusion=failure
pr=42
run_id=999
retries=0
fail_log=boom
EOF
  set +e
  OUT=$( cd "$workdir" && PATH="$stub:$PATH" \
    GH_FAKE_STATE="$stub/gh-state" \
    PIPELINE_REPO="fake/repo" \
    PIPELINE_CI_FIX_RETRY_BUDGET="2" \
    PIPELINE_CI_FIX_LOG_LINES="200" \
    PIPELINE_LOGS_ENABLED="$enabled" \
    bash "$HELPER" 42 2>&1 )
  set -e
  echo "$OUT" > "$workdir/out"
  echo "$workdir"
}

# ---- Case 1: PIPELINE_LOGS_ENABLED=false -------------------------------
echo "Case 1: PIPELINE_LOGS_ENABLED=false -> no .claude/logs file, ACTION= still emitted"
inc
w1=$(run_case "false")
out1=$(cat "$w1/out")

if echo "$out1" | grep -q "^ACTION=red-retry "; then
  pass_msg "1a ACTION=red-retry on stdout"
else
  fail_msg "1a missing ACTION=red-retry: $out1"
fi

inc
if [ ! -d "$w1/.claude/logs" ] || ! ls "$w1/.claude/logs"/ci-fix-42-attempt-*.log >/dev/null 2>&1; then
  pass_msg "1b no .claude/logs/ci-fix-* file created"
else
  fail_msg "1b unexpected log file under .claude/logs: $(ls "$w1/.claude/logs")"
fi

inc
LOG_PATH1=$(echo "$out1" | grep -oE 'LOG=[^ ]+' | cut -d= -f2 || true)
if [ -n "$LOG_PATH1" ] && [ -f "$LOG_PATH1" ] && [[ "$LOG_PATH1" != "$w1/.claude/logs/"* ]]; then
  pass_msg "1c LOG= points outside .claude/logs ($LOG_PATH1)"
else
  fail_msg "1c LOG path unexpected: LOG=$LOG_PATH1"
fi

# ---- Case 2: PIPELINE_LOGS_ENABLED=true --------------------------------
echo "Case 2: PIPELINE_LOGS_ENABLED=true -> .claude/logs file IS created"
inc
w2=$(run_case "true")
out2=$(cat "$w2/out")

if echo "$out2" | grep -q "^ACTION=red-retry "; then
  pass_msg "2a ACTION=red-retry on stdout"
else
  fail_msg "2a missing ACTION=red-retry: $out2"
fi

inc
if ls "$w2/.claude/logs"/ci-fix-42-attempt-*.log >/dev/null 2>&1; then
  pass_msg "2b .claude/logs/ci-fix-* file created"
else
  fail_msg "2b expected log under .claude/logs not found"
fi

echo
echo "Tests: $TESTS  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
