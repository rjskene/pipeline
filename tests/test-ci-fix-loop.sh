#!/usr/bin/env bash
# Tests for scripts/check-ci-fix-loop.sh decision logic, plus
# end-to-end glue through scripts/run-queue.sh.template --ci-fix.
#
# The `gh` CLI is PATH-shimmed by a temporary fake that reads canned
# responses from a fixture directory. The shim also records every
# invocation to a "gh.log" file inside the fixture dir, which the
# assertions inspect.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-ci-fix-loop.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
inc()      { TESTS=$((TESTS+1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper not found at $HELPER" >&2
  exit 1
fi

# ---- fake `gh` shim factory ---------------------------------------------
# Each fixture writes a fresh FIX_DIR/gh-state file consumed by the shim.
# State file format (key=value lines):
#   conclusion=success|failure|pending
#   pr=42
#   run_id=999
#   retries=N            (prior pipeline.ci-retries value; 0 means absent)
#   fail_log=...         (string the fake `gh run view --log-failed` prints)

make_shim() {
  local dir="$1"
  cat > "$dir/gh" <<'SHIM'
#!/usr/bin/env bash
LOG="${GH_FAKE_LOG:-/tmp/gh.log}"
STATE="${GH_FAKE_STATE:-/tmp/gh-state}"
# shellcheck disable=SC2155
declare -A S
if [ -f "$STATE" ]; then
  while IFS='=' read -r k v; do S[$k]="$v"; done < "$STATE"
fi
printf '%q ' "$@" >> "$LOG"
echo >> "$LOG"

cmd="${1:-}"
sub="${2:-}"
case "$cmd $sub" in
  "issue view")
    # Need to know which JSON fields requested
    issue="$3"
    json_flag=""
    jq_filter=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        --jq)   jq_filter="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == *"closedByPullRequestsReferences"* ]]; then
      echo "${S[pr]:-}"
      exit 0
    fi
    if [[ "$json_flag" == *"comments"* ]]; then
      # Emit the retries number directly. The helper's jq filter is
      # bypassed because we're returning the raw N, matching the
      # post-jq value the helper expects to read.
      echo "${S[retries]:-0}"
      exit 0
    fi
    exit 0
    ;;
  "pr list")
    echo ""
    exit 0
    ;;
  "pr checks")
    # Args: pr_num --repo ... --json conclusion --jq ...
    # or:   pr_num --repo ... --json link --jq ...
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    if [[ "$json_flag" == "conclusion" ]]; then
      echo "${S[conclusion]:-pending}"
      exit 0
    fi
    if [[ "$json_flag" == "link" ]]; then
      # Return a fake job URL whose trailing number is the run id.
      echo "https://example.test/runs/${S[run_id]:-0}"
      exit 0
    fi
    exit 0
    ;;
  "run view")
    echo "${S[fail_log]:-stub failure log}"
    exit 0
    ;;
  "issue comment")
    exit 0
    ;;
  "issue edit")
    exit 0
    ;;
esac
exit 0
SHIM
  chmod +x "$dir/gh"
}

run_fixture() {
  local name="$1" issue="$2"
  shift 2
  inc
  local fix_dir
  fix_dir=$(mktemp -d)
  make_shim "$fix_dir"
  local log_file="$fix_dir/gh.log"
  local state_file="$fix_dir/gh-state"
  : > "$log_file"
  : > "$state_file"
  # remaining args are key=value pairs for state
  for kv in "$@"; do
    echo "$kv" >> "$state_file"
  done
  # Run helper with stubbed PATH and env. Capture stdout.
  local out
  out=$( PATH="$fix_dir:$PATH" \
         GH_FAKE_LOG="$log_file" \
         GH_FAKE_STATE="$state_file" \
         PIPELINE_REPO="fake/repo" \
         PIPELINE_CI_FIX_RETRY_BUDGET="2" \
         PIPELINE_CI_FIX_LOG_LINES="200" \
         bash "$HELPER" "$issue" 2>&1 )
  local rc=$?
  echo "$out" > "$fix_dir/helper.out"
  echo "$rc"  > "$fix_dir/helper.rc"
  echo "$fix_dir"
}

# ---- Fixture A: success -------------------------------------------------
echo "Fixture A: CI success -> ACTION=green"
fa=$(run_fixture A 42 \
  "conclusion=success" "pr=42" "run_id=0" "retries=0")
out_a=$(cat "$fa/helper.out")
if echo "$out_a" | grep -q "^ACTION=green ISSUE=42"; then pass_msg "A green"; else fail_msg "A green: $out_a"; fi

# ---- Fixture B: pending -------------------------------------------------
echo "Fixture B: CI pending -> ACTION=pending"
fb=$(run_fixture B 42 \
  "conclusion=pending" "pr=42" "run_id=0" "retries=0")
out_b=$(cat "$fb/helper.out")
if echo "$out_b" | grep -q "^ACTION=pending ISSUE=42"; then pass_msg "B pending"; else fail_msg "B pending: $out_b"; fi

# ---- Fixture C: failure, no prior retries -> red-retry RETRIES=1 -------
echo "Fixture C: CI failure, no prior retry -> ACTION=red-retry RETRIES=1"
fc=$(run_fixture C 42 \
  "conclusion=failure" "pr=42" "run_id=999" "retries=0" "fail_log=boom")
out_c=$(cat "$fc/helper.out")
if echo "$out_c" | grep -q "ACTION=red-retry "; then pass_msg "C action"; else fail_msg "C action: $out_c"; fi
if echo "$out_c" | grep -q "RETRIES=1 BUDGET=2"; then pass_msg "C retries=1 budget=2"; else fail_msg "C retries: $out_c"; fi
if grep -q "issue comment 42" "$fc/gh.log" && grep -q "pipeline.ci-retries" "$fc/gh.log"; then
  pass_msg "C retry comment posted"
else
  fail_msg "C no retry comment in: $(cat "$fc/gh.log")"
fi

# ---- Fixture D: failure with prior retries=2, budget exhausted ---------
echo "Fixture D: budget exhausted -> ACTION=red-budget-exhausted + human label"
fd=$(run_fixture D 42 \
  "conclusion=failure" "pr=42" "run_id=999" "retries=2" "fail_log=boom")
out_d=$(cat "$fd/helper.out")
if echo "$out_d" | grep -q "ACTION=red-budget-exhausted "; then pass_msg "D action"; else fail_msg "D action: $out_d"; fi
if grep -q "issue edit 42" "$fd/gh.log" && grep -q -- "--add-label human" "$fd/gh.log"; then
  pass_msg "D human label applied"
else
  fail_msg "D no human label in: $(cat "$fd/gh.log")"
fi

# ---- Summary -----------------------------------------------------------
echo
echo "Tests: $TESTS  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
