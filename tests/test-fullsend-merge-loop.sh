#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-merge-loop.sh — scripts/fullsend-merge-loop.sh, the ONE
# merge-loop call per wave: order -> rebase -> CI wait -> gate -> merge/block,
# ending in a `LOOP: done` / `LOOP: pending issues=<csv>` trailer.
#
# Substrate (the test-fullsend-merge-green-regate.sh shape): a fixture COPY of
# scripts/ whose auto-merge-gate.sh reads its token from $FAKE_GATE_DIR/<issue>
# (default green) and whose fullsend-merge-rebase.sh prints
# REBASE=${FAKE_REBASE_<PR>:-skip}; a stub `gh` on PATH that logs every call;
# real `git init` worktree dirs supplying the branches. PR = issue + 35.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t

mkdir -p "$TMP/scripts"
cp -r "$ROOT/scripts/." "$TMP/scripts/"
cat > "$TMP/scripts/auto-merge-gate.sh" <<'FAKE'
# fake gate (test fixture): first line of $FAKE_GATE_DIR/<issue>.seq (consumed)
# when non-empty, else the token from $FAKE_GATE_DIR/<issue>, default green
auto_merge_should_fire() {
  local s="$FAKE_GATE_DIR/$1.seq"
  if [ -s "$s" ]; then
    head -1 "$s"; tail -n +2 "$s" > "$s.t"; mv "$s.t" "$s"; return 0
  fi
  cat "$FAKE_GATE_DIR/$1" 2>/dev/null || echo green
}
FAKE
cat > "$TMP/scripts/fullsend-merge-rebase.sh" <<'FAKE'
#!/bin/bash
# fake rebase (test fixture): $1 worktree, $2 PR
v="FAKE_REBASE_$2"
echo "REBASE=${!v:-skip}"
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
      *" --head feature/c "*) echo 44 ;;
      *) echo "" ;;
    esac ;;
  "issue view")
    case "$args" in
      *" --json state "*) v="GH_STATE_$3"; echo "${!v:-OPEN}" ;;
      *) echo "" ;;
    esac ;;
  "pr view")
    case "$args" in
      *" --json files "*) v="GH_FILES_$3"; printf '%b\n' "${!v:-}" ;;
      *title*) echo "feat: pr $3" ;;
      *baseRefName*) echo "$PIPELINE_BASE_BRANCH" ;;
      *mergeCommit*) echo "abc$3" ;;
      *statusCheckRollup*)
        # first line of $FAKE_GATE_DIR/rollup-<P>.seq (consumed) when non-empty
        rs="$FAKE_GATE_DIR/rollup-$3.seq"
        if [ -s "$rs" ]; then
          head -1 "$rs"; tail -n +2 "$rs" > "$rs.t"; mv "$rs.t" "$rs"
        else
          v="GH_ROLLUP_$3"; d='{"statusCheckRollup":[]}'; echo "${!v:-$d}"
        fi ;;
      *) echo "" ;;
    esac ;;
  "pr checks")
    case "$args" in
      *" --watch "*)
        wn="${GH_LOG%/*}/watchn"; c=$(cat "$wn" 2>/dev/null); c=$(( ${c:-0} + 1 )); echo "$c" > "$wn"
        if [ -n "${GH_WATCH_NOCHECKS_FIRST:-}" ] && [ "$c" = 1 ]; then
          echo "no checks reported on the 'feature/a' branch" >&2; exit 1
        fi
        sleep "${GH_WATCH_SLEEP:-0}"
        [ -n "${GH_WATCH_FLIP:-}" ] && echo green > "$FAKE_GATE_DIR/$(( $3 - 35 ))"
        ;;
      *) v="GH_CHECKS_$3"; echo "${!v:-[]}" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

