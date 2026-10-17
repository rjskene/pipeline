# Auto-merge gate — the orchestrator's post-evaluation merge procedure

Read this from `skills/fullsend/SKILL.md` Step 7, on any token the gate returns.

**Owner: the ORCHESTRATOR.** The evaluator posts its `## Evaluation` verdict and stops. `scripts/auto-merge-gate.sh` (`auto_merge_should_fire`) emits ONE TOKEN and performs no action; every `gh` write lives in the `scripts/fullsend-*.sh` helpers below.

**Greenlight matrix — all 4 must hold** (otherwise the PR is left for manual merge with a `block-*` reason):
1. Latest `## Evaluation` comment contains `**Verdict:** Approved`.
2. Every `statusCheckRollup` entry has `conclusion == SUCCESS` (an empty rollup passes for repos with no CI).
3. `mergeable == MERGEABLE`.
4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

Base-branch enforcement is layered: the gate's `baseRefName` assertion (`block-base-mismatch`), a TOCTOU re-read before `gh pr merge`, the quoted `--base` in `execute-issue-plan` Step 9b, and the `enforce-base-branch.py` hook. The eval-time gate is the load-bearing layer.

1. **Flag parsing.** `--manual-merge` may appear anywhere in argv; `MANUAL_MERGE=1` (exported by `spawn-claude.sh --manual-merge`) is equivalent. Either ⇒ skip the gate, Approved-but-not-merged.

2. **Run the gate** — `scripts/fullsend-gate.sh <N>...` (one call per wave). It sources the helper, then `check-capability-refusal.sh --resolve-sources` resolves the MAIN checkout's log dir (a worktree has no `.claude/logs/`) and threads `PIPELINE_CAPABILITY_REFUSAL_SOURCES` before calling `auto_merge_should_fire` per issue. Tokens: `resolved` (export the knob), `no-log-dir` / `unresolvable-root` (knob left unexported, fail-open, NOTE on stderr). Each issue's PR is DERIVED (worktree glob → branch → `gh pr list --head`), never recalled; the `[ -n ]` guards fail closed, since `git -C ""` and `gh pr list --head ""` exit 0 naming an unrelated branch/PR. An empty PR yields a `block-*` token — a visible `GATE:` line, never a silent skip.
   Checks in order: `MANUAL_MERGE` env, `manual-merge` label, the 4 greenlight conditions, capability-refusal, `baseRefName == $PIPELINE_BASE_BRANCH`. Prints exactly one token: `green`, `block-flag`, `block-label`, `block-cage-tests-diff`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-ci`, `block-mergeable`, or `block-mergestate`. A stderr `NOTE: capability-refusal arm skipped (REASON=async-dispatch …)` is expected for background dispatches, not a WARN.

   pr-eval depth is never gated: the dispatch carries `model=` from `resolve-stage-model.sh <N> pr-eval` (`PIPELINE_STAGE_MODEL_PR_EVAL`, unset ⇒ `opus`).

3. **On `green`:** ONE wave call over the greenlit issues (bound from the Step 7 `GATE:` lines):
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-merge-green.sh" <issues whose GATE line read reason=green>
   ```
   It prints one `MERGE: issue=#<N> pr=#<P> reason=<green|block-base-mismatch|block-no-pr|block-merge-failed> [sha=<sha>]` line per issue. Its order is load-bearing:
   - **TOCTOU re-check** — re-read `baseRefName` right before the merge; a mismatch emits `block-base-mismatch` and never calls `gh pr merge`.
   - Merge synchronously (NOT `--auto`) with `--merge --delete-branch`, guarded: a failed merge (stale `mergeStateStatus` after an earlier merge in the batch) emits `block-merge-failed`.
   - Capture the merge-commit SHA (empty on API lag ⇒ omitted from the close comment).
   - Rewrite the eval comment's branch-pinned screenshot URLs (public `raw.githubusercontent.com` and private `blob` forms) to the merge SHA — after the SHA capture, before the footer; fail-soft. `PIPELINE_SCREENSHOT_REWRITE_ENABLED=false` skips it.
   - Post the `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at <ts>` footer (Step 8 greps this prefix), then the green `MERGE:` line — before the label flip, so a later `exit 1` never hides a completed merge.
   - `finalize-issue-labels.sh "$ISSUE" --repo "$PIPELINE_REPO"` adds `merged` and strips the lifecycle set (WARN on failure).
   - Close the issue; an `already closed` error (the merge auto-closed it via `closingIssuesReferences`) is benign. A genuine close failure exits 1 and aborts the batch; Step 8's fallback pass recovers.

   **Every `block-*` line is DEFERRED to step 4, never dropped** — `MERGE:` and `GATE:` lines alike. One blocked PR never stops its siblings.

4. **On any `block-*` reason:** comment why auto-merge was skipped, apply the `manual-merge` label, return Approved-but-not-merged; no other label flip, no close. ONE wave call, `<N>:<reason>` pairs:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-block-merge.sh" <issue:reason pairs>
   ```
   - The comment reads `Auto-merge skipped: <reason>. Run \`gh pr merge\` manually.`; for `block-base-mismatch` it also suggests `retarget-pr.sh <PR> <base>` (or `gh pr edit <PR> --base <base>`).
   - `--add-label "manual-merge"` lets `scripts/run-queue.sh` free the queue slot on its next poll instead of the 90-min timeout; it fails open, and the label stays post-merge as history.
   - **`block-capability-refused` remediation:** re-dispatch the refused task to the PR-opening role (the inline execute `Agent` on PATH A/B, the orchestrator on PATH C fan-out) per `execute-issue-plan` Step 8's owner rule, then re-run the evaluation.

Release-please PRs are out of scope — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in `skills/fullsend/SKILL.md` Step 7b.
