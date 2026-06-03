#!/usr/bin/env bash
# Tests for scripts/check-ci-fix-loop.sh decision logic, plus
# end-to-end glue through scripts/run-queue.sh --ci-fix.
#
# The `gh` CLI is PATH-shimmed by a temporary fake that reads canned
# responses from a fixture directory. The shim also records every
# invocation to a "gh.log" file inside the fixture dir, which the
# assertions inspect.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_lib/env-hygiene.sh
. "$SCRIPT_DIR/_lib/env-hygiene.sh"
pipeline_test_reset_env

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/check-ci-fix-loop.sh"

PASS=0; FAIL=0; TESTS=0
PIPELINE_TEST_TMPDIRS=()
cleanup_tmpdirs() {
  local d
  for d in "${PIPELINE_TEST_TMPDIRS[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_tmpdirs EXIT
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
    # State-driven, argument-aware. Parses --head <branch> and
    # --search <query> out of $@.
    #   head_<ref>=<prnum>  -> exact-branch linkage. For --head <ref>:
    #                          echo [{"number":<p>}] on match, [] otherwise.
    #   latest_open_pr=<p>  -> the PR a buggy "latest open PR" resolver picks.
    #                          Returned for a bare/unfiltered search (NO
    #                          "<N> in:body" filter). The trap: the fixed
    #                          helper must never return this for an issue.
    #   body_pr_<N>=<p>     -> for --search "<N> in:body": echo
    #                          [{"number":<p>,"body":"...#<N>..."}], else [].
    head_ref=""
    search_q=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --head)   head_ref="$2"; shift 2 ;;
        --search) search_q="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # The shim does NOT run jq -- like the `closedByPullRequestsReferences`
    # branch above, it returns the ALREADY-jq-collapsed value (the bare PR
    # number, or empty for no match) that the helper's `--jq` would yield.
    if [ -n "$head_ref" ]; then
      echo "${S[head_${head_ref}]:-}"
      exit 0
    fi
    if [ -n "$search_q" ]; then
      # Extract the leading issue number from a "<N> in:body" query.
      if [[ "$search_q" =~ ^([0-9]+)[[:space:]]+in:body ]]; then
        n="${BASH_REMATCH[1]}"
        echo "${S[body_pr_$n]:-}"
        exit 0
      fi
      # Bare/unfiltered search (the legacy fuzzy `linked:` path). Return the
      # trap value the OLD helper's `.[0]` resolution would latch onto.
      echo "${S[latest_open_pr]:-}"
      exit 0
    fi
    echo ""
    exit 0
    ;;
  "pr checks")
    # Args: pr_num --repo ... --json <field> --jq ...
    #
    # This shim mirrors real `gh pr checks --json` FIELD VALIDATION: the
    # only fields it knows are the ones real `gh` exposes. Requesting an
    # unknown field (e.g. the bogus `conclusion`, which only exists on
    # `gh pr view --json statusCheckRollup`) errors to stderr and exits
    # non-zero — exactly as real `gh` does. This is the guard the old
    # shim lacked: it answered `conclusion` unconditionally, masking that
    # the helper queried a field that always errors against real `gh`
    # (issue #876).
    json_flag=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --json) json_flag="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    # Real `gh pr checks --json` fields. `state` carries the uppercase
    # per-check status; `bucket` the lowercase category. `conclusion` is
    # deliberately NOT here.
    VALID_FIELDS="bucket completedAt description event link name startedAt state workflow"
    case " $VALID_FIELDS " in
      *" $json_flag "*) : ;;
      *)
        echo "Unknown JSON field: \"$json_flag\"" >&2
        echo "Available fields:" >&2
        echo "  $VALID_FIELDS" >&2
        exit 1
        ;;
    esac
    if [[ "$json_flag" == "state" ]]; then
      # The helper feeds `state` through a `--jq` filter that collapses the
      # per-check uppercase `state` values to a canonical success/pending/
      # failure verdict. The shim does not run jq, so it returns that
      # already-collapsed verdict directly (matching the post-jq value the
      # helper reads) — same contract the old `conclusion` branch used.
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
  # cd into $fix_dir so any .claude/logs/ side-effects land in tmpdir
  # rather than REPO_ROOT (see #362). PIPELINE_LOGS_ENABLED="" is
  # belt-and-braces against any future mid-fixture re-export.
  PIPELINE_TEST_TMPDIRS+=("$fix_dir")
  local out
  out=$( cd "$fix_dir" && PATH="$fix_dir:$PATH" \
         GH_FAKE_LOG="$log_file" \
         GH_FAKE_STATE="$state_file" \
         PIPELINE_REPO="fake/repo" \
         PIPELINE_CI_FIX_RETRY_BUDGET="2" \
         PIPELINE_CI_FIX_LOG_LINES="200" \
         PIPELINE_LOGS_ENABLED="" \
         bash "$HELPER" "$issue" 2>&1 )
  local rc=$?
  echo "$out" > "$fix_dir/helper.out"
  echo "$rc"  > "$fix_dir/helper.rc"
  echo "$fix_dir"
}