PROJ="$TMP/proj"
for spec in 7:a 8:b 9:c; do
  n=${spec%%:*}; x=${spec#*:}
  wt="$PROJ/.claude/worktrees/wt-$n-$x"
  mkdir -p "$wt"
  git -C "$wt" init -q -b "feature/$x" 2>/dev/null \
    || { git -C "$wt" init -q && git -C "$wt" symbolic-ref HEAD "refs/heads/feature/$x"; }
done

export GH_LOG="$TMP/gh.log" FAKE_GATE_DIR="$TMP/gate" PATH="$TMP/bin:$PATH"
export PIPELINE_REPO=o/r PIPELINE_BASE_BRANCH=evolve PIPELINE_PROJECT_ROOT="$PROJ"
export PIPELINE_WORKTREE_PREFIX=wt PIPELINE_SCREENSHOT_REWRITE_ENABLED=false
export PIPELINE_MERGE_LOOP_CI_WAIT_SECS=2 PIPELINE_MERGEABILITY_POLL_SECS=0
unset CLAUDE_PLUGIN_ROOT MANUAL_MERGE PIPELINE_MERGE_LOOP_WALL_SECS PIPELINE_MERGE_LOOP_CI_RERUN 2>/dev/null || true

# run <issues...> — OUT/RC/ERR set; the gh log is reset per run.
run() {
  : > "$GH_LOG"; : > "$TMP/watchn"
  OUT="$(cd "$PROJ" && bash "$TMP/scripts/fullsend-merge-loop.sh" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
reset_gate() { rm -rf "$FAKE_GATE_DIR" "$PROJ/.claude/scratch/merge-loop"; mkdir -p "$FAKE_GATE_DIR"; }
has_line() { printf '%s\n' "$OUT" | grep -qx -- "$1"; }
rc0() { if [ "$RC" -eq 0 ]; then pass_msg "$1: rc 0"; else fail_msg "$1: rc=$RC err=$ERR"; fi; }

# ---------------------------------------------------------------------------
scenario "(a) three PRs, skip + green: ordered fewest-overlap-first, all merged"
reset_gate
export GH_FILES_42='a.txt\nb.txt' GH_FILES_43='a.txt' GH_FILES_44='b.txt'
run 7 8 9
rc0 "(a)"
has_line 'ORDER: 43 44 42' && pass_msg "(a) ORDER: 43 44 42" || fail_msg "(a) ORDER line wrong: $OUT"
L8=$(printf '%s\n' "$OUT" | grep -nx 'LOOP: issue=#8 pr=#43 outcome=merged sha=abc43' | cut -d: -f1)
L9=$(printf '%s\n' "$OUT" | grep -nx 'LOOP: issue=#9 pr=#44 outcome=merged sha=abc44' | cut -d: -f1)
L7=$(printf '%s\n' "$OUT" | grep -nx 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' | cut -d: -f1)
if [ -n "$L8" ] && [ -n "$L9" ] && [ -n "$L7" ] && [ "$L8" -lt "$L9" ] && [ "$L9" -lt "$L7" ]; then
  pass_msg "(a) three merged LOOP lines in ORDER (43, 44, 42)"
else
  fail_msg "(a) merged LOOP lines missing/out of order: $OUT"
fi
[ "$(printf '%s\n' "$OUT" | tail -1)" = "LOOP: done" ] && pass_msg "(a) trailer LOOP: done is the last line" || fail_msg "(a) no trailing LOOP: done: $OUT"
printf '%s\n' "$OUT" | grep -q '^MERGE: issue=#8 pr=#43 reason=green sha=abc43' \
  && pass_msg "(a) relays the fullsend-merge-green.sh MERGE: line" || fail_msg "(a) MERGE: line not relayed"
unset GH_FILES_42 GH_FILES_43 GH_FILES_44

# ---------------------------------------------------------------------------
scenario "(e) re-entry: a CLOSED issue => already-merged, no merge"
reset_gate
export GH_STATE_7=CLOSED
run 7
rc0 "(e)"
printf '%s\n' "$OUT" | grep -qE '^LOOP: issue=#7 pr=#[0-9a-z]+ outcome=already-merged$' \
  && pass_msg "(e) outcome=already-merged" || fail_msg "(e) no already-merged line: $OUT"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(e) gh pr merge called" || pass_msg "(e) zero gh pr merge calls"
has_line 'LOOP: done' && pass_msg "(e) LOOP: done" || fail_msg "(e) no LOOP: done: $OUT"
unset GH_STATE_7

# ---------------------------------------------------------------------------
scenario "(b) REBASE=done + block-ci: CI wait on the rebased PR, then merged"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export FAKE_REBASE_42=done GH_WATCH_FLIP=1
run 7
rc0 "(b)"
W=$(grep -n '^gh pr checks 42 .*--watch' "$GH_LOG" | head -1 | cut -d: -f1)
M=$(grep -n '^gh pr merge 42 ' "$GH_LOG" | head -1 | cut -d: -f1)
if [ -n "$W" ] && [ -n "$M" ] && [ "$W" -lt "$M" ]; then
  pass_msg "(b) gh pr checks 42 --watch logged before gh pr merge 42"
else
  fail_msg "(b) watch/merge order wrong (watch=${W:-none} merge=${M:-none})"
fi
[ "$(grep -c '^gh pr checks 42 .*--watch' "$GH_LOG")" = 1 ] && pass_msg "(b) exactly one CI wait" || fail_msg "(b) CI wait count != 1"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(b) outcome=merged" || fail_msg "(b) not merged: $OUT"
unset FAKE_REBASE_42 GH_WATCH_FLIP

# ---------------------------------------------------------------------------
scenario "(f) CI wait times out: block-ci handed back, no label"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export FAKE_REBASE_42=done GH_WATCH_SLEEP=5 GH_WATCH_FLIP=1
PIPELINE_MERGE_LOOP_CI_WAIT_SECS=1 run 7
rc0 "(f)"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-ci' && pass_msg "(f) outcome=block-ci" || fail_msg "(f) no block-ci line: $OUT"
grep -q -- '--add-label' "$GH_LOG" && fail_msg "(f) a label was applied on block-ci" || pass_msg "(f) no --add-label call"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(f) gh pr merge called" || pass_msg "(f) no gh pr merge"
has_line 'LOOP: pending issues=7' && pass_msg "(f) LOOP: pending issues=7" || fail_msg "(f) pending trailer wrong: $OUT"
unset FAKE_REBASE_42 GH_WATCH_SLEEP GH_WATCH_FLIP

# ---------------------------------------------------------------------------
scenario "(h) wall guard: every issue deferred, none merged"
reset_gate
PIPELINE_MERGE_LOOP_WALL_SECS=0 run 7 8
rc0 "(h)"
has_line 'LOOP: issue=#7 pr=#42 outcome=deferred' && pass_msg "(h) issue 7 deferred" || fail_msg "(h) issue 7 not deferred: $OUT"
has_line 'LOOP: issue=#8 pr=#43 outcome=deferred' && pass_msg "(h) issue 8 deferred" || fail_msg "(h) issue 8 not deferred: $OUT"
printf '%s\n' "$OUT" | grep -qxE 'LOOP: pending issues=(7,8|8,7)' && pass_msg "(h) pending lists both" || fail_msg "(h) pending trailer wrong: $OUT"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(h) gh pr merge called" || pass_msg "(h) no gh pr merge"

# ---------------------------------------------------------------------------
scenario "(c) REBASE=conflict: needs-fix handed back, the sibling still merges"
reset_gate
export FAKE_REBASE_43='conflict FILES=f.txt,g.txt HEAD=abc123'
run 7 8
rc0 "(c)"
has_line 'LOOP: issue=#8 pr=#43 outcome=needs-fix files=f.txt,g.txt head=abc123 attempt=1' && pass_msg "(c) #8 outcome=needs-fix files=f.txt,g.txt head=abc123 attempt=1" || fail_msg "(c) needs-fix line wrong: $OUT"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(c) #7 still merged" || fail_msg "(c) sibling not merged: $OUT"
has_line 'LOOP: pending issues=8' && pass_msg "(c) LOOP: pending issues=8" || fail_msg "(c) pending trailer wrong: $OUT"
grep -q '^gh pr merge 43' "$GH_LOG" && fail_msg "(c) gh pr merge 43 called" || pass_msg "(c) no gh pr merge 43"
unset FAKE_REBASE_43

# ---------------------------------------------------------------------------
scenario "(c2) REBASE=dirty: needs-fix reason=dirty handed back, no merge, no label"
reset_gate
export FAKE_REBASE_42='dirty FILES=pipeline.config HEAD=abc123'
run 7
rc0 "(c2)"
has_line 'LOOP: issue=#7 pr=#42 outcome=needs-fix files=pipeline.config head=abc123 reason=dirty' && pass_msg "(c2) outcome=needs-fix ... reason=dirty" || fail_msg "(c2) needs-fix line wrong: $OUT"
has_line 'LOOP: pending issues=7' && pass_msg "(c2) LOOP: pending issues=7" || fail_msg "(c2) pending trailer wrong: $OUT"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(c2) gh pr merge called" || pass_msg "(c2) no gh pr merge"
grep -q -- '--add-label' "$GH_LOG" && fail_msg "(c2) a label was applied" || pass_msg "(c2) no label applied"
[ -e "$PROJ/.claude/scratch/merge-loop/42.conflicts" ] && fail_msg "(c2) reason=dirty wrote 42.conflicts" || pass_msg "(c2) reason=dirty never records 42.conflicts"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
scenario "(c3) REBASE=error: routed block-rebase-error once, not pending"
reset_gate
export FAKE_REBASE_42='error REASON=fatal: simulated refusal'
run 7
rc0 "(c3)"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-rebase-error' && pass_msg "(c3) outcome=block-rebase-error" || fail_msg "(c3) outcome wrong: $OUT"
printf '%s\n' "$OUT" | grep -q '^BLOCK: issue=#7 pr=#42 reason=block-rebase-error' && pass_msg "(c3) BLOCK: line relayed" || fail_msg "(c3) no BLOCK: line: $OUT"
[ "$(grep -c '^gh issue edit 7 .*--add-label manual-merge' "$GH_LOG")" = 1 ] \
  && pass_msg "(c3) exactly one manual-merge label call" || fail_msg "(c3) manual-merge label calls != 1"
has_line 'LOOP: done' && pass_msg "(c3) LOOP: done" || fail_msg "(c3) trailer wrong: $OUT"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(c3) gh pr merge called" || pass_msg "(c3) no gh pr merge"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
CONF_F="$PROJ/.claude/scratch/merge-loop/42.conflicts"
scenario "(viii) first conflict: needs-fix attempt=1, one 42.conflicts record"
reset_gate
export FAKE_REBASE_42='conflict FILES=bin/calibctl HEAD=aaa'
run 7
rc0 "(viii)"
has_line 'LOOP: issue=#7 pr=#42 outcome=needs-fix files=bin/calibctl head=aaa attempt=1' && pass_msg "(viii) needs-fix ... attempt=1" || fail_msg "(viii) needs-fix line wrong: $OUT"
[ "$(grep -c . "$CONF_F" 2>/dev/null)" = 1 ] && pass_msg "(viii) 42.conflicts holds exactly 1 line" || fail_msg "(viii) 42.conflicts lines=$(grep -c . "$CONF_F" 2>/dev/null || echo missing)"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
scenario "(x) moved head, same files: a fresh attempt=2, no label"
reset_gate
export FAKE_REBASE_42='conflict FILES=bin/calibctl HEAD=aaa'
run 7
export FAKE_REBASE_42='conflict FILES=bin/calibctl HEAD=bbb'
run 7
rc0 "(x)"
has_line 'LOOP: issue=#7 pr=#42 outcome=needs-fix files=bin/calibctl head=bbb attempt=2' && pass_msg "(x) needs-fix ... head=bbb attempt=2" || fail_msg "(x) needs-fix line wrong: $OUT"
grep -q -- '--add-label' "$GH_LOG" && fail_msg "(x) a label was applied" || pass_msg "(x) no --add-label call"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
scenario "(ix) same files + same head again: routed block-mergeable, not pending"
reset_gate
export FAKE_REBASE_42='conflict FILES=bin/calibctl HEAD=aaa'
run 7
run 7
rc0 "(ix)"
printf '%s\n' "$OUT" | grep -q 'outcome=needs-fix' && fail_msg "(ix) second run still needs-fix: $OUT" || pass_msg "(ix) no needs-fix on the repeat"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-mergeable' && pass_msg "(ix) outcome=block-mergeable" || fail_msg "(ix) outcome wrong: $OUT"
printf '%s\n' "$OUT" | grep -q '^BLOCK: issue=#7 pr=#42 reason=block-mergeable' && pass_msg "(ix) BLOCK: line relayed" || fail_msg "(ix) no BLOCK: line: $OUT"
[ "$(grep -c '^gh issue edit 7 .*--add-label manual-merge' "$GH_LOG")" = 1 ] \
  && pass_msg "(ix) exactly one manual-merge label call" || fail_msg "(ix) manual-merge label calls != 1"
printf '%s\n' "$ERR" | grep -qF 'REBASE: pr=#42 repeat=same-head' && pass_msg "(ix) stderr names repeat=same-head" || fail_msg "(ix) repeat=same-head missing: $ERR"
has_line 'LOOP: done' && pass_msg "(ix) LOOP: done" || fail_msg "(ix) trailer wrong: $OUT"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
scenario "(xii) merge removes 42.conflicts"
reset_gate
export FAKE_REBASE_42='conflict FILES=bin/calibctl HEAD=aaa'
run 7
[ -e "$CONF_F" ] && pass_msg "(xii) 42.conflicts exists before the merge run" || fail_msg "(xii) 42.conflicts missing before the merge run"
unset FAKE_REBASE_42
run 7
rc0 "(xii)"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(xii) outcome=merged" || fail_msg "(xii) not merged: $OUT"
[ -e "$CONF_F" ] && fail_msg "(xii) 42.conflicts survives the merge" || pass_msg "(xii) merge removes 42.conflicts"

# ---------------------------------------------------------------------------
scenario "(d) block-verdict: routed to fullsend-block-merge.sh once"
reset_gate
echo block-verdict > "$FAKE_GATE_DIR/7"
run 7
rc0 "(d)"
[ "$(grep -c '^gh issue edit 7 .*--add-label manual-merge' "$GH_LOG")" = 1 ] \
  && pass_msg "(d) exactly one manual-merge label call" || fail_msg "(d) manual-merge label calls != 1"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-verdict' && pass_msg "(d) outcome=block-verdict" || fail_msg "(d) outcome wrong: $OUT"
printf '%s\n' "$OUT" | grep -q '^BLOCK: issue=#7 pr=#42 reason=block-verdict' && pass_msg "(d) BLOCK: line relayed" || fail_msg "(d) no BLOCK: line: $OUT"
has_line 'LOOP: done' && pass_msg "(d) a routed block is not pending" || fail_msg "(d) trailer wrong: $OUT"
grep -q '^gh pr merge' "$GH_LOG" && fail_msg "(d) gh pr merge called" || pass_msg "(d) no gh pr merge"
[ -e "$PROJ/.claude/scratch/merge-loop/42.deferred" ] && fail_msg "(d) terminal block-verdict wrote 42.deferred" || pass_msg "(d) terminal token never touches the deferral counter"

# ---------------------------------------------------------------------------
scenario "(g) failed check: exactly one rerun of the run id, then block-ci"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export GH_CHECKS_42='[{"state":"FAILURE","link":"https://github.com/o/r/actions/runs/555/job/9"}]'
PIPELINE_MERGE_LOOP_CI_RERUN=1 run 7
rc0 "(g)"
[ "$(grep -cE '^gh run rerun 555( |$).*--failed' "$GH_LOG")" = 1 ] \
  && pass_msg "(g) exactly one gh run rerun 555 --failed" || fail_msg "(g) rerun calls wrong: $(grep 'run rerun' "$GH_LOG")"
grep -q 'run rerun 9' "$GH_LOG" && fail_msg "(g) reran the job id" || pass_msg "(g) never reruns the trailing job id"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-ci' && pass_msg "(g) outcome=block-ci" || fail_msg "(g) outcome wrong: $OUT"
grep -q -- '--add-label' "$GH_LOG" && fail_msg "(g) a label was applied on block-ci" || pass_msg "(g) no --add-label call"
unset GH_CHECKS_42

# ---------------------------------------------------------------------------
scenario "(i) first watch sees no checks: re-watch once checks register, then merged"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export FAKE_REBASE_42=done GH_ROLLUP_42='{"statusCheckRollup":[{"name":"t"}]}' GH_WATCH_FLIP=1 GH_WATCH_NOCHECKS_FIRST=1
run 7
rc0 "(i)"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(i) outcome=merged" || fail_msg "(i) not merged: $OUT"
[ "$(grep -c '^gh pr checks 42 .*--watch' "$GH_LOG")" = 2 ] && pass_msg "(i) exactly two watches (empty one not counted)" || fail_msg "(i) watch count != 2: $(grep -c '^gh pr checks 42 .*--watch' "$GH_LOG")"
unset FAKE_REBASE_42 GH_ROLLUP_42 GH_WATCH_FLIP GH_WATCH_NOCHECKS_FIRST

# ---------------------------------------------------------------------------
scenario "(v) completed watch, rollup lags: block-ci twice then green => merged, one watch"
reset_gate
printf '%s\n' block-ci block-ci green > "$FAKE_GATE_DIR/7.seq"
export FAKE_REBASE_42=done
run 7
rc0 "(v)"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(v) outcome=merged" || fail_msg "(v) not merged: $OUT"
[ "$(grep -c '^gh pr checks 42 .*--watch' "$GH_LOG")" = 1 ] && pass_msg "(v) exactly one watch (settle reads spend no wait)" || fail_msg "(v) watch count != 1: $(grep -c '^gh pr checks 42 .*--watch' "$GH_LOG")"
unset FAKE_REBASE_42

# ---------------------------------------------------------------------------
scenario "(vi) rollup unchanged from pre-push snapshot twice, then changed: watch starts only after the change"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export FAKE_REBASE_42=done GH_WATCH_FLIP=1
{
  for _ in 1 2 3; do echo '{"statusCheckRollup":[{"name":"t","status":"COMPLETED","detailsUrl":"u/1"}]}'; done
  echo '{"statusCheckRollup":[{"name":"t","status":"QUEUED","detailsUrl":"u/2"}]}'
} > "$FAKE_GATE_DIR/rollup-42.seq"
run 7
rc0 "(vi)"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(vi) outcome=merged" || fail_msg "(vi) not merged: $OUT"
RB_READS=$(awk '/^gh pr checks 42 .*--watch/ { exit } /^gh pr view 42 .*statusCheckRollup/ { c++ } END { print c + 0 }' "$GH_LOG")
[ "$RB_READS" = 4 ] && pass_msg "(vi) 4 rollup reads (pre-push + 3 settle) precede the first watch" || fail_msg "(vi) rollup reads before the first watch=$RB_READS (want 4)"
unset FAKE_REBASE_42 GH_WATCH_FLIP

# ---------------------------------------------------------------------------
scenario "(vii) LOOP: log= names a merge-loop scratch file holding the REBASE line"
reset_gate
echo block-ci > "$FAKE_GATE_DIR/7"
export FAKE_REBASE_42=done GH_WATCH_FLIP=1
run 7
rc0 "(vii)"
LOG=$(printf '%s\n' "$OUT" | sed -n 's/^LOOP: log=//p')
case "$LOG" in
  "$PROJ/.claude/scratch/merge-loop/"*.log) pass_msg "(vii) LOOP: log= names a merge-loop scratch .log" ;;
  *) fail_msg "(vii) LOOP: log= path wrong: '${LOG}' out=$OUT" ;;
esac
[ -n "$LOG" ] && [ -f "$LOG" ] && pass_msg "(vii) the log file exists" || fail_msg "(vii) log file missing: '${LOG}'"
[ -n "$LOG" ] && grep -q 'REBASE=done' "$LOG" 2>/dev/null && pass_msg "(vii) the log holds the REBASE=done relay" || fail_msg "(vii) REBASE=done not in log: $(cat "$LOG" 2>/dev/null)"
[ "$(printf '%s\n' "$OUT" | tail -1)" = "LOOP: done" ] && pass_msg "(vii) LOOP: done stays the last line" || fail_msg "(vii) last line not LOOP: done: $OUT"
case "$(printf '%s\n' "$OUT" | tail -2 | head -1)" in
  "LOOP: log="*) pass_msg "(vii) LOOP: log= immediately precedes the trailer" ;;
  *) fail_msg "(vii) LOOP: log= not right before the trailer: $OUT" ;;
