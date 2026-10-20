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
# fake gate (test fixture): token from $FAKE_GATE_DIR/<issue>, default green
auto_merge_should_fire() { cat "$FAKE_GATE_DIR/$1" 2>/dev/null || echo green; }
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
      *) echo "" ;;
    esac ;;
  "pr checks")
    case "$args" in
      *" --watch "*)
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
  : > "$GH_LOG"
  OUT="$(cd "$PROJ" && bash "$TMP/scripts/fullsend-merge-loop.sh" "$@" 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
}
reset_gate() { rm -rf "$FAKE_GATE_DIR"; mkdir -p "$FAKE_GATE_DIR"; }
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

echo ""
echo "  PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