# Unique per-fixture issue numbers prevent cross-fixture collisions in
# any shared .claude/logs/ci-fix-<issue>-attempt-*.log namespace (#362).

# ---- Fixture A: success -------------------------------------------------
echo "Fixture A: CI success -> ACTION=green"
fa=$(run_fixture A 4201 \
  "conclusion=success" "pr=42" "run_id=0" "retries=0")
out_a=$(cat "$fa/helper.out")
if echo "$out_a" | grep -q "^ACTION=green ISSUE=4201"; then pass_msg "A green"; else fail_msg "A green: $out_a"; fi

# ---- Fixture B: pending -------------------------------------------------
echo "Fixture B: CI pending -> ACTION=pending"
fb=$(run_fixture B 4202 \
  "conclusion=pending" "pr=42" "run_id=0" "retries=0")
out_b=$(cat "$fb/helper.out")
if echo "$out_b" | grep -q "^ACTION=pending ISSUE=4202"; then pass_msg "B pending"; else fail_msg "B pending: $out_b"; fi

# ---- Fixture C: failure, no prior retries -> red-retry RETRIES=1 -------
echo "Fixture C: CI failure, no prior retry -> ACTION=red-retry RETRIES=1"
fc=$(run_fixture C 4203 \
  "conclusion=failure" "pr=42" "run_id=999" "retries=0" "fail_log=boom")
out_c=$(cat "$fc/helper.out")
if echo "$out_c" | grep -q "ACTION=red-retry "; then pass_msg "C action"; else fail_msg "C action: $out_c"; fi
if echo "$out_c" | grep -q "RETRIES=1 BUDGET=2"; then pass_msg "C retries=1 budget=2"; else fail_msg "C retries: $out_c"; fi
if grep -q "issue comment 4203" "$fc/gh.log" && grep -q "pipeline.ci-retries" "$fc/gh.log"; then
  pass_msg "C retry comment posted"
else
  fail_msg "C no retry comment in: $(cat "$fc/gh.log")"
fi

# ---- Fixture D: failure with prior retries=2, budget exhausted ---------
echo "Fixture D: budget exhausted -> ACTION=red-budget-exhausted + human label"
fd=$(run_fixture D 4204 \
  "conclusion=failure" "pr=42" "run_id=999" "retries=2" "fail_log=boom")
out_d=$(cat "$fd/helper.out")
if echo "$out_d" | grep -q "ACTION=red-budget-exhausted "; then pass_msg "D action"; else fail_msg "D action: $out_d"; fi
if grep -q "issue edit 4204" "$fd/gh.log" && grep -q -- "--add-label human" "$fd/gh.log"; then
  pass_msg "D human label applied"
else
  fail_msg "D no human label in: $(cat "$fd/gh.log")"
fi

# ---- Fixture E: run-queue.sh --ci-fix dispatch -------------------------
echo "Fixture E: run-queue.sh --ci-fix dispatches spawn-claude with PIPELINE_CI_FIX_CONTEXT"
inc
fe=$(mktemp -d)
PIPELINE_TEST_TMPDIRS+=("$fe")
WT_FAKE="$fe/.claude/worktrees/wt-42-fake"
mkdir -p "$WT_FAKE" "$fe/.claude/scripts"
cat > "$fe/.claude/scripts/spawn-claude.sh" <<'REC'
#!/usr/bin/env bash
echo "ARGS=$*" >> "$RECORDER_LOG"
echo "PIPELINE_CI_FIX_CONTEXT=${PIPELINE_CI_FIX_CONTEXT:-}" >> "$RECORDER_LOG"
REC
chmod +x "$fe/.claude/scripts/spawn-claude.sh"