esac
unset FAKE_REBASE_42 GH_WATCH_FLIP

# ---------------------------------------------------------------------------
DEFER_F="$PROJ/.claude/scratch/merge-loop/42.deferred"
scenario "(ii) block-mergestate settles to green: merged, no label, counter removed"
reset_gate
printf '%s\n' block-mergestate block-mergestate green > "$FAKE_GATE_DIR/7.seq"
mkdir -p "$PROJ/.claude/scratch/merge-loop"; echo 1 > "$DEFER_F"
run 7
rc0 "(ii)"
has_line 'LOOP: issue=#7 pr=#42 outcome=merged sha=abc42' && pass_msg "(ii) outcome=merged" || fail_msg "(ii) not merged: $OUT"
grep -q -- '--add-label manual-merge' "$GH_LOG" && fail_msg "(ii) manual-merge label applied" || pass_msg "(ii) no manual-merge label"
printf '%s\n' "$OUT" | grep -q '^BLOCK:' && fail_msg "(ii) BLOCK: line emitted" || pass_msg "(ii) no BLOCK: line"
[ -e "$DEFER_F" ] && fail_msg "(ii) 42.deferred survives the merge" || pass_msg "(ii) merge removes 42.deferred"

# ---------------------------------------------------------------------------
scenario "(iii) block-mergestate never settles: deferred, counter=1, no label"
reset_gate
echo block-mergestate > "$FAKE_GATE_DIR/7"
run 7
rc0 "(iii)"
has_line 'LOOP: issue=#7 pr=#42 outcome=deferred' && pass_msg "(iii) outcome=deferred" || fail_msg "(iii) not deferred: $OUT"
grep -q -- '--add-label' "$GH_LOG" && fail_msg "(iii) a label was applied" || pass_msg "(iii) no --add-label call"
[ "$(cat "$DEFER_F" 2>/dev/null)" = 1 ] && pass_msg "(iii) 42.deferred reads 1" || fail_msg "(iii) 42.deferred=$(cat "$DEFER_F" 2>/dev/null || echo missing)"
has_line 'LOOP: pending issues=7' && pass_msg "(iii) LOOP: pending issues=7" || fail_msg "(iii) pending trailer wrong: $OUT"

