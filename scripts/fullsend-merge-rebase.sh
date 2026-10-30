#!/usr/bin/env bash
# fullsend-merge-rebase.sh — fullsend merge-time rebase (#1536). Optimistic
# execute lets file-sharing issues run in the same wave; this decides, per PR at
# merge time, whether its feature branch needs a rebase onto origin/<base>, and
# performs the mechanical (conflict-free) case. Reuses
# evaluate-issue-pr-rebase-check.sh verbatim for the needed/skip decision.
# --onto <ref> [--from <sha>] (#1602): the merge loop's stack mode — rebase onto
# a sibling's tip (or un-stack a predecessor's commits); the stack decides.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: fullsend-merge-rebase.sh [--no-gh] [--onto <ref> [--from <sha>]] <worktree-dir> <PR>

Prints ONE stdout line, exit 0 on every decision:
  REBASE=skip                    no rebase needed
  REBASE=done                    rebased onto origin/<base>, pushed --force-with-lease
  REBASE=conflict FILES=<csv> HEAD=<sha>
                                 textual conflict — the helper aborted its rebase;
                                 the branch is untouched. FILES lists every
                                 conflicting path (U list + merge-tree);
                                 FILES=- when the push after a clean rebase failed
                                 HEAD = the pre-rebase branch tip
  REBASE=dirty FILES=<csv> HEAD=<sha>
                                 rebase needed but tracked files carry uncommitted
                                 changes — nothing rebased, pushed or stashed
  REBASE=error REASON=<line>     git refused to start the rebase (no rebase in
                                 progress); REASON = its first stderr line
The rebase-check diagnostic line goes to stderr. Exit 2 on usage errors or when
<worktree-dir> is the main checkout (never touched).
--no-gh: no gh call; REBASE_CHECK_VIEW_JSON defaults to MERGEABLE/CLEAN.
--onto <ref>: skip the rebase check and run `git rebase <ref>` (with --from
  <sha>: `git rebase --onto <ref> <sha>`, dropping the commits up to <sha>);
  REBASE=skip when HEAD is unchanged (no push), else push => REBASE=done.
  Conflicts are listed against <ref>. --from without --onto is a usage error.
Env: PIPELINE_REPO, PIPELINE_BASE_BRANCH, REBASE_CHECK_VIEW_JSON.
USAGE
}

NO_GH=0
ONTO=""
FROM=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --no-gh) NO_GH=1; shift ;;
    --onto|--from)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then usage >&2; exit 2; fi
      if [ "$1" = --onto ]; then ONTO="$2"; else FROM="$2"; fi
      shift 2 ;;
    *) break ;;
  esac
done
if [ -n "$FROM" ] && [ -z "$ONTO" ]; then usage >&2; exit 2; fi
if [ "$#" -ne 2 ]; then usage >&2; exit 2; fi
WT="$1"
PR="$2"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
BASE="${PIPELINE_BASE_BRANCH:?PIPELINE_BASE_BRANCH unset}"

GIT_DIR_ABS=$(git -C "$WT" rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
  echo "fullsend-merge-rebase: $WT is not a git checkout" >&2; exit 2; }
COMMON_DIR_ABS=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir)
if [ "$GIT_DIR_ABS" = "$COMMON_DIR_ABS" ]; then
  echo "fullsend-merge-rebase: refusing: $WT is the main checkout" >&2
  exit 2
fi

if [ "$NO_GH" = 1 ]; then
  CLEAN_VIEW='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
  export REBASE_CHECK_VIEW_JSON="${REBASE_CHECK_VIEW_JSON:-$CLEAN_VIEW}"
fi

