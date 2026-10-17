# Step 6a — post-dispatch completion verification

Immediately AFTER the inline foreground `Agent` batch returns (every dispatched PATH A/B/D issue, and PATH C under PATH_C_FANOUT=off, in this wave) and BEFORE Step 6b, verify each issue reached its terminal state — branch pushed **AND** PR open **AND** issue at `pr-open`. The orchestrator **MUST NOT trust the agent's narrated self-report**: the narrate-and-yield drop-out leaves committed work unpushed with the issue stuck at `in-progress`. Per issue:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" <N>
   ```

   Parse the `ACTION=` line (the token carries the verdict; exit is always 0; fail-closed — an unconfirmed state never reads `complete`). The helper resolves the branch from the issue's worktree (`git worktree list --porcelain`), else the linked PR head, and pins the remote to `origin`.

   | ACTION | Behavior |
   |--------|----------|
   | `complete` | issue verified pushed + PR-open + labelled; proceed to 6b. |
   | `recover-push` | committed-but-unpushed: **orchestrator-owned** — the orchestrator runs `git push -u origin <branch>` itself, then re-runs the helper. The dropped-out agent is never resumed for it. |
   | `recover-pr` | branch pushed, no PR: orchestrator runs `gh pr create --base "$PIPELINE_BASE_BRANCH"`, then re-run the helper. |
   | `recover-label` | PR open, issue still `in-progress`: orchestrator applies `pr-open` / removes `in-progress`, then re-run the helper. |
   | `recover-redispatch` | no committed work / no resolvable branch: re-dispatch a **FRESH** execute `Agent` for `<N>` (never resume the stranded agent; at most once per issue per wave). |

   **No-re-ask rule (mandatory).** On ANY `recover-*` token the recovery is **orchestrator-owned**. It MUST NOT resume, re-prompt, or `SendMessage` the dropped-out agent — an agent that narrate-and-yielded once reproduces it on resume.

   **Bounded escalation ladder.** Act on the token, then re-run the helper ONCE. A different token ⇒ act on it (push → pr → label). If the same token repeats, escalate to `recover-redispatch` with a FRESH `Agent`, at most once per issue per wave. Still `recover-*` after that ⇒ STOP work on this issue, leave labels as-is, record `ACTION=recover-exhausted ISSUE=<N>`, and CONTINUE the wave — a scoped halt for that issue only.

   This complements the `--spawn` run-queue's `executor_finished_terminal()` reap, which covers only the spawned transport.

   **Post-dispatch model verify (WARN-level).** For each dispatched PATH A/B/C/D execute — and each `plan` / `plan-eval` / `pr-eval` stage dispatch of Steps 1b / 2 / 7, using that stage resolver's `MODEL=` — run right after the dispatch returns:

   ```bash
   VED_EXPECT_MODEL="$MODEL" VED_OBSERVED_MODEL="<model-dispatched>" PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --verify-dispatch <N> <A|B|C|D>
   ```

   It may first print the advisory `COST=miss ISSUE=<N> REASON=unattributed-row` (silent unless `PIPELINE_LOGS_ENABLED=true`), then one `DISPATCH=` token: `match` / `mismatch REASON=model:<got>!=<want>` / `warn REASON=model-unrecoverable`. Surface a mismatch in the run log; it never halts the wave.

   **Base-ref drift guard (post-batch, mandatory).** Snapshot `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")` BEFORE the batch; after it returns:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-ref-drift.sh" "$PIPELINE_BASE_BRANCH" "$BASE0" <wave-feature-branches...>
   ```

   - `BASE=ok` → continue.
   - `BASE=recovered` → every stray commit was on a feature branch and the guard reset the base; report and continue.
   - `BASE=drift-unsafe ORPHANS=<shas>` → **scoped HALT** — do NOT proceed to Step 6b; report the orphan shas for manual recovery.
   - `BASE=error REASON=<...>` → advisory; do NOT halt (fail-open).

   **Clean-main guard (post-batch, advisory).** Then:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main "$MAIN_REPO"
   ```

   - `CLEAN=ok` → continue.
   - `CLEAN=untracked-only` → only untracked (typically operator-owned) paths; WARN with `git -C "$MAIN_REPO" status --short` and continue. **Do NOT stash here** — never add the untracked flag to a stash; it sweeps the operator's files.
   - `CLEAN=dirty` → staged or modified tracked files: a subagent's `git add` leaked into the main index. WARN with `git -C "$MAIN_REPO" status --short`, then recover with a plain `git -C "$MAIN_REPO" stash push` (no untracked flag; the verdict is index/tracked-only) BEFORE the inter-wave / inter-leg base advance; continue. The drift guard checks committed SHAs; this guard catches the uncommitted leak.
