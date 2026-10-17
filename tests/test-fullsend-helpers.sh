#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-helpers.sh — the scripts/fullsend-*.sh wave helpers.
#
# skills/fullsend/SKILL.md calls each multi-command step as ONE helper call per
# wave. Each helper is the step's former fence text moved verbatim, so this test
# pins the behaviour the fence used to carry: the emitted line grammar, the
# fail-closed PR derivation (an empty worktree glob never names an unrelated
# PR), the merge loop's line order, and the benign "already closed" swallow.
#
# Substrate: a stub `gh` on PATH logs every call and answers from env knobs; a
# real `git init` worktree dir supplies the branch.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HELPERS="fullsend-fetch-attachments.sh fullsend-approve.sh fullsend-preflight.sh fullsend-gate.sh fullsend-merge-green.sh fullsend-block-merge.sh fullsend-dispatch-specs.sh fullsend-release-prs.sh fullsend-merge-order.sh"

# ---------------------------------------------------------------------------
# Stub gh. Knobs: GH_PR_NUM, GH_BASE, GH_MERGE_RC, GH_CLOSE_MODE
# (ok|already|genuine), GH_LABELS, GH_RELEASE_JSON. Every call is logged.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
args=" $* "
case "$1 $2" in
  "pr list")
    case "$args" in
      *" --head "*) echo "${GH_PR_NUM:-}" ;;
      *"--label autorelease"*) echo "${GH_RELEASE_JSON:-[]}" ;;
      *) echo "" ;;
    esac ;;
  "pr view")
    case "$args" in
      *baseRefName*) echo "${GH_BASE:-}" ;;
      *mergeCommit*) echo "abc123" ;;
      *) echo "" ;;
    esac ;;
  "pr merge") exit "${GH_MERGE_RC:-0}" ;;
  "issue close")
    case "${GH_CLOSE_MODE:-ok}" in
      already) echo "issue #$3 is already closed" >&2; exit 1 ;;
      genuine) echo "HTTP 502: bad gateway" >&2; exit 1 ;;
    esac ;;
  "issue view") printf '%s\n' ${GH_LABELS:-} ;;
  "api "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

PROJ="$TMP/proj"
WT7="$PROJ/.claude/worktrees/wt-7-foo"
mkdir -p "$WT7"
git -C "$WT7" init -q -b feature/foo 2>/dev/null \
  || { git -C "$WT7" init -q && git -C "$WT7" symbolic-ref HEAD refs/heads/feature/foo; }

export GH_LOG="$TMP/gh.log"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="o/r" PIPELINE_BASE_BRANCH="evolve" PIPELINE_PROJECT_ROOT="$PROJ"
export PIPELINE_WORKTREE_PREFIX="wt" PIPELINE_SCREENSHOT_REWRITE_ENABLED=false
unset CLAUDE_PLUGIN_ROOT MANUAL_MERGE PIPELINE_RELEASE_PR_AUTO_MERGE 2>/dev/null || true

run() { : > "$GH_LOG"; OUT="$(cd "$PROJ" && "$@" 2>"$TMP/err")"; RC=$?; }

# ---------------------------------------------------------------------------
scenario "every helper exists, is strict-mode, and answers --help"

for h in $HELPERS _fullsend-resolve-pr.sh; do
  if [ -f "$S/$h" ]; then pass_msg "$h exists"; else fail_msg "$h is missing"; continue; fi
  if [ "$h" = "_fullsend-resolve-pr.sh" ] || grep -q '^set -uo pipefail' "$S/$h"; then
    pass_msg "$h runs under set -uo pipefail (or is a sourced lib)"
  else
    fail_msg "$h lacks 'set -uo pipefail'"
  fi
done

for h in $HELPERS; do
  [ -f "$S/$h" ] || continue
  run bash "$S/$h" --help
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^Usage:'; then
    pass_msg "$h --help exits 0 with a Usage: line"
  else
    fail_msg "$h --help rc=$RC or no Usage: line"
  fi
  if [ -s "$GH_LOG" ]; then fail_msg "$h --help called gh"; else pass_msg "$h --help makes no gh call"; fi
done

