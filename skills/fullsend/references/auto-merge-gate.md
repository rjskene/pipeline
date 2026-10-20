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

2. **Run the merge loop** — `scripts/fullsend-merge-loop.sh <N>...` (one call per wave, SKILL.md Step 7). Each issue's PR is DERIVED (worktree glob → branch → `gh pr list --head`), never recalled; the `[ -n ]` guards fail closed, since `git -C ""` and `gh pr list --head ""` exit 0 naming an unrelated branch/PR, so an empty PR yields a visible `block-no-pr`, never a silent skip. It sources the helper, then `check-capability-refusal.sh --resolve-sources` resolves the MAIN checkout's log dir and threads `PIPELINE_CAPABILITY_REFUSAL_SOURCES` before each `auto_merge_should_fire` call: `resolved` exports the knob; `no-log-dir` / `unresolvable-root` leave it unexported (fail-open, stderr NOTE).
   Per PR in `ORDER:` (fewest-overlap-first): `fullsend-merge-rebase.sh`, a bounded `gh pr checks --watch` after a rebase push (`PIPELINE_MERGE_LOOP_CI_WAIT_SECS`), then the gate. Checks in order: `MANUAL_MERGE` env, `manual-merge` label, the 4 greenlight conditions, capability-refusal, `baseRefName == $PIPELINE_BASE_BRANCH`. Prints exactly one token: `green`, `block-flag`, `block-label`, `block-cage-tests-diff`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-ci`, `block-mergeable`, or `block-mergestate`. A stderr `NOTE: capability-refusal arm skipped (REASON=async-dispatch …)` is expected for background dispatches. A pending `block-ci` gets one wait, a failed one a single `gh run rerun --failed` (`PIPELINE_MERGE_LOOP_CI_RERUN`). One line per issue, then the trailer:
   ```text
   LOOP: issue=#<N> pr=#<P> outcome=merged sha=<sha>
   LOOP: issue=#<N> pr=#<P> outcome=already-merged
   LOOP: issue=#<N> pr=#<P> outcome=needs-fix files=<csv> head=<sha>
   LOOP: issue=#<N> pr=#<P> outcome=<block-* token>
   LOOP: issue=#<N> pr=#<P> outcome=deferred
   LOOP: done | LOOP: pending issues=<csv>
   ```

   pr-eval depth is never gated: the dispatch carries `model=` from `resolve-stage-model.sh <N> pr-eval` (`PIPELINE_STAGE_MODEL_PR_EVAL`, unset ⇒ `opus`).

3. **On `green`:** the loop calls `fullsend-merge-green.sh <N>`, which re-gates with `auto_merge_should_fire` immediately before `gh pr merge`, so a moved head never merges on a stale token. Its order is load-bearing:
   - **TOCTOU re-check** — re-read `baseRefName` right before the merge; a mismatch emits `block-base-mismatch`, no merge.
   - Merge synchronously (NOT `--auto`) with `--merge --delete-branch`; a failure emits `block-merge-failed`.
   - Capture the merge SHA, then rewrite the eval comment's branch-pinned screenshot URLs to it (fail-soft; `PIPELINE_SCREENSHOT_REWRITE_ENABLED=false` skips).
   - Post the `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at <ts>` footer (Step 8 greps this prefix), then the green `MERGE:` line.
   - `finalize-issue-labels.sh "$ISSUE" --repo "$PIPELINE_REPO"` adds `merged` and strips the lifecycle set (WARN on failure).
   - Close the issue; `already closed` (auto-closed via `closingIssuesReferences`) is benign.

4. **On any `block-*` reason** except `block-ci`, the loop calls `fullsend-block-merge.sh <N>:<reason>`: one `Auto-merge skipped: <reason>. Run \`gh pr merge\` manually.` comment, then `--add-label "manual-merge"` (frees the `scripts/run-queue.sh` slot; fail-open; stays as history). No other label flip, no close: Approved-but-not-merged. One blocked PR never stops its siblings.
   - `block-base-mismatch` adds a `retarget-pr.sh <PR> <base>` (or `gh pr edit <PR> --base <base>`) suggestion.
   - **`block-capability-refused` remediation:** re-dispatch the refused task to the PR-opening role (the inline execute `Agent` on PATH A/B, the orchestrator on PATH C fan-out) per `execute-issue-plan` Step 8's owner rule, then re-run the evaluation.

### Re-entry

`LOOP: done` ends the wave. Otherwise clear each pending outcome, then re-call the loop with the `pending` issues:
- `needs-fix` (the rebase hit `conflict FILES=<csv>`; the helper aborted, branch untouched) ⇒ every such issue gets, in parallel, ONE `Agent(subagent_type='pipeline:stage-executor', model=$MODEL, description='rebase-fix #<N>')`, `$MODEL` from its `DISPATCH` line; its prompt starts `cd <worktree-abs-path>` and states "No stage SKILL.md — this prompt is the whole procedure."; then: run `git rebase origin/<base>` yourself, resolve every conflict, starting with `files=`, per the approved plan's intent, run the full suite in the foreground, push `--force-with-lease`, report `REBASE-FIX issue=#<N> files=<csv>`. Then re-dispatch pr-eval per rebased PR (Step 7 invocation, evaluator independence) after one `fullsend-preflight.sh <N>` call, its prompt carrying `REEVAL=rebase-fix OLD_HEAD=<head from the LOOP line> FILES=<files from the LOOP line>` plus the fresh `PREFLIGHT` line; first evaluations carry no `REEVAL=`.
- A rebase-fix with no `REBASE-FIX` line, or a `needs-fix` repeating its previous `files=` (kept from the `LOOP:` lines) ⇒ `fullsend-block-merge.sh <N>:block-mergeable`; new `files=` after a sibling merge get another rebase-fix, at most 3 per issue per wave.
- `block-ci` ⇒ Step 6b's CI wait/repair first. `deferred` ⇒ re-call as-is.

Headless: the script decides; no operator prompt. Step 8's fallback and hand-driving use `fullsend-gate.sh <N>...` (`GATE: issue=#<N> pr=#<P> reason=<token>`), then `fullsend-merge-green.sh` / `fullsend-block-merge.sh`.

Release-please PRs are out of scope — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in `skills/fullsend/SKILL.md` Step 7b.
