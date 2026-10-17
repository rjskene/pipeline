# shellcheck shell=bash
# _fullsend-resolve-pr.sh — sourced by scripts/fullsend-*.sh. Defines:
#
#   fullsend_resolve_pr <N>   sets WT, BR, PR_NUM for issue <N>
#
# Derivation: worktree glob .claude/worktrees/${PIPELINE_WORKTREE_PREFIX:-wt}-<N>-*
# under ${PIPELINE_PROJECT_ROOT:-$(pwd)} -> that worktree's branch ->
# `gh pr list --head <branch>`. Never recalled from orchestrator context.
#
# FAIL-CLOSED: the two `[ -n … ]` tests are the guards, not the commands' exit
# statuses. `git -C "" branch --show-current` exits 0 printing the CALLER's own
# branch, and `gh pr list --head ""` exits 0 returning the repo's newest open PR,
# so an empty WT or BR would otherwise name an unrelated PR. Empty WT => empty BR
# => empty PR_NUM; callers turn an empty PR_NUM into a visible block-* line.
#
# No top-level side effects — function definition only.

# shellcheck disable=SC2034  # WT/BR/PR_NUM are this function's outputs
fullsend_resolve_pr() {
  local wt_root="${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/worktrees"
  WT=$(ls -d "$wt_root/${PIPELINE_WORKTREE_PREFIX:-wt}-$1-"* 2>/dev/null | head -1)
  BR=$([ -n "$WT" ] && git -C "$WT" branch --show-current)
  PR_NUM=$([ -n "$BR" ] && gh pr list --repo "$PIPELINE_REPO" --head "$BR" --json number --jq '.[0].number')
  return 0
}