# ---------------------------------------------------------------------------
scenario "(iv) deferral cap reached: routed block-mergestate once"
reset_gate
echo block-mergestate > "$FAKE_GATE_DIR/7"
mkdir -p "$PROJ/.claude/scratch/merge-loop"; echo 3 > "$DEFER_F"
run 7
rc0 "(iv)"
[ "$(grep -c '^gh issue edit 7 .*--add-label manual-merge' "$GH_LOG")" = 1 ] \
  && pass_msg "(iv) exactly one manual-merge label call" || fail_msg "(iv) manual-merge label calls != 1"
has_line 'LOOP: issue=#7 pr=#42 outcome=block-mergestate' && pass_msg "(iv) outcome=block-mergestate" || fail_msg "(iv) outcome wrong: $OUT"
printf '%s\n' "$OUT" | grep -q '^BLOCK: issue=#7 pr=#42 reason=block-mergestate' && pass_msg "(iv) BLOCK: line relayed" || fail_msg "(iv) no BLOCK: line: $OUT"
has_line 'LOOP: done' && pass_msg "(iv) LOOP: done" || fail_msg "(iv) trailer wrong: $OUT"

# ---------------------------------------------------------------------------
scenario "(p) prose/config pins: repeated-needs-fix rule + DEFER_MAX example"
GATE_MD="$ROOT/skills/fullsend/references/auto-merge-gate.md"
grep -qF 'repeating its previous `files=`' "$GATE_MD" && pass_msg "(p) Re-entry names the repeated files= rule" || fail_msg "(p) repeated files= rule missing"
grep -qF 'at most 3 per issue per wave' "$GATE_MD" && pass_msg "(p) Re-entry caps rebase-fix at 3 per issue per wave" || fail_msg "(p) per-wave cap missing"
grep -qF 'A second `needs-fix` for the same issue' "$GATE_MD" && fail_msg "(p) stale second-needs-fix rule still present" || pass_msg "(p) stale second-needs-fix rule gone"
grep -qF 'except `block-ci` (handed back) and `block-mergestate`/`block-mergeable`' "$GATE_MD" && pass_msg "(p) block-* routing names the settled merge-state tokens" || fail_msg "(p) block-* routing omits block-mergestate/block-mergeable"
grep -qF 'reason** except `block-ci`, the loop calls' "$GATE_MD" && fail_msg "(p) stale block-ci-only routing wording still present" || pass_msg "(p) stale block-ci-only routing wording gone"
grep -qF 'reason=dirty' "$GATE_MD" && pass_msg "(p) Re-entry names the reason=dirty token" || fail_msg "(p) reason=dirty token missing from Re-entry"
grep -qF 'LOOP: log=<path>' "$GATE_MD" && pass_msg "(p) LOOP text block names LOOP: log=<path>" || fail_msg "(p) LOOP: log=<path> missing from the LOOP text block"
grep -qE '^#PIPELINE_MERGE_LOOP_DEFER_MAX="3"' "$ROOT/pipeline.config.example" && pass_msg "(p) pipeline.config.example carries DEFER_MAX" || fail_msg "(p) DEFER_MAX example line missing"

echo ""
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
