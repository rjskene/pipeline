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

export GH_LOG="$TMP/gh.log" PATH="$TMP/bin:$PATH"
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
