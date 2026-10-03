# Merge orchestration

After all evaluations complete, fullsend merges via the greenlight gate (the per-PR auto-merge loop, `## Greenlight matrix` above). Default is **autonomous merge for the green subset**.

**Pre-merge pairwise overlap scan.** Before the sequential merge loop, source `${CLAUDE_PLUGIN_ROOT}/scripts/detect-merge-overlap.sh` and run `detect_merge_overlap` over the approved-PR set to surface pairwise file overlaps; `recommend_merge_order` returns a fewest-overlap-first ordering to use for the loop. Advisory — does not block.

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/detect-merge-overlap.sh"
APPROVED=( $(gh pr list --repo "$PIPELINE_REPO" --label pr-open --json number --jq '.[].number') )
if [ "${#APPROVED[@]}" -ge 2 ]; then
  echo "=== Pre-merge pairwise overlap scan ==="
  detect_merge_overlap "${APPROVED[@]}"
  echo "=== Recommended merge order (fewest overlap first) ==="
  ORDERED=( $(recommend_merge_order "${APPROVED[@]}") )
  printf '  %s\n' "${ORDERED[@]}"
else
  ORDERED=( "${APPROVED[@]}" )
fi
```

Use `${ORDERED[@]}` as the iteration order for the sequential merge loop. Before each merge: detect the PR's base branch; if it diverges from `.claude/base-branch` (or `PIPELINE_BASE_BRANCH`), call `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE`. Check `mergeable`; on conflict, rebase in the worktree and force-push with `--force-with-lease`, retrying merge. Merge PRs sequentially to avoid cascading conflicts. Validate the PR title against the Conventional Commits format (`scripts/check-conventional-title.sh`).

**Constraints during full send:**

Slate-pre-hygiene (housekeeping, worktree cleanup, discovery) is owned by `/pipeline:status`; fullsend assumes a clean slate and does not re-implement that flow.

- Issues labeled `PIPELINE_LABELS_EXCLUDED` are always skipped.
- Issues labeled `PIPELINE_LABELS_LATER` are shown in the final report (stage = `PIPELINE_LABELS_LATER`) but not processed.
- Issues labeled `PIPELINE_LABELS_HUMAN` are shown in the final report (stage = `PIPELINE_LABELS_HUMAN`) but never processed by autonomous full send. These need a human in the loop — usually for architecture decisions, cross-platform validation, production deploy risk, or items where the planner can't make the right call without you. They must be picked up manually with `/pipeline:plan-issue` / `/pipeline:execute-issue-plan`, never via full send.
- Issues labeled `PIPELINE_LABELS_BRAINSTORM` are shown in the final report (stage = `PIPELINE_LABELS_BRAINSTORM`) but never processed by autonomous full send — same handling as `PIPELINE_LABELS_HUMAN`. The body is open-ended discussion/architectural critique, not a commit-to-act spec. Manual pickup via `/pipeline:plan-issue` is allowed once the idea crystallizes.
- Blocked issues (blocked-by dependency not yet merged) are skipped; noted in final report as "Blocked".
- The re-plan loop cap of 3 prevents infinite loops on stubborn issues.
- If any stage fails unexpectedly (script error, API failure), stop full send and report the failure with enough detail for the user to diagnose.
