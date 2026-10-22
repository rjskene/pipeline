#!/usr/bin/env bash
# fullsend-merge-loop.sh — fullsend Step 7 merge loop, ONE call per wave.
#
# Composes the existing helpers in one process so the orchestrator spends one
# turn per wave instead of one per helper call: PR derivation (fail-closed) ->
# merge order (fewest-overlap-first) -> per PR: fullsend-merge-rebase.sh ->
# auto_merge_should_fire -> fullsend-merge-green.sh / fullsend-block-merge.sh.
# Every outcome the loop cannot settle itself (a rebase conflict or a dirty
# worktree) is handed back as a LOOP: line; the orchestrator re-enters per
# skills/fullsend/references/auto-merge-gate.md `### Re-entry`.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-merge-loop.sh <N>...

For the wave's issues whose evaluator returned: derive worktree -> branch -> PR
(fail-closed), order the PRs fewest-overlap-first, then per PR run
fullsend-merge-rebase.sh -> the gate (auto_merge_should_fire) ->
fullsend-merge-green.sh or fullsend-block-merge.sh. Prints, on stdout:
  ORDER: <pr> <pr> ...
  the relayed MERGE: / BLOCK: lines
  LOOP: issue=#<N> pr=#<P> outcome=<outcome>   (one per issue)
  LOOP: log=<path>   (stderr log under .claude/scratch/merge-loop/; precedes the trailer)
  LOOP: done | LOOP: pending issues=<csv>      (trailer)
Outcomes: merged sha=<sha>, already-merged, needs-fix files=<csv> head=<sha>
[reason=dirty], block-ci, deferred, block-rebase-error, or the routed block-* token. pending = needs-fix + block-ci +
deferred. A block-mergestate/block-mergeable token is re-gated until it
settles, then deferred (counter .claude/scratch/merge-loop/<P>.deferred) up to
DEFER_MAX re-entries before it is routed. Exit 0 always; exit 2 with no issue
argument.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, PIPELINE_PROJECT_ROOT,
PIPELINE_WORKTREE_PREFIX, MANUAL_MERGE, PIPELINE_MERGE_LOOP_CI_WAIT_SECS (300),
PIPELINE_MERGE_LOOP_WALL_SECS (540), PIPELINE_MERGE_LOOP_CI_RERUN (1),
PIPELINE_MERGE_LOOP_DEFER_MAX (3), PIPELINE_MERGEABILITY_POLL_SECS/_MAX.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 1 ] || { usage >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
# Diagnostic log: stderr is tee'd to a per-run scratch file (named on the
# LOOP: log= line) so the caller can read what the loop saw. Opened after the
# config source so PIPELINE_PROJECT_ROOT from pipeline.config applies.
DEFER_DIR="${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/merge-loop"
mkdir -p "$DEFER_DIR"
LOG_FILE="$DEFER_DIR/$(date -u +%Y%m%dT%H%M%SZ).log"
exec 3>&2
exec 2> >(tee -a "$LOG_FILE" >&3)
TEE_PID=$!
# shellcheck source=scripts/_fullsend-resolve-pr.sh
source "$SELF_DIR/_fullsend-resolve-pr.sh"
# shellcheck source=scripts/detect-merge-overlap.sh
source "$SELF_DIR/detect-merge-overlap.sh"
# shellcheck source=scripts/check-conventional-title.sh
source "$SELF_DIR/check-conventional-title.sh"

source "$SELF_DIR/auto-merge-gate.sh"
CR_LINE=$(bash "$SELF_DIR/check-capability-refusal.sh" --resolve-sources)
CR_STATE=${CR_LINE%% *}; CR_STATE=${CR_STATE#SOURCES=}
case "$CR_STATE" in
  resolved)                     export PIPELINE_CAPABILITY_REFUSAL_SOURCES="${CR_LINE##*DIR=}" ;;
  no-log-dir|unresolvable-root) echo "NOTE: capability arm skipped/DORMANT: $CR_LINE" >&2 ;;
esac

CI_WAIT="${PIPELINE_MERGE_LOOP_CI_WAIT_SECS:-300}"
WALL="${PIPELINE_MERGE_LOOP_WALL_SECS:-540}"
CI_RERUN="${PIPELINE_MERGE_LOOP_CI_RERUN:-1}"
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)

