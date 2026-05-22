# Tracker filter and audit-only notes

## Why this exists

Tracker issues (label: `tracker`) are coordination artifacts that roll up child issues for visibility, not implementation work. The orchestrator excludes them from the action queue (never proposed for plan/execute) but surfaces them in the status table with `stage=tracker`. The filter block below partitions the issue list into `READY_ISSUES` (no pipeline-stage label AND no `tracker`/excluded/later/human label) and `TRACKER_ISSUES` (carry `tracker`). Assume `ISSUE_LIST_JSON` holds the output of `gh issue list ... --json number,title,labels --limit 100`.

The block is wrapped by `# BEGIN-TRACKER-FILTER` / `# END-TRACKER-FILTER` sentinel comments. `tests/test-tracker-filter.sh` extracts the block, stubs `gh`, runs the bash logic against a fixture payload, and asserts the partition is correct. Do not rephrase or restructure the block without rewriting that test.

## The filter block

```bash
# BEGIN-TRACKER-FILTER
# Required env: ISSUE_LIST_JSON (output of `gh issue list ... --json number,title,labels`).
# Emits: READY_ISSUES (space-separated numbers), TRACKER_ISSUES (space-separated numbers).
STAGE_LABELS='plan-pending|plan-reviewed|plan-approved|in-progress|pr-open|merged'
SKIP_LABELS="tracker|$PIPELINE_LABELS_EXCLUDED|$PIPELINE_LABELS_LATER|$PIPELINE_LABELS_HUMAN|$PIPELINE_LABELS_BRAINSTORM"
READY_ISSUES=$(echo "$ISSUE_LIST_JSON" | jq -r --arg stage "$STAGE_LABELS" --arg skip "$SKIP_LABELS" '
  .[] | select(
    ([.labels[].name] | any(test("^(" + $stage + ")$"))) | not
  ) | select(
    ([.labels[].name] | any(test("^(" + $skip  + ")$"))) | not
  ) | .number
' | tr '\n' ' ')
TRACKER_ISSUES=$(echo "$ISSUE_LIST_JSON" | jq -r '
  .[] | select([.labels[].name] | any(. == "tracker")) | .number
' | tr '\n' ' ')
# END-TRACKER-FILTER
```

`READY_ISSUES` feeds the planning proposal in Step 4 of `/pipeline:run`. `TRACKER_ISSUES` feeds the status-table render in Step 3 — those issues are displayed with `Stage=tracker` and never reach the classify/plan dispatch.

Classification is deferred — see Step 6 (Propose ONE action → planning branch) for the cache-checked dispatch that runs only on the user-committed slate.

## Audit-only signals

These two signals are surfaced in the final report but do NOT block any dispatch — the user is the decision maker.

**Detect residual mismatch (audit only).** For each `ready` issue with a fresh classification, compare the cached `## Classification` comment's `recommended_path` against the current label-derived path (`A` if labeled `docs-only`, `C` if labeled `multi-task`, else `B`). They should match — classify-issue writes them together. If they diverge, it means a user hand-edited a label after the last classify run; flag as `⚠ mismatch` and include in the final report column. Do NOT block planning on a mismatch: the label is authoritative, the comment is history.

**Detect cleanup candidates.** Cross-reference active worktrees (from `git worktree list`) with merged PRs. A worktree whose branch appears in the merged PR list is a cleanup candidate. Also check for `pr-open` issues whose PR has been merged (state = MERGED) — these need cleanup too.