cat > "$fe/pipeline.config" <<'CFG'
PIPELINE_REPO="fake/repo"
PIPELINE_WORKTREE_PREFIX="wt"
CFG

cp "$REPO_ROOT/scripts/run-queue.sh" "$fe/.claude/scripts/run-queue.sh"

# Fake `git worktree list` to advertise the fake worktree directory.
cat > "$fe/git" <<GIT
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
  echo "worktree $WT_FAKE"
  echo "HEAD deadbeef"
  echo "branch refs/heads/feature/42-fake"
  exit 0
fi
exec /usr/bin/git "\$@"
GIT
chmod +x "$fe/git"

RECORDER_LOG="$fe/recorder.log"
: > "$RECORDER_LOG"

# run-queue.sh now resolves its sibling spawn-claude.sh via
# ${CLAUDE_PLUGIN_ROOT}/scripts/. The fixture's recorder script lives at
# $fe/.claude/scripts/spawn-claude.sh, so point CLAUDE_PLUGIN_ROOT at
# $fe/.claude so the guard passes and dispatch resolves there.
set +e
( cd "$fe" && PATH="$fe:$PATH" RECORDER_LOG="$RECORDER_LOG" \
  CLAUDE_PLUGIN_ROOT="$fe/.claude" \
  bash .claude/scripts/run-queue.sh --ci-fix 42 /tmp/some.log >"$fe/dispatch.out" 2>&1 )
disp_rc=$?
set -e

if [ "$disp_rc" -ne 0 ]; then
  fail_msg "E dispatch exit=$disp_rc: $(cat "$fe/dispatch.out")"
elif grep -q "PIPELINE_CI_FIX_CONTEXT=/tmp/some.log" "$RECORDER_LOG" && \
     grep -q "$WT_FAKE" "$RECORDER_LOG"; then
  pass_msg "E dispatch fires spawn-claude with context env + worktree path"
else
  fail_msg "E recorder missing expected entries:
$(cat "$RECORDER_LOG")
dispatch out: $(cat "$fe/dispatch.out")"
fi

# ---- Fixture F: spawn-claude CI-FIX MODE prompt injection --------------
echo "Fixture F: spawn-claude.sh dry-run payload contains CI-FIX MODE when PIPELINE_CI_FIX_CONTEXT is set"
inc
ff=$(mktemp -d)
PIPELINE_TEST_TMPDIRS+=("$ff")
PROJ_F="$ff/proj"
mkdir -p "$PROJ_F/.claude/scripts" "$PROJ_F/worktree"
cp "$REPO_ROOT/scripts/spawn-claude.sh" "$PROJ_F/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ_F/.claude/scripts/spawn-claude.sh"

cat > "$PROJ_F/pipeline.config" <<'CFG'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_WIN_TEMP=""
CFG

# Stub gh that returns empty labels (-> PATH B default), succeeds.
mkdir -p "$ff/stub"
cat > "$ff/stub/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ff/stub/gh"

set +e
OUT=$( cd "$PROJ_F" && PATH="$ff/stub:$PATH" \
  PIPELINE_SPAWN_DRY_RUN=1 \
  PIPELINE_CI_FIX_CONTEXT=/tmp/fake.log \
  bash .claude/scripts/spawn-claude.sh "$PROJ_F/worktree" 4206 slug tmux 2>/dev/null )
set -e

PAYLOAD_F=$(echo "$OUT" | sed -n '/^=== PAYLOAD ===/,/^=== END PAYLOAD ===/p' | sed '1d;$d')

if echo "$PAYLOAD_F" | grep -q "CI-FIX MODE"; then
  pass_msg "F payload contains 'CI-FIX MODE'"
else
  fail_msg "F missing CI-FIX MODE; payload was:
$PAYLOAD_F"
fi
inc
if echo "$PAYLOAD_F" | grep -q "/tmp/fake.log"; then
  pass_msg "F payload references /tmp/fake.log"
else
  fail_msg "F missing /tmp/fake.log; payload was:
$PAYLOAD_F"
fi

