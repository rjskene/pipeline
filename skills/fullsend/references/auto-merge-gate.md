# Auto-merge gate — the orchestrator's post-evaluation merge procedure

Read this from `skills/fullsend/SKILL.md` Step 7, on any token the gate returns.

**Owner: the ORCHESTRATOR.** Until #1444 this procedure was the evaluator's
final step and the EVALUATOR fired it; the evaluator now posts its
`## Evaluation` verdict and stops. `scripts/auto-merge-gate.sh` emits ONE TOKEN
(`auto_merge_should_fire`) and performs no action at all — every `gh` write
below exists only here, so this file is the merge procedure, not a restatement
of the helper. Steps 1-4 below are the renumbered `11.1`-`11.4`.

**Authoritative owner of the greenlight check.**

On `needs-browser` issues, gate (1) requires zero `unsatisfied` entries in the Visual proof row.

**Greenlight matrix — all 4 must hold** (otherwise the PR is left for manual merge with a `block-*` reason):
1. Latest `## Evaluation` comment contains `**Verdict:** Approved`.
2. Every entry in the PR's `statusCheckRollup` has `conclusion == SUCCESS` (or the rollup is empty for repos with no CI configured).
3. `mergeable == MERGEABLE`.
4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

**Dual-defense doctrine (issue #295).** Base-branch enforcement is defense-in-depth across four layers: (i) the eval-time `baseRefName == $PIPELINE_BASE_BRANCH` assertion inside `auto-merge-gate.sh` (step 2 below — `block-base-mismatch`); (ii) a TOCTOU re-read immediately before `gh pr merge` in step 3 below; (iii) the skill-level quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b; (iv) the `enforce-base-branch.py` PreToolUse hook over `gh pr create` / `gh pr edit --base`. The hook alone is **insufficient** — bypassed in production (#295; see `dev/audits/295-root-cause.md`). The eval-time gate is the load-bearing zero-data-loss layer.

1. **Flag parsing.** `--manual-merge` may appear anywhere in argv. Also honored via env: `MANUAL_MERGE=1` (exported by `spawn-claude.sh` when the spawn carried `--manual-merge`) is equivalent. If either signal is set, skip this gate entirely and return Approved-but-not-merged.

2. **Source the helper and run the gate.** Thread `PIPELINE_CAPABILITY_REFUSAL_SOURCES` (#1233): `scripts/check-capability-refusal.sh --resolve-sources` resolves the MAIN checkout's log dir, never `$(pwd)` — a feature WORKTREE has no `.claude/logs/` of its own (#1246). Tokens: `resolved` (normal — export the knob), `no-log-dir` (`PIPELINE_LOGS_ENABLED=false` consumer install), `unresolvable-root` (no main checkout above cwd); either fallback leaves the knob unexported (fail-open).
   ```bash
   # Required env: GATED ISSUE PR_NUM (bound by skills/fullsend/SKILL.md Step 7).
   WT_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/worktrees"
   GATED="<wave-N pr-open issues whose evaluator returned>"
   source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
   CR_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-capability-refusal.sh" --resolve-sources)
   CR_STATE=${CR_LINE%% *}; CR_STATE=${CR_STATE#SOURCES=}
   CR_DIR=${CR_LINE##*DIR=}
   case "$CR_STATE" in
     resolved)          export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$CR_DIR" ;;
     no-log-dir)        echo "NOTE: no subagent log dir on the main checkout (PIPELINE_LOGS_ENABLED=false?) — capability arm skipped: $CR_LINE" >&2 ;;
     unresolvable-root) echo "WARN: capability-refusal sources UNRESOLVABLE from $(pwd) — gate arm DORMANT (#1246): $CR_LINE" >&2 ;;
   esac
   for N in $GATED; do
     ISSUE="$N"
     WT=$(ls -d "$WT_ROOT/${PIPELINE_WORKTREE_PREFIX:-wt}-$N-"* 2>/dev/null | head -1)
     BR=$([ -n "$WT" ] && git -C "$WT" branch --show-current)
     PR_NUM=$([ -n "$BR" ] && gh pr list --repo "$PIPELINE_REPO" --head "$BR" --json number --jq '.[0].number')
     REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
     echo "GATE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"
   done
   ```
   **ONE Bash call per wave (#1452).** `source` + the `--resolve-sources` resolution are wave-invariant and hoisted ABOVE the loop; only the per-issue gate call repeats. Each issue's `WT` / `PR_NUM` are DERIVED in-loop (worktree glob → that worktree's branch → `gh pr list --head`), never recalled from orchestrator context. The TWO `[ -n … ]` tests are the fail-closed guards, NOT the commands' exit statuses: `git -C "" branch --show-current` exits 0 and prints the ORCHESTRATOR's own branch, and `gh pr list --head ""` exits 0 and returns the repo's newest open PR — so a glob miss (empty `WT`) or a detached/stale worktree (empty `BR`) would otherwise name an unrelated PR (a #909-class misroute). An empty `$PR_NUM` makes the gate emit a `block-*` token — a visible `GATE:` line, never a silent skip.
   Checks in order: `MANUAL_MERGE` env, `manual-merge` label, the 4 greenlight conditions, capability-refusal, `baseRefName == $PIPELINE_BASE_BRANCH`. Prints exactly one token: `green`, `block-flag`, `block-label`, `block-cage-tests-diff`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-ci`, `block-mergeable`, or `block-mergestate`. The gate may also print `NOTE: capability-refusal arm skipped (REASON=async-dispatch …)` on stderr — expected for background-dispatch records, not a WARN, never reported as "unproven".

   **pr-eval depth is never gated (W3).** pr-eval itself STAYS Opus in all configurations, never gated by any execute-side knob. Since #1186 that is an explicit PIN, not an inheritance side-effect: the dispatch carries `model=` resolved from `scripts/resolve-stage-model.sh <N> pr-eval` (`PIPELINE_STAGE_MODEL_PR_EVAL`, unset ⇒ `opus`). No carve-out can lower the pin; an explicit knob below the resolved execute tier is honored but emits a stderr WARN (an operator override is allowed, silence is not).

3. **On `green`:** ONE batched wave loop (#1452). The whole green path — TOCTOU re-check, merge, SHA capture, screenshot rewrite, footer, label flip, close — is ONE Bash call over the wave's greenlit issues, emitting one line per issue: `MERGE: issue=#<N> pr=#<P> reason=<green|block-base-mismatch|block-no-pr|block-merge-failed> [sha=<sha>]`. The line ORDER inside the loop is load-bearing — the rationale bullets below say why; do not reorder them.
   ```bash
   # No inherited env: GREEN is bound HERE, from the Step 7 GATE lines.
   GREEN="<issue numbers whose Step 7 GATE line read reason=green>"
   WT_ROOT="${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/worktrees"
   for N in $GREEN; do
     ISSUE="$N"
     WT=$(ls -d "$WT_ROOT/${PIPELINE_WORKTREE_PREFIX:-wt}-$N-"* 2>/dev/null | head -1)
     BR=$([ -n "$WT" ] && git -C "$WT" branch --show-current)
     PR_NUM=$([ -n "$BR" ] && gh pr list --repo "$PIPELINE_REPO" --head "$BR" --json number --jq '.[0].number')
     [ -n "$PR_NUM" ] || { echo "MERGE: issue=#$ISSUE pr=#none reason=block-no-pr"; continue; }
     BASE_RECHECK=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
     if [ -z "$BASE_RECHECK" ] || [ "$BASE_RECHECK" != "$PIPELINE_BASE_BRANCH" ]; then
       REASON="block-base-mismatch"
       echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"; continue
     fi
     gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch \
       || { echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=block-merge-failed"; continue; }
     SHA=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json mergeCommit --jq .mergeCommit.oid)
     if [ -n "$SHA" ] && [ "${PIPELINE_SCREENSHOT_REWRITE_ENABLED:-true}" = "true" ]; then
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/rewrite-eval-screenshot-urls.sh" "$PR_NUM" "$SHA" \
         || echo "WARN: post-merge URL rewrite failed for PR #${PR_NUM}"
     fi
     TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
     FOOTER="Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at ${TS}"
     gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" --body "$FOOTER"
     echo "MERGE: issue=#$ISSUE pr=#$PR_NUM reason=green sha=${SHA:-none}"
     bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/finalize-issue-labels.sh" "$ISSUE" --repo "$PIPELINE_REPO" \
       || echo "WARN: finalize-issue-labels exited non-zero for issue #${ISSUE}; labels may be stale (merge already completed)."
     CLOSE_SUFFIX=$([ -n "$SHA" ] && echo " (${SHA})" || echo "")
     CLOSE_ERR=$(gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM}${CLOSE_SUFFIX}. ${FOOTER}" 2>&1)
     if [ $? -ne 0 ]; then
       if printf '%s' "$CLOSE_ERR" | grep -qi 'already closed'; then
         echo "Issue #${ISSUE} already closed by gh pr merge (closingIssuesReferences) — benign (issue #813)."
       else
         echo "$CLOSE_ERR" >&2
         exit 1
       fi
     fi
   done
   ```
   - **Every `block-*` line is DEFERRED to step 4, never dropped.** A per-iteration `continue` ends that issue's merge, not its handling: every `MERGE: … reason=block-*` line here — exactly like every Step 7 `GATE: … reason=block-*` line — is then run through **step 4** below, per PR, which posts the `Auto-merge skipped:` comment AND applies the `manual-merge` label (#489's run-queue slot-freeing signal). One blocked PR never stops its siblings, and no blocked PR loses its step-4 routing.
   - **TOCTOU re-check (issue #295).** Immediately before the merge, re-read `baseRefName`. A malicious or buggy actor could retarget the PR between step 2's gate and the merge call. On a mismatch the loop sets `REASON="block-base-mismatch"`, emits its `MERGE:` line and `continue`s — `gh pr merge` is never invoked for that PR.
   - **The `PR_NUM=` derivation fails closed on the `[ -n "$WT" ]` / `[ -n "$BR" ]` tests, not on `git` or `gh`.** `git -C "" branch --show-current` exits 0 printing the ORCHESTRATOR's own branch, and `gh pr list --head ""` exits 0 returning the repo's newest open PR, so a worktree-glob miss (empty `WT`) or a detached/stale worktree (empty `BR`) would otherwise name an unrelated PR (a #909-class misroute). An empty `$PR_NUM` emits `reason=block-no-pr` so `gh pr merge ""` is unreachable.
   - Merge synchronously (NOT `--auto`), then capture the merge-commit SHA (empty `$SHA` from rare API lag → omit from close comment; the merge is authoritative). **The merge itself is guarded (#1452):** batching runs every gate BEFORE any merge, so each post-first PR's `mergeStateStatus` is stale by the time its turn comes; a failed `gh pr merge` emits `reason=block-merge-failed` and `continue`s instead of posting the `Auto-merged:` footer, applying `merged` and closing the issue on an UNMERGED PR.
   - **Rewrite screenshot URLs to the merge SHA (issue #506, extended #551).** The eval comment embeds branch-pinned screenshot URLs that 404 once `--delete-branch` removes the feature branch. On public repos these are `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/...`; on private repos they are `github.com/<owner>/<repo>/blob/<branch>/.eval-screenshots/...` (the blob-link form from Step 6). The rewriter branch-scope-pins BOTH host forms to the durable merge-SHA equivalent (`.../<merge-sha>/.eval-screenshots/...`) in one pass. Must run AFTER the SHA capture (the SHA it pins to) and BEFORE the footer-append (so the rewriter targets the screenshot comment, not the footer). Fail-soft — never block the merge that already completed.
   - Append the auto-merged footer (exact literal prefix — `skills/fullsend/SKILL.md` Step 8 greps it). The green `MERGE:` line is emitted immediately AFTER that footer and BEFORE the label flip, so the retained `exit 1` below can never abort the batch while HIDING a merge that completed.
   - Flip labels and close the issue (omit `(${SHA})` if `$SHA` is empty). **Swallow the benign "already closed" non-error (issue #813).** `gh pr merge` auto-closes the linked issue via `closingIssuesReferences` a beat before this explicit `gh issue close` runs, so the explicit close routinely fails with an "already closed" message. That is cosmetic — the final state (merged + closed) is already correct — so the guard treats an `already closed` stderr as success and only re-raises a genuine close failure (e.g. a transient API error). The label flip and close comment still run for the case where the PR body carried no `Closes #N` link.
     The label flip is delegated to the shared `finalize-issue-labels.sh` helper (issue #866): it adds `merged` and strips the full pipeline lifecycle/path/priority set (not just `pr-open`), keeping all three merge-completion sites (this path, `finish-manual-merge.sh`, `cleanup-worktree.sh`) in lockstep. The close-comment / "already closed" guard (#813) is unchanged. Step 3 now passes `--repo "$PIPELINE_REPO"` explicitly (this subshell may not export it) and surfaces a `WARN` on finalize failure rather than silently no-op'ing on stale labels (issue #888). The `exit 1` on a genuine close failure is KEPT (fail-loud, #813) and therefore ABORTS the remaining green merges in the batch; recovery is Step 8's documented fallback pass, which re-runs the gate for any `pr-open` issue Step 7 did not merge.
   - Screenshots: no cleanup needed — the `.eval-screenshots/` commit collapses into the merge-commit and the feature branch is deleted by `--delete-branch`. Step 3 above has already rewritten the eval comment's branch-pinned URLs — both the public `raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/...` form and the private `github.com/<owner>/<repo>/blob/<branch>/.eval-screenshots/...` blob link (issue #551) — to the merge-SHA-pinned form (`.../<merge-sha>/.eval-screenshots/...`), so the embedded screenshots stay durable for the life of the commit even after the feature branch is deleted (issue #506). Operators who deliberately want the legacy ephemeral behaviour (e.g. external or legal-hold screenshot capture) set `PIPELINE_SCREENSHOT_REWRITE_ENABLED=false`, which skips step 3's rewrite and restores the tracker-#383 post-merge-404 semantics.

4. **On any `block-*` reason:** post a single comment explaining why auto-merge was skipped, then return Approved-but-not-merged. Do not flip labels or close the issue.
   ```bash
   gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
     --body "Auto-merge skipped: ${REASON}. Run \`gh pr merge\` manually."
   ```

   **`block-base-mismatch` extension.** When `REASON == block-base-mismatch` (from step 2's gate or step 3's TOCTOU re-check), the comment body MUST also include a retarget suggestion:
   ```bash
   gh pr comment "$PR_NUM" --repo "$PIPELINE_REPO" \
     --body "Auto-merge skipped: block-base-mismatch — PR baseRefName diverges from \$PIPELINE_BASE_BRANCH ($PIPELINE_BASE_BRANCH).

Run \`\$CLAUDE_PLUGIN_ROOT/scripts/retarget-pr.sh $PR_NUM $PIPELINE_BASE_BRANCH\` to retarget (or \`gh pr edit $PR_NUM --base $PIPELINE_BASE_BRANCH\` if retarget-pr.sh is unavailable)."
   ```

   **Auto-apply the `manual-merge` label (issue #489).** After posting the `Auto-merge skipped:` comment — for ANY `block-*` reason — add the `manual-merge` label to the issue so the wedge becomes terminal-detectable by the run-queue runner on its next poll:
   ```bash
   gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" --add-label "manual-merge" 2>/dev/null || true
   ```
   The label flip is what lets the runner (`scripts/run-queue.sh` `evaluator_finished_terminal()`) free the queue slot immediately instead of waiting for the per-agent 90-min timeout. Fails OPEN on `gh` error — the worst case is the pre-#489 behaviour (queue waits for the timeout). The label is permanent post-merge (`cleanup-worktree.sh` leaves it as a historical "this PR did not auto-merge" signal).

   **`block-capability-refused` remediation (#1233).** No new arm is needed — the ANY-`block-*` handling above already posts the skip comment and applies `manual-merge`. The remediation is: re-dispatch the refused task to the PR-opening role (the inline execute `Agent` on PATH A/B, the orchestrator on PATH C) per `execute-issue-plan` Step 8's owner rule, then re-run this evaluation.

Release-please PRs are out of scope for this gate — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in `skills/fullsend/SKILL.md` Step 7b.
