# Step 7 — merge orchestration detail

This file holds the verbose detail for Step 7 of `/pipeline:run` (per-PR auto-merge loop, conventional-title pre-validation, base-branch retarget, conflict rebase, sequential merge gating). SKILL.md keeps the auto-merge-gate invocation + footer string + `Auto-merged?` report column inline because `tests/test-run-skill-auto-merge-default.sh` greps for them; the surrounding walkthrough lives here.

## Greenlight gate — four conditions

The default behavior is **autonomous merge for the green subset** via the greenlight gate (`${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh`). All four conditions must hold; any one missing falls back to a `block-*` reason and requires manual `gh pr merge`:

1. Latest `## Evaluation` verdict is **Approved**.
2. Every `statusCheckRollup` entry has `conclusion == SUCCESS` (or the rollup is empty for repos with no CI configured).
3. `mergeable == MERGEABLE`.
4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

## Per-PR auto-merge loop

For each PR labelled `pr-open`:

### 1. Already-merged short-circuit

Check the latest `## Evaluation` PR comment body for the exact footer prefix `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at` (written by `evaluate-issue-pr` Step 11 on the green path). If present, mark the row `Auto-merged? = yes (eval)` in the report and skip this PR — it is already merged and closed.

### 2. Run the gate

Source the helper and call it:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
```

### 3. On `green`

Run the conventional-title pre-validation (see below), then merge synchronously here (NOT `--auto`):

```bash
gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch
SHA=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json mergeCommit --jq .mergeCommit.oid)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FOOTER="Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at ${TS}"
gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" --add-label "merged" --remove-label "pr-open"
if [ -n "$SHA" ]; then
  gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM} (${SHA}). ${FOOTER}"
else
  gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM}. ${FOOTER}"
fi
```

Mark the row `Auto-merged? = yes (step8)`.

### 4. On any `block-*` reason

Mark the row `Auto-merged? = no (${REASON})` and leave the PR for manual merge by the user. Do NOT flip labels. Do NOT close the issue.

## Release-please scope

Release-please PRs are out of scope here — they continue to flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b of the run skill, unchanged.

## Opt-outs

The three greenlight opt-outs:

- `FULL SEND --manual-merge` (token may appear anywhere in argv — before, between, or after issue numbers).
- `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations.
- A `manual-merge` label on the issue, for per-issue control without re-typing the flag.

## Conventional-title pre-validation

Runs before any merge call regardless of the auto/manual path. It is informational at the batch level and enforced per-PR in the sequential-merge step below.

```bash
# Uses canonical regex from scripts/check-conventional-title.sh — see Issue #45.
source $CLAUDE_PLUGIN_ROOT/scripts/check-conventional-title.sh
echo "=== Pre-merge PR title validation ==="
for PR_NUM in $(gh pr list --repo $PIPELINE_REPO --state open --json number --jq '.[].number'); do
  PR_TITLE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json title --jq '.title')
  if ! check_conventional_title "$PR_TITLE"; then
    echo "  ⚠ PR #$PR_NUM: $PR_TITLE"
  else
    echo "  ✓ PR #$PR_NUM: $PR_TITLE"
  fi
done
```

## Pre-merge pairwise overlap scan

Before entering the sequential merge loop, scan the approved-PR set for changed-file overlap. Overlapping pairs are the leading indicator of rebase-cascade conflicts (the original symptom in #48).

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

Use `${ORDERED[@]}` as the iteration order for the sequential merge loop below. The scan is **advisory** — it does NOT block merges; the auto-rebase + `--force-with-lease` retry below still handles actual conflicts. Its job is to (a) pre-empt the rebase cascade by merging the least-overlapping PRs first and (b) give the orchestrator visibility into which pairs are likely to need rebase. For PR pairs with high overlap (e.g. both editing the same skill example block), the orchestrator may also recommend pre-rebasing or merging them together as one PR before kicking off the loop.

## Sequential merge with base-branch retarget + conflict rebase

1. For each approved PR, detect its base branch:
   ```bash
   gh pr view $PR_NUM --repo $PIPELINE_REPO --json baseRefName --jq '.baseRefName'
   ```

1b. Verify and retarget if needed — compare the PR's current base with the expected base from the worktree metadata:
   ```bash
   EXPECTED_BASE=$(cat <worktree-path>/.claude/base-branch 2>/dev/null || echo "$PIPELINE_BASE_BRANCH")
   ACTUAL_BASE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json baseRefName --jq '.baseRefName')
   if [ "$ACTUAL_BASE" != "$EXPECTED_BASE" ]; then
     PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE
   fi
   ```
   If `retarget-pr.sh` exits non-zero, stop the merge sequence and report the failure.

2. Check for merge conflicts:
   ```bash
   gh pr view $PR_NUM --repo $PIPELINE_REPO --json mergeable --jq '.mergeable'
   ```

3. If conflicts exist, attempt rebase in the worktree:
   ```bash
   cd <worktree-path>
   BASE_BRANCH=$(cat .claude/base-branch 2>/dev/null || echo "$PIPELINE_BASE_BRANCH")
   git fetch origin "$BASE_BRANCH"
   git rebase "origin/$BASE_BRANCH"
   ```
   - If rebase succeeds: run tests, force-push with `--force-with-lease`, retry merge
   - If conflicts are complex: abort rebase, flag for user review, skip this PR

4. Merge PRs sequentially to avoid cascading conflicts. Before each merge, validate the PR title against the Conventional Commits format — release-please reads the merge-commit subject on merge, so a non-conforming title breaks automated versioning and CHANGELOG generation.

   ```bash
   # Validate PR title against Conventional Commits format.
   # Uses canonical regex from scripts/check-conventional-title.sh — see Issue #45.
   source $CLAUDE_PLUGIN_ROOT/scripts/check-conventional-title.sh
   PR_TITLE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json title --jq '.title')
   if ! check_conventional_title "$PR_TITLE"; then
     echo "⚠ PR #$PR_NUM title does not match conventional commit format: $PR_TITLE"
     echo "  Expected: type(scope): description  (e.g. feat(web): add modal component)"
     # Propose a reword based on the issue title/body, then apply with:
     # gh pr edit $PR_NUM --repo $PIPELINE_REPO --title "<type>(<scope>): <summary>"
   fi
   ```

   - **Interactive mode:** if validation fails, print the warning, propose a reword derived from the PR's issue title/body, and ask the user to confirm or provide an alternative. If the user confirms (or supplies one), apply via `gh pr edit $PR_NUM --repo $PIPELINE_REPO --title "..."` and proceed. If the user declines, skip the merge for this PR and flag it in the final report.
   - **Full send (autonomous mode):** auto-propose a reword from the PR's issue title/body, apply it with `gh pr edit`, and proceed without blocking. If a valid reword cannot be determined, skip the PR and flag it in the final report.

   Once the title passes validation, run the merge:
   ```bash
   gh pr merge $PR_NUM --repo $PIPELINE_REPO --merge --delete-branch
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "merged" --remove-label "pr-open"
   gh issue close <N> --repo $PIPELINE_REPO
   ```

5. If a merge fails, stop and report the failure. Do not continue merging remaining PRs (they may depend on the failed one).