# rollup_snapshot <P> — statusCheckRollup (the gate's own source, so the
# settle and the gate cannot disagree) as a compact [name, status, url] list;
# the run URL is per-head, so a new head's checks differ from the old ones.
# StatusContext entries fall back to context/state/targetUrl; garbage => [].
rollup_snapshot() {
  local s
  s=$(gh pr view "$1" --repo "$PIPELINE_REPO" --json statusCheckRollup 2>/dev/null \
    | jq -c '.statusCheckRollup | map([(.name // .context), (.status // .state), (.detailsUrl // .targetUrl)])' 2>/dev/null)
  case "$s" in '['*) ;; *) s='[]' ;; esac
  echo "$s"
}
# settle_registration <P> — after a rebase push, wait (bounded) for the pushed
# head's checks when the PR had checks before ($PRE): the rollup still equal
# to the pre-push snapshot ($PRE_SNAP) is the old head's, and an empty rollup
# reads green.
settle_registration() {
  local reads=0 cur
  while [ "$PRE" -gt 0 ] && [ "$reads" -lt "${PIPELINE_MERGEABILITY_POLL_MAX:-12}" ]; do
    cur=$(rollup_snapshot "$1")
    [ "$cur" = "$PRE_SNAP" ] || [ "$cur" = '[]' ] || break
    sleep "${PIPELINE_MERGEABILITY_POLL_SECS:-5}"; reads=$((reads + 1))
  done
}
# wall_ok — one more CI wait still returns before the wall budget.
wall_ok() { [ $((SECONDS + CI_WAIT)) -le "$WALL" ]; }
# ci_wait <P> — bounded watch, output relayed to stderr; rc 3 when gh saw no
# checks yet (`no checks reported`), rc 4 when the watch timed out, else 0
# (the gate decides). LAST_CW keeps the rc for the post-watch settle.
ci_wait() {
  local out rc=0
  if [ -n "$TIMEOUT_BIN" ]; then
    out=$("$TIMEOUT_BIN" "$CI_WAIT" gh pr checks "$1" --repo "$PIPELINE_REPO" --watch --interval 10 2>&1) || rc=$?
  else
    out=$(gh pr checks "$1" --repo "$PIPELINE_REPO" 2>&1)
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  case "$out" in *"no checks reported"*) LAST_CW=3; return 3 ;; esac
  [ "$rc" -eq 124 ] && { LAST_CW=4; return 4; }
  LAST_CW=0; return 0
}
# ci_class <P> — failed | pending (check-ci-fix-loop.sh's state mapping).
ci_class() {
  gh pr checks "$1" --repo "$PIPELINE_REPO" --json state,link 2>/dev/null \
    | jq -r 'if any(.[]; .state == "FAILURE" or .state == "CANCELLED" or .state == "TIMED_OUT" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE") then "failed" else "pending" end' 2>/dev/null \
    || echo pending
}
# settle_ci — a COMPLETED watch can still read block-ci while the rollup lags:
# re-gate (bounded by POLL_MAX and the wall) while REASON stays block-ci and
# the checks read pending. Settle reads spend no wait and start no watch.
settle_ci() {
  local reads=0
  while [ "$REASON" = block-ci ] && [ "$(ci_class "$PR_NUM")" = pending ] \
    && [ "$reads" -lt "${PIPELINE_MERGEABILITY_POLL_MAX:-12}" ] \
    && [ $((SECONDS + ${PIPELINE_MERGEABILITY_POLL_SECS:-5})) -le "$WALL" ]; do
    sleep "${PIPELINE_MERGEABILITY_POLL_SECS:-5}"; reads=$((reads + 1))
    REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
  done
}

PENDING=()
loop_line() { echo "LOOP: issue=#$1 pr=#$2 outcome=$3"; }

# Pre-pass, argv order: closed issues (re-entry), PR derivation, PR->issue map.
declare -A ISSUE_OF=() PR_OF=() WT_OF=()
PRS=()
for N in "$@"; do
  STATE=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json state --jq .state 2>/dev/null)
  if [ "$STATE" = CLOSED ]; then
    CWT=$(ls -d "${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/worktrees/${PIPELINE_WORKTREE_PREFIX:-wt}-$N-"* 2>/dev/null | head -1)
    CBR=$([ -n "$CWT" ] && git -C "$CWT" branch --show-current)
    MPR=$([ -n "$CBR" ] && gh pr list --repo "$PIPELINE_REPO" --head "$CBR" --state merged --json number --jq '.[0].number')
    loop_line "$N" "${MPR:-none}" already-merged
    continue
  fi
  fullsend_resolve_pr "$N"
  if [ -z "$PR_NUM" ]; then
    bash "$SELF_DIR/fullsend-block-merge.sh" "$N:block-no-pr"
    loop_line "$N" none block-no-pr
    continue
  fi
  ISSUE_OF[$PR_NUM]="$N"; PR_OF[$N]="$PR_NUM"; WT_OF[$N]="$WT"
  PRS+=("$PR_NUM")
done