# --onto: the stack decides, so the mergeability-against-base check is skipped.
if [ -z "$ONTO" ]; then
  # Name held in a variable so the path never reads as a bare slash command
  # (tests/test-plan-issue-namespace.sh).
  REBASE_CHECK_SH=evaluate-issue-pr-rebase-check.sh
  CHECK=$(cd "$WT" && bash "$SELF_DIR/$REBASE_CHECK_SH" "$PR")
  echo "$CHECK" >&2
  DECISION=$(printf '%s\n' "$CHECK" | sed -n 's/.*REBASE=\([a-z]*\).*/\1/p' | tail -1)

  if [ "$DECISION" = skip ]; then
    echo "REBASE=skip"
    exit 0
  fi
fi
UPSTREAM="${ONTO:-origin/$BASE}"
if [ -n "$FROM" ]; then
  RB_ARGS=(--onto "$ONTO" "$FROM")
else
  RB_ARGS=("$UPSTREAM")
fi

# A tracked file with uncommitted edits makes git refuse the rebase outright;
# report it instead of a phantom conflict. Untracked files never block a rebase.
# No autostash: the dirty branch is left exactly as found.
DIRTY=$(git -C "$WT" status --porcelain --untracked-files=no)
if [ -n "$DIRTY" ]; then
  DIRTY_CSV=$(printf '%s\n' "$DIRTY" | cut -c4- | sed 's/.* -> //' | paste -sd, -)
  echo "REBASE=dirty FILES=$DIRTY_CSV HEAD=$(git -C "$WT" rev-parse HEAD)"
  exit 0
fi

OLD_HEAD=$(git -C "$WT" rev-parse HEAD)
RB_ERR=$(mktemp)
trap 'rm -f "$RB_ERR"' EXIT
RB_RC=0
git -C "$WT" rebase "${RB_ARGS[@]}" >&2 2>"$RB_ERR" || RB_RC=$?
cat "$RB_ERR" >&2
if [ "$RB_RC" -eq 0 ]; then
  # --onto: a branch already on the ref is left as is (no push).
  if [ -n "$ONTO" ] && [ "$(git -C "$WT" rev-parse HEAD)" = "$OLD_HEAD" ]; then
    echo "REBASE=skip"
    exit 0
  fi
  if git -C "$WT" push --force-with-lease origin HEAD >&2; then
    echo "REBASE=done"
  else
    echo "fullsend-merge-rebase: push failed after a clean rebase" >&2
    echo "REBASE=conflict FILES=- HEAD=$OLD_HEAD"
  fi
  exit 0
fi

# git refused to start the rebase (no REBASE_HEAD, no rebase state dir): nothing
# to abort and no conflict to list — report the refusal and leave the branch.
if ! git -C "$WT" rev-parse -q --verify REBASE_HEAD >/dev/null \
   && [ ! -d "$GIT_DIR_ABS/rebase-merge" ] && [ ! -d "$GIT_DIR_ABS/rebase-apply" ]; then
  REASON=$(sed '/^[[:space:]]*$/d' "$RB_ERR" | head -1)
  echo "REBASE=error REASON=${REASON:-unknown}"
  exit 0
fi

# The rebase stops on the FIRST conflicting commit, so its U list can miss paths
# a later commit conflicts on. After the abort (HEAD restored — mid-rebase HEAD
# is a partial replay) a tip-vs-tip merge-tree lists the rest; the union keeps
# the list never narrower than the U list. merge-tree rc 0/1 = usable (git
# >= 2.38); any other rc falls back to the U list alone.
U_LIST=$(git -C "$WT" diff --name-only --diff-filter=U)
git -C "$WT" rebase --abort >&2
MT_LIST=""
MT_OUT=$(git -C "$WT" merge-tree --write-tree --name-only --no-messages "$UPSTREAM" HEAD 2>/dev/null)
MT_RC=$?
if [ "$MT_RC" -eq 0 ] || [ "$MT_RC" -eq 1 ]; then
  MT_LIST=$(printf '%s\n' "$MT_OUT" | tail -n +2)
fi
FILES=$(printf '%s\n%s\n' "$U_LIST" "$MT_LIST" | sed '/^$/d' | sort -u | paste -sd, -)
echo "REBASE=conflict FILES=${FILES:--} HEAD=$OLD_HEAD"
exit 0