# ---- Fixture G: end-to-end smoke (helper -> run-queue --ci-fix) --------
echo "Fixture G: helper red-retry -> run-queue --ci-fix dispatch with parsed LOG path"
inc
fg=$(mktemp -d)
PIPELINE_TEST_TMPDIRS+=("$fg")
mkdir -p "$fg/.claude/scripts" "$fg/.claude/worktrees/wt-4207-fake" "$fg/stub"
make_shim "$fg/stub"
echo "conclusion=failure" >  "$fg/stub/gh-state"
echo "pr=42"             >> "$fg/stub/gh-state"
echo "run_id=999"        >> "$fg/stub/gh-state"
echo "retries=0"         >> "$fg/stub/gh-state"
echo "fail_log=boom"     >> "$fg/stub/gh-state"

cp "$REPO_ROOT/scripts/check-ci-fix-loop.sh" "$fg/.claude/scripts/"
cp "$REPO_ROOT/scripts/run-queue.sh" "$fg/.claude/scripts/"
cat > "$fg/.claude/scripts/spawn-claude.sh" <<'REC'
#!/usr/bin/env bash
echo "ARGS=$*" >> "$RECORDER_LOG"
echo "PIPELINE_CI_FIX_CONTEXT=${PIPELINE_CI_FIX_CONTEXT:-}" >> "$RECORDER_LOG"
REC
chmod +x "$fg/.claude/scripts/spawn-claude.sh"

cat > "$fg/pipeline.config" <<'CFG'
PIPELINE_REPO="fake/repo"
PIPELINE_WORKTREE_PREFIX="wt"
CFG

# Fake `git worktree list` to advertise the fake worktree directory.
cat > "$fg/stub/git" <<GIT
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
  echo "worktree $fg/.claude/worktrees/wt-4207-fake"
  echo "HEAD deadbeef"
  echo "branch refs/heads/feature/4207-fake"
  exit 0
fi
exec /usr/bin/git "\$@"
GIT
chmod +x "$fg/stub/git"

# Step 1: run the helper, capture LOG= path.
set +e
HELPER_OUT=$( cd "$fg" && PATH="$fg/stub:$PATH" \
  GH_FAKE_LOG="$fg/gh.log" GH_FAKE_STATE="$fg/stub/gh-state" \
  PIPELINE_REPO="fake/repo" \
  PIPELINE_CI_FIX_RETRY_BUDGET="2" \
  PIPELINE_CI_FIX_LOG_LINES="200" \
  bash .claude/scripts/check-ci-fix-loop.sh 4207 2>&1 )
helper_rc=$?
set -e

if [ "$helper_rc" -ne 0 ]; then
  fail_msg "G helper failed: $HELPER_OUT"
else
  LOG_PATH=$(echo "$HELPER_OUT" | grep -oE 'LOG=[^ ]+' | cut -d= -f2)
  if [ -z "$LOG_PATH" ] || [ ! -f "$LOG_PATH" ]; then
    fail_msg "G no LOG= in helper output: $HELPER_OUT"
  else
    # Step 2: dispatch
    RECORDER_LOG="$fg/recorder.log"; : > "$RECORDER_LOG"
    set +e
    ( cd "$fg" && PATH="$fg/stub:$PATH" RECORDER_LOG="$RECORDER_LOG" \
      CLAUDE_PLUGIN_ROOT="$fg/.claude" \
      bash .claude/scripts/run-queue.sh --ci-fix 4207 "$LOG_PATH" >"$fg/dispatch.out" 2>&1 )
    drc=$?
    set -e
    if [ "$drc" -eq 0 ] && grep -q "PIPELINE_CI_FIX_CONTEXT=$LOG_PATH" "$RECORDER_LOG"; then
      pass_msg "G chain: helper LOG -> dispatch env"
    else
      fail_msg "G chain failed (rc=$drc):
RECORDER: $(cat "$RECORDER_LOG")
DISPATCH: $(cat "$fg/dispatch.out")"
    fi
  fi
fi

