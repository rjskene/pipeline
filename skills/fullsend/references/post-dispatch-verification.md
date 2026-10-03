# Step 6a — post-dispatch completion verification

Immediately AFTER the inline foreground `Agent` batch returns (every dispatched PATH A/B/D issue in this wave) and BEFORE the Step 6b CI-fix loop, the orchestrator MUST verify each dispatched issue actually reached its terminal state — branch pushed **AND** PR open **AND** issue at `pr-open` — and **MUST NOT trust the agent's narrated self-report**. The #764/#814 dispatch-prompt + SKILL-body directives are necessary but **not** sufficient: they landed and were present, yet the narrate-and-yield drop-out RECURRED (#838/#904 — committed work, then *"...Waiting for the sweep Monitor..."*, no push, no PR, issue stuck at `in-progress`). This sub-step is the missing orchestrator-side backstop. For EVERY PATH A/B/D issue dispatched in the inline foreground batch, run:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" <N>
   ```

   and parse the single emitted `ACTION=` line (the token, not the exit code, carries the verdict — the helper exits 0 in every case, mirroring `check-ci-fix-loop.sh`; fail-closed: any unconfirmed terminal state emits a recover token, never `complete`). The helper resolves the feature branch **deterministically** — primary: the issue's worktree from `git worktree list --porcelain` (the `wt-<N>-<slug>` dir → its `branch refs/heads/<...>` ref, read verbatim — there is NO `feature/issue-<N>` convention); secondary: the issue's linked PR head — and pins the git remote to `origin` (`PIPELINE_REPO` is the gh owner/repo slug, not a git remote). Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `complete` | issue verified pushed + PR-open + labelled; proceed to 6b. |
   | `recover-push` | branch committed-but-unpushed: **orchestrator-owned** — the orchestrator runs `git push -u origin <branch>` itself for the feature branch (branch as resolved by the helper), then re-runs the helper. The dropped-out agent is never resumed for it. |
   | `recover-pr` | branch pushed, no PR: orchestrator runs `gh pr create --base "$PIPELINE_BASE_BRANCH"`, then re-run the helper. |
   | `recover-label` | PR open, issue still `in-progress`: orchestrator applies `pr-open` / removes `in-progress`, then re-run the helper. |
   | `recover-redispatch` | stranded with no committed work / no resolvable branch: re-dispatch a **FRESH** execute `Agent` for `<N>` (never resume the stranded agent; at most once per issue per wave). Counts against the same wave. |

   **No-re-ask rule (#1208, mandatory).** On ANY `recover-*` token the recovery is **orchestrator-owned**: the orchestrator performs the push / PR / label work ITSELF. It MUST NOT resume, re-prompt, or `SendMessage` the dropped-out agent to finish that work — an agent that narrate-and-yielded once has demonstrated the failure mode and reproduces it on resume (#1208: after `ACTION=recover-push REASON=branch-unpushed` the orchestrator resumed the dropped-out agent with an explicit "STOP WAITING / run everything in the FOREGROUND" message and it dropped out a SECOND time, idle ~11 minutes with the branch still unpushed).

   **Bounded escalation ladder (#1208).** Act on the token, then re-run the helper ONCE. If a different token comes back, act on it (the normal push → pr → label progression). If the same token repeats, the orchestrator's own recovery is not converging: escalate to `recover-redispatch` with a FRESH execute `Agent`, at most once per issue per wave, never a resume of the stranded agent. If the helper still emits a `recover-*` token after that, STOP work on this issue, leave its labels as-is, record `ACTION=recover-exhausted ISSUE=<N>` in the wave report, and CONTINUE the rest of the wave — a scoped halt for that issue only, never a wave halt.

   This complements (does NOT replace) the `--spawn`/run-queue path's existing `executor_finished_terminal()` reap (`scripts/run-queue.sh:595`, #636/#666): that backstop covers the spawned-worker transport only. The gap closed here is specifically the INLINE foreground batch (#838/#904), which has no runner backstop.

   **Post-dispatch model verify (#1056, WARN-level).** For each dispatched **PATH A / PATH B / PATH C / PATH D** issue (#1186 widened this from B/D — A and C now carry real resolved pins, so their dispatches are verifiable too), alongside the `ACTION=` completion check above, also run the additive `--verify-dispatch` mode so a silent model regression becomes VISIBLE in the run log (the #1056 invisible-cost gap — the inline path dispatched every PATH B/D execute WITHOUT a `model=`, inheriting Opus when config said Sonnet, with no signal). Thread the resolver's spec (the `MODEL=` the orchestrator just consumed in Step 6) and the model actually dispatched:

   ```bash
   # Required env: MODEL (token consumed verbatim from resolve-execute-dispatch.sh).
   VED_EXPECT_MODEL="$MODEL" VED_OBSERVED_MODEL="<model-dispatched>" \
     PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --verify-dispatch <N> <A|B|C|D>
   ```

   Run `--verify-dispatch` immediately after the dispatch returns; it also surfaces the advisory FIRST line `COST=miss ISSUE=<N> REASON=unattributed-row` (#1387) — ahead of the `DISPATCH=` verdict line — at WARN level: it never halts the wave and is silent when `PIPELINE_LOGS_ENABLED` is not `true`.

   **The same WARN-level check extends to the pinned STAGE dispatches (#1186).** For each `plan` / `plan-eval` / `pr-eval` Agent dispatched in Steps 1b / 2 / 7, thread the stage resolver's `MODEL=` as `VED_EXPECT_MODEL` and the model actually passed as `VED_OBSERVED_MODEL`, using the issue's path letter:
   ```bash
   VED_EXPECT_MODEL="$MODEL" VED_OBSERVED_MODEL="<model-dispatched>" \
     PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --verify-dispatch <N> <A|B|C|D>
   ```
   `--verify-dispatch` is a pure model check for every path and stage (#1420 retired the shape half): it makes a silently-unpinned stage dispatch VISIBLE instead of invisible, which is the whole failure class #1186 closes.

   It emits a single `DISPATCH=` token (`match` / `mismatch REASON=model:<got>!=<want>` / `warn REASON=model-unrecoverable`). Surface a `DISPATCH=mismatch` in the run log; it is WARN-level and does **not** by itself halt the wave — it is the missing feedback surface, not a new hard gate (it FAILs only on a definite mismatch and WARNs when the observed model is unrecoverable, e.g. the inline path with no `runs` row).

   **Base-ref drift guard (#1106 — Layer 2, post-batch, mandatory).** Alongside the completion + model/shape checks above, run the cause-agnostic drift guard. BEFORE dispatching the inline foreground batch, snapshot: `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")`. AFTER the batch returns, call the guard with the wave's feature branches:

   ```bash
   # Required env: BASE0 MAIN_REPO (BASE0 snapshotted pre-dispatch; MAIN_REPO from the ## Boot fence).
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-ref-drift.sh" \
     "$PIPELINE_BASE_BRANCH" "$BASE0" <wave-feature-branches...>
   ```

   Parse the single emitted token and act:
   - `BASE=ok` → base unchanged; continue.
   - `BASE=recovered` → base drifted but every stray was reachable from a feature branch; guard already ran `git reset --hard origin/<base>`; report the recovery in the run log and continue.
   - `BASE=drift-unsafe ORPHANS=<shas>` → a stray commit is on no feature branch; **scoped HALT** — do NOT proceed to Step 6b. Report the orphan shas for manual recovery (`git reset --hard origin/<base>` once the orphan is confirmed or cherry-picked to a feature branch).
   - `BASE=error REASON=<...>` → internal guard failure; relay as advisory in the run log; do NOT halt (fail-open).

   **Clean-main guard (#1122, post-batch, advisory).** After the base-ref drift guard, run the `--clean-main` mode of `verify-execute-completion.sh` against the orchestrator main checkout:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main "$MAIN_REPO"
   ```

   Parse the `CLEAN=` token and act:
   - `CLEAN=ok` → main checkout index and tracked worktree are both clean; continue.
   - `CLEAN=untracked-only` → the checkout carries ONLY untracked paths — typically operator-owned files that predate the run (`mock-web/`, `scratchpad/`, local notes). This is **not** the #1122 leak (that leak is an INDEX/tracked-file condition), and untracked paths cannot abort a fetch-only base advance. Surface them in the run log as a WARN-level advisory (`git -C "$MAIN_REPO" status --short`) and continue. **Do NOT stash here** — never add the untracked flag (`-u`) to a stash at this boundary; it sweeps the operator's own untracked working files (#1207).
   - `CLEAN=dirty` → staged index entries and/or modified tracked files: a dispatched subagent's `git add` leaked into the main checkout index (the #1122 leak: an execute subagent's bare `git add` staged files in the MAIN index instead of its worktree index). Surface the dirty paths in the run log as a WARN-level advisory (`git -C "$MAIN_REPO" status --short`), then auto-recover with `git -C "$MAIN_REPO" stash push` — plain, with no untracked flag: the dirty verdict is index/tracked-only by construction (#1207), so a plain stash fully clears it and can never touch untracked operator files — BEFORE the inter-wave / inter-leg base advance; then continue. A fetch-only advance is no longer *aborted* by a dirty index (#1214) — this stash is now hygienic housekeeping rather than unblocking a fast-forward — but leaving a leaked stage around is still worth clearing. Note that base-ref-drift (committed) and clean-main (uncommitted index/worktree) are complementary guards — the drift guard compares committed base SHAs and cannot catch a leaked-but-uncommitted `git add` (which produces no stray commit); the clean-main guard closes that specific gap.