declare -A GRAMMAR=(
  [fullsend-gate.sh]='GATE: issue=#<N> pr=#<P> reason=<token>'
  [fullsend-merge-green.sh]='MERGE: issue=#<N> pr=#<P> reason='
  [fullsend-preflight.sh]='PREFLIGHT issue=#<N> PREFLIGHT='
  [fullsend-dispatch-specs.sh]='DISPATCH issue=#<N>'
  [fullsend-block-merge.sh]='BLOCK: issue=#<N> pr=#<P> reason=<token>'
  [fullsend-approve.sh]='TRANSITION='
  [fullsend-merge-order.sh]='ORDER:'
)
for h in "${!GRAMMAR[@]}"; do
  [ -f "$S/$h" ] || continue
  run bash "$S/$h" --help
  if printf '%s\n' "$OUT" | grep -qF -- "${GRAMMAR[$h]}"; then
    pass_msg "$h --help states its line grammar (${GRAMMAR[$h]})"
  else
    fail_msg "$h --help does not state '${GRAMMAR[$h]}'"
  fi
done

# ---------------------------------------------------------------------------
scenario "_fullsend-resolve-pr.sh fails closed on an empty worktree glob"

if [ -f "$S/_fullsend-resolve-pr.sh" ]; then
  : > "$GH_LOG"
  RES="$(cd "$PROJ" && source "$S/_fullsend-resolve-pr.sh" && fullsend_resolve_pr 9; echo "WT=[$WT] BR=[$BR] PR=[$PR_NUM]")"
  if [ "$RES" = "WT=[] BR=[] PR=[]" ]; then pass_msg "no worktree => WT/BR/PR_NUM all empty"; else fail_msg "empty-glob derivation gave: $RES"; fi
  if grep -q -- '--head' "$GH_LOG"; then fail_msg "gh pr list --head ran on an empty branch"; else pass_msg "gh pr list --head never runs on an empty branch"; fi
  RES="$(cd "$PROJ" && export GH_PR_NUM=42 && source "$S/_fullsend-resolve-pr.sh" && fullsend_resolve_pr 7; echo "BR=[$BR] PR=[$PR_NUM]")"
  if [ "$RES" = "BR=[feature/foo] PR=[42]" ]; then pass_msg "worktree => branch => PR derived"; else fail_msg "derivation gave: $RES"; fi
fi

# ---------------------------------------------------------------------------
scenario "fullsend-gate.sh: one GATE line per issue; empty worktree => block-*"

if [ -f "$S/fullsend-gate.sh" ]; then
  run bash "$S/fullsend-gate.sh" 9
  if printf '%s\n' "$OUT" | grep -qE '^GATE: issue=#9 pr=# reason=block-[a-z-]+$'; then
    pass_msg "empty worktree => visible GATE line with a block-* token"
  else
    fail_msg "gate empty-WT output: $OUT"
  fi
  export GH_PR_NUM=42
  run bash "$S/fullsend-gate.sh" 7 9
  if [ "$(printf '%s\n' "$OUT" | grep -c '^GATE: ')" = "2" ]; then pass_msg "two issues => two GATE lines (one call per wave)"; else fail_msg "gate 2-issue output: $OUT"; fi
  if printf '%s\n' "$OUT" | grep -q '^GATE: issue=#7 pr=#42 reason='; then pass_msg "issue 7 gates its own PR #42"; else fail_msg "gate issue 7 line: $OUT"; fi
  unset GH_PR_NUM
fi

# ---------------------------------------------------------------------------
scenario "fullsend-merge-green.sh: green loop order, guards, close swallow"