# ---- Fixture H: concurrent open PRs resolve per-issue ------------------
# Reproduces #909: in a concurrent leg/wave with >=2 open feature PRs and
# NO auto-linked closing PR ("Closes #N"), the helper must resolve each
# issue to its OWN PR via that issue's worktree branch ref -- never the
# latest open PR. Shared gh-state advertises:
#   - wt-838-campaign-fold-wave -> feature/campaign-fold-wave -> PR 906
#   - wt-888-finalize-labels-repo-arg -> feature/finalize-labels-repo-arg -> 907
#   - latest_open_pr=907 (the trap a naive resolver would pick for 838)
#   - closing-PR refs EMPTY for both (pr unset) -> forces branch resolution
# Plus a non-feature/ (fix/...) worktree to prove no feature/$SLUG rebuild.
echo "Fixture H: concurrent open PRs -> each issue resolves to its OWN PR"
fh=$(mktemp -d)
PIPELINE_TEST_TMPDIRS+=("$fh")
mkdir -p "$fh/stub" \
  "$fh/.claude/worktrees/wt-838-campaign-fold-wave" \
  "$fh/.claude/worktrees/wt-888-finalize-labels-repo-arg" \
  "$fh/.claude/worktrees/wt-555-some-bug"
make_shim "$fh/stub"

# Shared state: no closing-PR auto-link (pr unset), branch->PR linkage,
# the latest-open-pr trap, and CI green so the helper short-circuits to
# ACTION=green PR=<resolved> (we only assert the PR resolution here).
cat > "$fh/stub/gh-state" <<'STATE'
conclusion=success
run_id=0
retries=0
head_feature/campaign-fold-wave=906
head_feature/finalize-labels-repo-arg=907
head_fix/some-bug=555
latest_open_pr=907
STATE

# Fake `git worktree list --porcelain` advertising all three worktrees,
# each with the FULL branch ref the helper reads verbatim (no prefix
# reconstruction). Includes a fix/ branch to prove prefix-agnostic resolution.
cat > "$fh/stub/git" <<GIT
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "list" ]; then
  echo "worktree $fh/.claude/worktrees/wt-838-campaign-fold-wave"
  echo "HEAD deadbeef"
  echo "branch refs/heads/feature/campaign-fold-wave"
  echo ""
  echo "worktree $fh/.claude/worktrees/wt-888-finalize-labels-repo-arg"
  echo "HEAD cafebabe"
  echo "branch refs/heads/feature/finalize-labels-repo-arg"
  echo ""
  echo "worktree $fh/.claude/worktrees/wt-555-some-bug"
  echo "HEAD f00dface"
  echo "branch refs/heads/fix/some-bug"
  exit 0
fi
exec /usr/bin/git "\$@"
GIT
chmod +x "$fh/stub/git"

run_h() {
  local issue="$1"
  set +e
  ( cd "$fh" && PATH="$fh/stub:$PATH" \
    GH_FAKE_LOG="$fh/gh-$issue.log" GH_FAKE_STATE="$fh/stub/gh-state" \
    PIPELINE_REPO="fake/repo" \
    PIPELINE_CI_FIX_RETRY_BUDGET="2" \
    PIPELINE_CI_FIX_LOG_LINES="200" \
    PIPELINE_LOGS_ENABLED="" \
    bash "$HELPER" "$issue" 2>&1 )
  set -e
}

# Issue 838 MUST resolve to its own PR 906, NOT the trap 907.
inc
out_h838=$(run_h 838)
if echo "$out_h838" | grep -q "ISSUE=838 PR=906"; then
  pass_msg "H 838 -> own PR 906"
else
  fail_msg "H 838 expected PR=906, got: $out_h838"
fi
inc
if echo "$out_h838" | grep -q "PR=907"; then
  fail_msg "H 838 MISROUTED to trap PR 907: $out_h838"
else
  pass_msg "H 838 never picks the latest-open-pr trap (907)"
fi

# Issue 888 MUST resolve to its own PR 907.
inc
out_h888=$(run_h 888)
if echo "$out_h888" | grep -q "ISSUE=888 PR=907"; then
  pass_msg "H 888 -> own PR 907"
else
  fail_msg "H 888 expected PR=907, got: $out_h888"
fi

# Issue 555 on a fix/ branch MUST resolve to PR 555 via the FULL ref
# (proves no lossy feature/$SLUG reconstruction).
inc
out_h555=$(run_h 555)
if echo "$out_h555" | grep -q "ISSUE=555 PR=555"; then
  pass_msg "H 555 (fix/ branch) -> PR 555 via full ref (no feature/ rebuild)"
else
  fail_msg "H 555 expected PR=555, got: $out_h555"
fi

# ---- Summary -----------------------------------------------------------
echo
echo "Tests: $TESTS  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