# Order (advisory overlap scan to stderr; never blocks).
PR_ORDER=("${PRS[@]}")
if [ "${#PRS[@]}" -ge 2 ]; then
  detect_merge_overlap "${PRS[@]}" >&2
  # shellcheck disable=SC2207  # PR numbers: word-splitting is the intent
  PR_ORDER=( $(recommend_merge_order "${PRS[@]}") )
fi
echo "ORDER: ${PR_ORDER[*]}"
# ORDERED holds ISSUE numbers in PR merge order (the per-issue maps key on N).
ORDERED=()
for P in "${PR_ORDER[@]}"; do ORDERED+=("${ISSUE_OF[$P]}"); done

# route_block <N> <P> <token> — comment + manual-merge label, relay BLOCK:.
route_block() {
  bash "$SELF_DIR/fullsend-block-merge.sh" "$1:$3"
  loop_line "$1" "$2" "$3"
}
# defer_or_route <N> <P> <token> — an unsettled merge-state token defers the
# PR (per-PR counter, removed on merge) until DEFER_MAX re-entries, then routes.
defer_or_route() {
  local f="$DEFER_DIR/$2.deferred" c
  mkdir -p "$DEFER_DIR"
  c=$(cat "$f" 2>/dev/null); case "$c" in ''|*[!0-9]*) c=0 ;; esac
  if [ "$c" -ge "${PIPELINE_MERGE_LOOP_DEFER_MAX:-3}" ]; then
    route_block "$1" "$2" "$3"; return
  fi
  echo $((c + 1)) > "$f"
  loop_line "$1" "$2" deferred; PENDING+=("$1")
}
is_mergestate() { case "$1" in block-mergestate|block-mergeable) return 0 ;; esac; return 1; }