if [ -f "$S/fullsend-merge-green.sh" ]; then
  run bash "$S/fullsend-merge-green.sh" 9
  if [ "$RC" -eq 0 ] && [ "$OUT" = "MERGE: issue=#9 pr=#none reason=block-no-pr" ]; then
    pass_msg "empty worktree => reason=block-no-pr"
  else
    fail_msg "block-no-pr: rc=$RC out=$OUT"
  fi
  if grep -q 'pr merge' "$GH_LOG"; then fail_msg "gh pr merge ran with no PR"; else pass_msg "gh pr merge unreachable with no PR"; fi

  export GH_PR_NUM=42 GH_BASE=main
  run bash "$S/fullsend-merge-green.sh" 7
  if [ "$OUT" = "MERGE: issue=#7 pr=#42 reason=block-base-mismatch" ]; then pass_msg "TOCTOU base re-read => block-base-mismatch"; else fail_msg "base mismatch out=$OUT"; fi
  if grep -q 'pr merge' "$GH_LOG"; then fail_msg "gh pr merge ran on a base mismatch"; else pass_msg "no merge on a base mismatch"; fi

  export GH_BASE=evolve GH_MERGE_RC=1
  run bash "$S/fullsend-merge-green.sh" 7
  if [ "$OUT" = "MERGE: issue=#7 pr=#42 reason=block-merge-failed" ]; then pass_msg "failed merge => block-merge-failed"; else fail_msg "merge-failed out=$OUT"; fi
  if grep -q 'pr comment' "$GH_LOG"; then fail_msg "footer posted on an unmerged PR"; else pass_msg "no footer on a failed merge"; fi

  export GH_MERGE_RC=0 GH_CLOSE_MODE=already
  run bash "$S/fullsend-merge-green.sh" 7
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'MERGE: issue=#7 pr=#42 reason=green sha=abc123'; then
    pass_msg "green => MERGE reason=green sha=<sha>, rc 0"
  else
    fail_msg "green: rc=$RC out=$OUT"
  fi
  if printf '%s\n' "$OUT" | grep -q 'already closed'; then pass_msg "already-closed close is reported benign"; else fail_msg "no benign already-closed line: $OUT"; fi
  m=$(grep -n 'pr merge' "$GH_LOG" | head -1 | cut -d: -f1)
  s=$(grep -n 'mergeCommit' "$GH_LOG" | head -1 | cut -d: -f1)
  c=$(grep -n 'pr comment 42' "$GH_LOG" | head -1 | cut -d: -f1)
  x=$(grep -n 'issue close' "$GH_LOG" | head -1 | cut -d: -f1)
  if [ -n "$m" ] && [ -n "$s" ] && [ -n "$c" ] && [ -n "$x" ] && [ "$m" -lt "$s" ] && [ "$s" -lt "$c" ] && [ "$c" -lt "$x" ]; then
    pass_msg "gh call order: merge < sha < footer < close"
  else
    fail_msg "gh call order wrong (merge=$m sha=$s footer=$c close=$x)"
  fi
  if grep -q 'pr comment 42 .*Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at' "$GH_LOG"; then pass_msg "footer literal prefix posted"; else fail_msg "footer literal missing"; fi

  export GH_CLOSE_MODE=genuine
  run bash "$S/fullsend-merge-green.sh" 7
  if [ "$RC" -ne 0 ]; then pass_msg "genuine close failure exits non-zero (fail-loud kept)"; else fail_msg "genuine close failure was swallowed"; fi
  unset GH_PR_NUM GH_BASE GH_MERGE_RC GH_CLOSE_MODE
fi

# ---------------------------------------------------------------------------
scenario "fullsend-block-merge.sh: skip comment + manual-merge label"

if [ -f "$S/fullsend-block-merge.sh" ]; then
  export GH_PR_NUM=42
  run bash "$S/fullsend-block-merge.sh" 7:block-ci
  if [ "$RC" -eq 0 ] && grep -q 'pr comment 42 .*Auto-merge skipped: block-ci' "$GH_LOG"; then pass_msg "block-ci => Auto-merge skipped: comment"; else fail_msg "block comment missing (rc=$RC)"; fi
  if grep -q 'issue edit 7 .*--add-label manual-merge' "$GH_LOG"; then pass_msg "manual-merge label applied"; else fail_msg "manual-merge label not applied"; fi
  if printf '%s\n' "$OUT" | grep -q '^BLOCK: issue=#7 pr=#42 reason=block-ci'; then pass_msg "BLOCK: line emitted"; else fail_msg "BLOCK line: $OUT"; fi
  run bash "$S/fullsend-block-merge.sh" 7:block-base-mismatch
  if grep -q 'retarget-pr.sh 42 evolve' "$GH_LOG" && grep -q 'gh pr edit 42 --base evolve' "$GH_LOG"; then pass_msg "base-mismatch comment carries the retarget suggestion"; else fail_msg "retarget suggestion missing"; fi
  unset GH_PR_NUM
  run bash "$S/fullsend-block-merge.sh" 9:block-no-pr
  if grep -q 'pr comment' "$GH_LOG"; then fail_msg "commented with no PR"; else pass_msg "no PR => no comment"; fi
  if grep -q 'issue edit 9 .*--add-label manual-merge' "$GH_LOG"; then pass_msg "no PR => label still applied"; else fail_msg "no-PR label missing"; fi
fi

# ---------------------------------------------------------------------------
scenario "fullsend-preflight.sh: one PREFLIGHT line per issue"

if [ -f "$S/fullsend-preflight.sh" ]; then
  run bash "$S/fullsend-preflight.sh" 9
  if printf '%s\n' "$OUT" | grep -qE '^PREFLIGHT issue=#9 PREFLIGHT=block REASON='; then pass_msg "empty worktree => PREFLIGHT=block line"; else fail_msg "preflight out=$OUT"; fi
  if grep -q -- '--head' "$GH_LOG"; then fail_msg "preflight ran gh --head on an empty branch"; else pass_msg "preflight derivation fails closed"; fi
fi

# ---------------------------------------------------------------------------
scenario "fullsend-dispatch-specs.sh: label => PATH, one DISPATCH line each"

