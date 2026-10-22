#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-merge-green-regate.sh — fullsend-merge-green.sh re-gates
# each PR with auto_merge_should_fire immediately before `gh pr merge` (#1540).
#
# A green GATE: token carries no head sha; anything that moves the PR head
# between the gate and the merge (merge-time rebase, rebase-fix, fix commit)
# must not let the stale token merge the moved head.
#
# Substrate: a fixture COPY of scripts/ whose auto-merge-gate.sh is a fake
# (`FAKE_GATE_<issue>` env, default green), a stub `gh` on PATH that logs every
# call, and two real `git init` worktree dirs supplying the branches.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL="$ROOT/scripts/fullsend-merge-green.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t

mkdir -p "$TMP/scripts"
cp -r "$ROOT/scripts/." "$TMP/scripts/"
cat > "$TMP/scripts/auto-merge-gate.sh" <<'FAKE'
# fake gate (test fixture): token from FAKE_GATE_<issue>, default green
auto_merge_should_fire() { local v="FAKE_GATE_$1"; echo "${!v:-green}"; }
FAKE

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
args=" $* "
case "$1 $2" in
  "pr list")
    case "$args" in
      *" --head feature/a "*) echo 42 ;;
      *" --head feature/b "*) echo 43 ;;
      *) echo "" ;;
    esac ;;
  "pr view")
    case "$args" in
      *baseRefName*) echo "$PIPELINE_BASE_BRANCH" ;;
      *mergeCommit*) echo "abc123" ;;
      *) echo "" ;;
    esac ;;
  "pr merge")
    # #1570: fail the first GH_MERGE_FAILS merges (stdout noise + stderr message)
    c=$(cat "$MERGE_COUNT" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$MERGE_COUNT"
    if [ "$c" -le "${GH_MERGE_FAILS:-0}" ]; then
      echo "gh-stdout-noise"
      echo "${GH_MERGE_ERR:-GraphQL: Head branch is out of date. Review and try the merge again. (mergePullRequest)}" >&2
      exit 1
    fi ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

PROJ="$TMP/proj"
for spec in 7:a 8:b; do
  n=${spec%%:*}; x=${spec#*:}
  wt="$PROJ/.claude/worktrees/wt-$n-$x"
  mkdir -p "$wt"
  git -C "$wt" init -q -b "feature/$x" 2>/dev/null \
    || { git -C "$wt" init -q && git -C "$wt" symbolic-ref HEAD "refs/heads/feature/$x"; }
done

export GH_LOG="$TMP/gh.log" PATH="$TMP/bin:$PATH" MERGE_COUNT="$TMP/merge.count"
export PIPELINE_REPO=o/r PIPELINE_BASE_BRANCH=evolve PIPELINE_PROJECT_ROOT="$PROJ"
export PIPELINE_WORKTREE_PREFIX=wt PIPELINE_SCREENSHOT_REWRITE_ENABLED=false FAKE_GATE_8=block-ci
unset CLAUDE_PLUGIN_ROOT MANUAL_MERGE FAKE_GATE_7 2>/dev/null || true

: > "$GH_LOG"
OUT="$(cd "$PROJ" && bash "$TMP/scripts/fullsend-merge-green.sh" 7 8 2>"$TMP/err")"; RC=$?

echo "-- behaviour: green merges, block-ci re-gate does not --"
[ "$RC" -eq 0 ] && pass_msg "rc 0" || fail_msg "rc=$RC err=$(cat "$TMP/err")"
printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#7 pr=#42 reason=green sha=abc123' \
  && pass_msg "issue 7 green => merged with sha" || fail_msg "issue 7 line missing: $OUT"
printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#8 pr=#43 reason=block-ci' \
  && pass_msg "issue 8 re-gate => MERGE reason=block-ci (no sha)" || fail_msg "issue 8 line wrong: $OUT"
grep -q '^gh pr merge 42 ' "$GH_LOG" && pass_msg "gh pr merge 42 called" || fail_msg "no gh pr merge 42"
grep -q '^gh pr merge 43' "$GH_LOG" && fail_msg "gh pr merge 43 called on block-ci" || pass_msg "no gh pr merge 43"
grep -q '^gh pr comment 43' "$GH_LOG" && fail_msg "footer posted on PR 43" || pass_msg "no footer on PR 43"
grep -q '^gh issue close 8' "$GH_LOG" && fail_msg "issue 8 closed" || pass_msg "issue 8 not closed"

echo "-- behaviour: head-out-of-date merge refusal re-gates and retries (#1570) --"
export PIPELINE_MERGEABILITY_POLL_SECS=0
mkdir -p "$TMP/s3"
cp -r "$ROOT/scripts/." "$TMP/s3/"
cat > "$TMP/s3/auto-merge-gate.sh" <<'FAKE'
# fake gate (test fixture): call 1 => green, later calls => block-ci
auto_merge_should_fire() {
  local c; c=$(cat "$GATE_COUNT" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$GATE_COUNT"
  if [ "$c" -le 1 ]; then echo green; else echo block-ci; fi
}
FAKE
export GATE_COUNT="$TMP/gate.count"
# run_one <scripts-dir> [VAR=val...] — single issue 7 (PR 42), fresh log + counters
run_one() {
  local dir="$1"; shift
  : > "$GH_LOG"; rm -f "$MERGE_COUNT" "$GATE_COUNT"
  OUT="$(cd "$PROJ" && env "$@" bash "$dir/fullsend-merge-green.sh" 7 2>"$TMP/err")"; RC=$?
  MERGES=$(grep -c '^gh pr merge 42 ' "$GH_LOG")
  RETRIES=$(grep -cE '^fullsend-merge-green: pr=#42 merge refused \(head out of date\), retry [0-9]+/[0-9]+ in 0s$' "$TMP/err")
}

run_one "$TMP/scripts" GH_MERGE_FAILS=1
printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#7 pr=#42 reason=green sha=abc123' \
  && pass_msg "(a) one refusal => retried, merged with sha" || fail_msg "(a) line wrong: $OUT"
[ "$RETRIES" -eq 1 ] && grep -qx 'fullsend-merge-green: pr=#42 merge refused (head out of date), retry 1/3 in 0s' "$TMP/err" \
  && pass_msg "(a) exactly one retry 1/3 stderr line" || fail_msg "(a) retries=$RETRIES err=$(cat "$TMP/err")"
[ "$MERGES" -eq 2 ] && pass_msg "(a) 2 merge calls" || fail_msg "(a) merges=$MERGES"

run_one "$TMP/scripts" GH_MERGE_FAILS=99 PIPELINE_MERGE_RETRY_MAX=2
printf '%s\n' "$OUT" | grep -qE '^MERGE: issue=#7 pr=#42 reason=block-merge-failed detail="GraphQL: Head branch is out of date\.' \
  && pass_msg "(b) retries exhausted => block-merge-failed with detail" || fail_msg "(b) line wrong: $OUT"
[ "$RETRIES" -eq 2 ] && grep -qx 'fullsend-merge-green: pr=#42 merge refused (head out of date), retry 1/2 in 0s' "$TMP/err" \
  && grep -qx 'fullsend-merge-green: pr=#42 merge refused (head out of date), retry 2/2 in 0s' "$TMP/err" \
  && pass_msg "(b) retry 1/2 + 2/2 stderr lines" || fail_msg "(b) retries=$RETRIES err=$(cat "$TMP/err")"
[ "$MERGES" -eq 3 ] && pass_msg "(b) 3 merge calls (MAX counts retries)" || fail_msg "(b) merges=$MERGES"
grep -q '^gh pr comment 42' "$GH_LOG" && fail_msg "(b) footer posted" || pass_msg "(b) no footer"

run_one "$TMP/scripts" GH_MERGE_FAILS=99 'GH_MERGE_ERR=Pull request is not mergeable'
printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#7 pr=#42 reason=block-merge-failed detail="Pull request is not mergeable"' \
  && pass_msg "(c) other error => block-merge-failed, stderr-only detail" || fail_msg "(c) line wrong: $OUT"
printf '%s\n' "$OUT" | grep -qx 'gh-stdout-noise' \
  && pass_msg "(c) gh stdout stays on stdout" || fail_msg "(c) gh stdout lost: $OUT"
[ "$RETRIES" -eq 0 ] && pass_msg "(c) no retry" || fail_msg "(c) retries=$RETRIES"
[ "$MERGES" -eq 1 ] && pass_msg "(c) 1 merge call" || fail_msg "(c) merges=$MERGES"

run_one "$TMP/s3" GH_MERGE_FAILS=1
printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#7 pr=#42 reason=block-ci' \
  && pass_msg "(d) re-gate non-green before retry => gate token, no detail" || fail_msg "(d) line wrong: $OUT"
[ "$MERGES" -eq 1 ] && pass_msg "(d) no merge after gate went non-green" || fail_msg "(d) merges=$MERGES"
grep -q '^gh pr comment 42' "$GH_LOG" && fail_msg "(d) footer posted" || pass_msg "(d) no footer"

echo "-- static: re-gate sits before gh pr merge in the REAL script (code lines only) --"
first_line() { grep -nE -- "$1" "$REAL" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1; }
GATE_LINE=$(first_line 'auto_merge_should_fire "\$ISSUE" "\$PR_NUM"')
MERGE_LINE=$(first_line 'gh pr merge "\$PR_NUM"')
if [ -n "$GATE_LINE" ] && [ -n "$MERGE_LINE" ] && [ "$GATE_LINE" -lt "$MERGE_LINE" ]; then
  pass_msg "auto_merge_should_fire (L$GATE_LINE) before gh pr merge (L$MERGE_LINE)"
else
  fail_msg "re-gate order wrong (gate=${GATE_LINE:-none} merge=${MERGE_LINE:-none})"
fi

echo ""
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