for N in "${ORDERED[@]}"; do
  ISSUE="$N"; PR_NUM="${PR_OF[$N]}"; WT="${WT_OF[$N]}"
  TITLE=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json title --jq .title 2>/dev/null)
  check_conventional_title "$TITLE" || echo "TITLE: pr=#$PR_NUM non-conventional" >&2

  if ! wall_ok; then
    loop_line "$N" "$PR_NUM" deferred; PENDING+=("$N"); continue
  fi
  WAITS=0; LAST_CW=-1
  if [ "${MANUAL_MERGE:-}" != 1 ]; then
    PRE_SNAP=$(rollup_snapshot "$PR_NUM")
    PRE=$(jq length <<<"$PRE_SNAP" 2>/dev/null); case "$PRE" in ''|*[!0-9]*) PRE=0 ;; esac
    RB=$(bash "$SELF_DIR/fullsend-merge-rebase.sh" "$WT" "$PR_NUM" | tail -1)
    # The helper's final REBASE= line goes to stdout; relay it to the log.
    echo "REBASE: pr=#$PR_NUM $RB" >&2
    case "$RB" in
      "REBASE=conflict"*)
        RB_FILES=${RB#*FILES=}; RB_FILES=${RB_FILES%% *}
        RB_HEAD=-; case "$RB" in *" HEAD="*) RB_HEAD=${RB##*HEAD=} ;; esac
        # Per-PR conflict record (removed on merge): one line per rebase-fix.
        CF="$DEFER_DIR/$PR_NUM.conflicts"
        K=$(grep -c . "$CF" 2>/dev/null); case "$K" in ''|*[!0-9]*) K=0 ;; esac
        echo "files=$RB_FILES head=$RB_HEAD" >> "$CF"
        loop_line "$N" "$PR_NUM" "needs-fix files=$RB_FILES head=$RB_HEAD attempt=$((K + 1))"
        PENDING+=("$N"); continue ;;
      "REBASE=dirty"*)
        RB_FILES=${RB#*FILES=}; RB_FILES=${RB_FILES%% *}
        RB_HEAD=-; case "$RB" in *" HEAD="*) RB_HEAD=${RB##*HEAD=} ;; esac
        loop_line "$N" "$PR_NUM" "needs-fix files=$RB_FILES head=$RB_HEAD reason=dirty"
        PENDING+=("$N"); continue ;;
      "REBASE=error"*)
        route_block "$N" "$PR_NUM" block-rebase-error; continue ;;
      "REBASE=done")
        # Registration settle, then wait. A watch that saw no checks is not a
        # wait: re-settle and re-watch once (bounded by the wall). A timed-out
        # watch (rc 4) is still a spent wait.
        settle_registration "$PR_NUM"; ci_wait "$PR_NUM"; CW=$?
        if [ "$CW" -eq 3 ] && [ "$PRE" -gt 0 ]; then
          if ! wall_ok; then
            loop_line "$N" "$PR_NUM" deferred; PENDING+=("$N"); continue
          fi
          settle_registration "$PR_NUM"; ci_wait "$PR_NUM"; CW=$?
        fi
        case "$CW" in 0|4) WAITS=1 ;; esac ;;
    esac
  fi

  REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
  # Post-watch settle: only after a COMPLETED watch (rc 0).
  [ "$LAST_CW" -eq 0 ] && settle_ci
  # block-ci, bounded (waits per PR <= 1 + reruns): pending with no wait yet
  # => ONE wait + re-gate; failed with rerun budget left => rerun the failed
  # jobs of the RUN (never the trailing job id), one wait, re-gate.
  RERUNS=0; DEFER=0
  while [ "$REASON" = block-ci ]; do
    if [ "$(ci_class "$PR_NUM")" = failed ]; then
      [ "$RERUNS" -lt "$CI_RERUN" ] || break
      RUN_ID=$(gh pr checks "$PR_NUM" --repo "$PIPELINE_REPO" --json state,link 2>/dev/null \
        | jq -r '.[] | select(.state == "FAILURE" or .state == "CANCELLED" or .state == "TIMED_OUT" or .state == "ACTION_REQUIRED" or .state == "STARTUP_FAILURE") | .link' 2>/dev/null \
        | grep -oE 'runs/[0-9]+' | head -1 | cut -d/ -f2)
      [ -n "$RUN_ID" ] || break
      wall_ok || { DEFER=1; break; }
      gh run rerun "$RUN_ID" --repo "$PIPELINE_REPO" --failed >&2; RERUNS=$((RERUNS + 1))
    else
      [ "$WAITS" -eq 0 ] || break
      wall_ok || { DEFER=1; break; }
    fi
    ci_wait "$PR_NUM"; WAITS=$((WAITS + 1))
    REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
    [ "$LAST_CW" -eq 0 ] && settle_ci
  done
  if [ "$DEFER" = 1 ]; then
    loop_line "$N" "$PR_NUM" deferred; PENDING+=("$N"); continue
  fi
  # Merge-state settle: mergeStateStatus lags a sibling merge / push; re-gate
  # (bounded by POLL_MAX and the wall) while the token stays merge-state.
  if is_mergestate "$REASON"; then
    reads=0
    while is_mergestate "$REASON" && [ "$reads" -lt "${PIPELINE_MERGEABILITY_POLL_MAX:-12}" ] \
      && [ $((SECONDS + ${PIPELINE_MERGEABILITY_POLL_SECS:-5})) -le "$WALL" ]; do
      sleep "${PIPELINE_MERGEABILITY_POLL_SECS:-5}"; reads=$((reads + 1))
      REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
    done
    if is_mergestate "$REASON"; then defer_or_route "$N" "$PR_NUM" "$REASON"; continue; fi
  fi
  if [ "$REASON" = block-ci ]; then
    # Step 6b owns repair: no label, no comment.
    loop_line "$N" "$PR_NUM" block-ci; PENDING+=("$N"); continue
  fi

  if [ "$REASON" = green ]; then
    MOUT=$(bash "$SELF_DIR/fullsend-merge-green.sh" "$N"); MRC=$?
    [ -n "$MOUT" ] && printf '%s\n' "$MOUT"
    MLINE=$(printf '%s\n' "$MOUT" | grep '^MERGE: ' | tail -1)
    MREASON=$(printf '%s\n' "$MLINE" | sed -n 's/.* reason=\([^ ]*\).*/\1/p')
    case "$MREASON" in
      green)
        [ "$MRC" -eq 0 ] || echo "WARN: issue #$N merged but fullsend-merge-green.sh exited $MRC (issue close)" >&2
        rm -f "$DEFER_DIR/$PR_NUM.deferred"
        rm -f "$DEFER_DIR/$PR_NUM.conflicts"
        loop_line "$N" "$PR_NUM" "merged sha=${MLINE##*sha=}" ;;
      block-ci) loop_line "$N" "$PR_NUM" block-ci; PENDING+=("$N") ;;
      block-mergestate|block-mergeable) defer_or_route "$N" "$PR_NUM" "$MREASON" ;;
      *) route_block "$N" "$PR_NUM" "${MREASON:-block-merge-failed}" ;;
    esac
  else
    route_block "$N" "$PR_NUM" "$REASON"
  fi
done

echo "LOOP: log=$LOG_FILE"
if [ "${#PENDING[@]}" -gt 0 ]; then
  echo "LOOP: pending issues=$(IFS=,; echo "${PENDING[*]}")"
else
  echo "LOOP: done"
fi
# Restore stderr and wait for tee so the log is flushed when the caller reads it.
exec 2>&3 3>&-
wait "$TEE_PID" 2>/dev/null
exit 0