if [ -f "$S/fullsend-dispatch-specs.sh" ]; then
  export GH_LABELS="quick-fix"
  run bash "$S/fullsend-dispatch-specs.sh" 7
  if printf '%s\n' "$OUT" | grep -q '^DISPATCH issue=#7 .*PATH=D .*MODEL='; then pass_msg "quick-fix => PATH=D with MODEL="; else fail_msg "dispatch D out=$OUT"; fi
  export GH_LABELS="multi-task"
  run bash "$S/fullsend-dispatch-specs.sh" 7 8
  if [ "$(printf '%s\n' "$OUT" | grep -c '^DISPATCH ')" = "2" ] && printf '%s\n' "$OUT" | grep -q 'PATH=C'; then pass_msg "multi-task => PATH=C, one line per issue"; else fail_msg "dispatch C out=$OUT"; fi
  export GH_LABELS=""
  run bash "$S/fullsend-dispatch-specs.sh" 7
  if printf '%s\n' "$OUT" | grep -q 'PATH=B'; then pass_msg "no path label => PATH=B"; else fail_msg "dispatch B out=$OUT"; fi
  unset GH_LABELS
fi

# ---------------------------------------------------------------------------
scenario "fullsend-approve.sh: transition-issue.sh per issue, --from/--comment relayed"

if [ -f "$S/fullsend-approve.sh" ]; then
  export GH_LABELS="plan-reviewed"
  run bash "$S/fullsend-approve.sh" 7 8
  if [ "$(printf '%s\n' "$OUT" | grep -c '^TRANSITION=')" = "2" ]; then pass_msg "two issues => two TRANSITION lines"; else fail_msg "approve out=$OUT"; fi
  if grep -q 'issue edit 7 .*--add-label plan-approved --remove-label plan-reviewed' "$GH_LOG"; then pass_msg "default --from plan-reviewed"; else fail_msg "default flip missing"; fi
  export GH_LABELS="plan-pending"
  run bash "$S/fullsend-approve.sh" --from plan-pending --comment "plan-eval skipped: lean profile" 7
  if grep -q 'issue edit 7 .*--remove-label plan-pending' "$GH_LOG" && grep -q 'issue comment 7 .*plan-eval skipped: lean profile' "$GH_LOG"; then pass_msg "--from/--comment relayed"; else fail_msg "--from/--comment not relayed"; fi
  unset GH_LABELS
fi

# ---------------------------------------------------------------------------
scenario "fullsend-release-prs.sh: no-op unless PIPELINE_RELEASE_PR_AUTO_MERGE=true"

if [ -f "$S/fullsend-release-prs.sh" ]; then
  run bash "$S/fullsend-release-prs.sh"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$GH_LOG" ]; then pass_msg "knob unset => silent no-op"; else fail_msg "knob-unset: rc=$RC out=$OUT"; fi
  export PIPELINE_RELEASE_PR_AUTO_MERGE=true PIPELINE_RELEASE_PR_LABEL="autorelease: pending"
  export GH_RELEASE_JSON='[{"number":5,"title":"chore: release","headRefName":"r","statusCheckRollup":[{"conclusion":"SUCCESS"}]},{"number":6,"title":"chore: release 2","headRefName":"r2","statusCheckRollup":[]}]'
  run bash "$S/fullsend-release-prs.sh"
  if grep -q 'pr merge 5 .*--merge --delete-branch' "$GH_LOG"; then pass_msg "ci=pass release PR merged (--merge)"; else fail_msg "release PR 5 not merged"; fi
  if printf '%s\n' "$OUT" | grep -q 'SKIP: release PR #6 ci=pending'; then pass_msg "ci=pending release PR skipped"; else fail_msg "release skip line: $OUT"; fi
  unset PIPELINE_RELEASE_PR_AUTO_MERGE PIPELINE_RELEASE_PR_LABEL GH_RELEASE_JSON
fi

# ---------------------------------------------------------------------------
scenario "fullsend-merge-order.sh / fullsend-fetch-attachments.sh: benign empty runs"

if [ -f "$S/fullsend-merge-order.sh" ]; then
  run bash "$S/fullsend-merge-order.sh"
  if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^ORDER:'; then pass_msg "merge-order emits an ORDER: line"; else fail_msg "merge-order: rc=$RC out=$OUT"; fi
fi
if [ -f "$S/fullsend-fetch-attachments.sh" ]; then
  run bash "$S/fullsend-fetch-attachments.sh"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then pass_msg "fetch-attachments with no issues is a no-op"; else fail_msg "fetch-attachments: rc=$RC out=$OUT"; fi
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
