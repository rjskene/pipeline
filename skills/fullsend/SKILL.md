---
name: fullsend
description: Run the full pipeline autonomously end-to-end (classify → plan → evaluate → execute → evaluate PR → auto-merge greenlit PRs) without intermediate confirmations. Usage: /pipeline:fullsend [issue_numbers...] [--manual-merge]
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Agent
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Full Send — the autonomous entry point

`/pipeline:fullsend` is the canonical autonomous entry to the pipeline. It chains classify → plan → eval-plan → execute → eval-pr → greenlight-merge across a slate of issues without intermediate confirmations.

```
slate → wave plan → classify+plan (waves) → eval-plan → approve → execute → eval-pr → greenlight → merge
```

Invoked two ways: (1) directly as `/pipeline:fullsend [issue_numbers...] [--manual-merge]` — the canonical entry point; (2) via the back-compat magic-string delegator in `/pipeline:run` — when a user prompt to `/pipeline:run` contains the token `full send` / `full-send` / `fullsend` (case-insensitive), `/pipeline:run` invokes this skill via `Skill(skill: "pipeline:fullsend", args: "<argv>")` with the original argv and stops.

Argv shape: `[issue_numbers...] [--manual-merge]`, position-independent (the flag-parsing rule below preserves the prior behavior).

PATH D (quick-fix) is NO LONGER path-agnostic to fullsend at the execute stage: fullsend now DOES branch D into a SPLIT DISPATCH (see Step 6). PATH-D-specific *lifecycle* behavior (auto-flip plan-pending → plan-approved, inline tdd-implementer execute dispatch, Step 8 skip) is still owned by /pipeline:run (skills/run/SKILL.md Step 4 and Step 6) and /pipeline:execute-issue-plan (skills/execute-issue-plan/SKILL.md Step 8 early-return). What fullsend adds on top is a DISPATCH split: within each wave, the wave's conflict-free A/B/D issues fan out as a **concurrent inline `Agent` batch in the FOREGROUND** while PATH C issues launch via the tmux **C-only run-queue** backgrounded with `run_in_background` (Step 6). Per #748, PATH B execute joined the inline foreground side alongside A/D (no `spawn-claude.sh` / `claude -p`), leaving only PATH C on the backgrounded run-queue. The inline foreground batch consumes **zero queue slots** — it is free concurrency atop the C-only run-queue capacity — so no fullsend run-queue change is required for the foreground paths themselves.

## Wave plan (pre-think)

Before any dispatch, fullsend pre-thinks the slate via `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=classify <ready-issue-numbers>` and captures stdout as the wave plan. Waves are processed serially; within a wave, issues dispatch in parallel. `plan-waves.sh` groups issues honoring (1) priority tiers, (2) explicit `blocked by #N` / `depends on #N` annotations in issue bodies, and (3) shared-file conflicts extracted via body-substring grep — when two issues touch the same file path, the second is deferred. The `--stage=classify` flag skips file-conflict detection because classify/plan agents are read-only, so cross-references in issue bodies must not over-serialize them.

```
Wave 1: classify #101, #102, #103 in parallel
Wave 2: classify #104 (serial — shares skills/run/SKILL.md with #101)
Wave 3: classify #105 (serial — blocked by #104)
Wave 4: classify #106, #107 in parallel
Wave 5: classify #108 in parallel
```

Gated by `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED` (default `true`); when `false`, fullsend falls back to single-blast parallel dispatch. The same wave-by-wave discipline applies to plan-issue dispatch in Step 1b — the wave plan is reused; the planner is not re-run.

## Greenlight matrix

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, fullsend auto-squash-merges if and only if all four conditions hold; otherwise the PR is left for manual merge with a `block-*` reason token.

```
| # | Condition                                                | Source                              |
|---|----------------------------------------------------------|-------------------------------------|
| 1 | Latest `## Evaluation` has `**Verdict:** Approved`       | gh pr view --json comments          |
| 2 | Every statusCheckRollup entry `conclusion == SUCCESS`    | gh pr view --json statusCheckRollup |
| 3 | `mergeable == MERGEABLE`                                 | gh pr view --json mergeable         |
| 4 | `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE) | gh pr view --json mergeStateStatus |
```

**block-base-mismatch** is enforced as defense-in-depth — PR `baseRefName` must equal `PIPELINE_BASE_BRANCH` (see #295). Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → verdict → `block-base-mismatch` → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, `block-flag`, `block-label`, `block-verdict`, `block-base-mismatch`, `block-ci`, `block-mergeable`, `block-mergestate`.

**Three opt-outs:** (1) `FULL SEND --manual-merge` — flag may appear anywhere in argv (cannot collide with issue numbers, which are bare integers); (2) `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations; (3) a `manual-merge` label on the issue for per-issue control without re-typing the flag.

## Auto-merge ownership

The gate logic lives in `scripts/auto-merge-gate.sh` (function `auto_merge_should_fire <issue> <pr>` returning a single token). `/pipeline:evaluate-issue-pr` Step 11 fires the gate inline immediately after posting its Approved verdict — that is the primary auto-merge path. Fullsend's Step 8 (Report) is the **fallback** auto-merge path; it re-runs the gate only for any `pr-open` issue the evaluator did not already auto-merge (e.g. the evaluator crashed between verdict post and gate fire). Release-please PRs are out of scope of this gate; they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` (Step 7b), unchanged. This section names ownership; do not re-document the gate body — that's evaluate-issue-pr's territory.

1. **Plan**

   **1a. Ingest attachments for the slate.** For each issue in the slate (the ready-issue set being processed this wave), run `fetch-issue-attachments.sh` so downstream classify/plan/execute/evaluate-pr agents have screenshots and binary evidence available locally:

   ```bash
   for N in <slate-issue-numbers>; do
     PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh" "$N" 2>/dev/null \
       | head -1
   done
   ```

   The helper is idempotent — repeat invocations cost zero `gh api` calls. The `head -1` cap keeps wave-log output to one line per issue. This is the autonomous-mode ingestion site; `/pipeline:run` step 0 does NOT fetch attachments. Interactive single-issue planning fetches at `/pipeline:plan-issue` step 3b instead.

   **1b. Dispatch classify and plan.** Process wave by wave per the `## Wave plan (pre-think)` section above — before dispatching plan-issue, run `/pipeline:classify-issue N` for every ready issue that lacks a fresh Classification comment (dispatch in parallel, one Agent per issue). Each classify run writes the Classification comment AND applies the path label (`docs-only` or `multi-task`). Cached issues skip dispatch. Then run `/pipeline:plan-issue N` for every issue with no pipeline label (in parallel, one Agent per issue). Wait for all to complete. **PATH D exclusion.** PATH D (`quick-fix`) issues are EXCLUDED from this per-stage classify/plan dispatch — their classify+plan stages run INSIDE the single collapsed foreground inline `Agent` dispatched at execute (Step 6), emitting `## Classification`+`quick-fix` and `## Implementation Plan`+`plan-pending` as inline side-effect checkpoints. Only A/B/C issues go through this Step 1b per-stage classify/plan dispatch. (The `## Wave plan (pre-think)` ordering still includes D — only the per-stage classify/plan *dispatch* is what D skips.)
   - **Dispatch prompt contract (mandatory):** each `/pipeline:plan-issue N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 and it reports the success line, or (b) `post-plan.sh` exited non-zero and it reports the FAILED line. Returning the plan body in chat is a failure — the plan does not exist until `post-plan.sh` has posted the `## Implementation Plan` comment and applied the `plan-pending` label. A `general-purpose` subagent may never load `skills/plan-issue/SKILL.md` (it can treat `/pipeline:plan-issue N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract.
   - **Verify plan comments:** After all plan-issue agents complete, for each issue that was targeted (had no pipeline label at the start of this step), confirm a plan comment was posted:
     ```bash
     PLAN_COUNT=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     ```
     If any targeted issue has `PLAN_COUNT == 0` (regardless of whether `plan-pending` was added), the plan-issue agent failed. Re-run `/pipeline:plan-issue N` for that issue (max 1 retry). If still missing after retry, skip the issue and flag it in the final report as "Skipped (plan not posted)".
2. **Evaluate plans** — run `/pipeline:evaluate-issue-plan N` for every `plan-pending` issue (in parallel, one Agent per issue). Wait for all to complete.
3. **Re-plan loop** — for any issue whose evaluation verdict is "Revise": re-run `/pipeline:plan-issue N`, then `/pipeline:evaluate-issue-plan N`. Repeat until all pass (max 3 iterations per issue). If an issue still fails after 3 iterations, skip it and flag it in the final report.
4. **Approve** — for every issue now at `plan-reviewed`, run:
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-reviewed"
   ```
### Execute the slate WAVE BY WAVE (Steps 5–7 per wave)

The execute stage runs the approved slate **wave by wave**, not as a single blast. Each wave's worktrees are set up off the *current local base tip* so that wave N+1 inherits wave N's merged work. Two distinct `plan-waves.sh` passes drive this loop:

**Pass A — wave order (re-run, `--stage=execute`).** Re-run the planner for the execute stage and capture stdout:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=execute <approved-slate>
```

This is a **second, distinct invocation** from the `--stage=classify` pre-think (see `## Wave plan (pre-think)`). The execute stage enables file-conflict waving (executors WRITE), so cross-references and shared-file conflicts ride along for free. Parse the `Wave N:` lines into per-wave issue lists and the wave order.

**Pass B — the edge map for the halt closure (`--emit-edges`).** ALSO run:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=execute --emit-edges <approved-slate>
```

Parse the emitted `EDGE #<N> blockers=<csv> files=<csv>` lines into a per-issue map. **Why a separate machine-readable pass is required:** the human-readable `Wave N:` lines print per-issue `reason` strings ONLY for single-issue waves — a blocked issue grouped into a MULTI-issue wave has its dependency edge **suppressed in stdout**. The scoped-halt dependency closure (below) MUST therefore be computed from this `--emit-edges` edge map, **NOT** from the human-readable `Wave N:` lines, because `--emit-edges` emits every issue's blockers+files regardless of wave grouping.

For each wave N, in wave order, serially run Steps 5 → 6 → 6b → 7 against ONLY that wave's issue numbers, then perform the **inter-wave pull** before starting wave N+1.

5. **Set up worktrees** — for wave N, run `setup-worktree.sh` for each issue in wave N (sequentially), branched off the **current local base tip**. Full invocation signature:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base>] <branch-name> <issue-number>
   ```

   Both positional args are required. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short) — same convention as `skills/run/SKILL.md` ("Branch and worktree naming convention"). `<issue-number>` is the bare integer.

   Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81
   ```

   The script defaults to `PIPELINE_BASE_BRANCH` from `pipeline.config`; pass `--base` only if you need to override (e.g., orchestrator running on a non-default branch).

   **Do NOT invoke with only the issue number** — the script will reject it as of #350. A bare integer like `setup-worktree.sh 81` fails the branch-prefix guard because `81` is not a `feature/<slug>` shape; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.

   **Base-tip note (the #626 fix).** `setup-worktree.sh` adds the worktree via `git worktree add -b`, which **branches off the main repo's LOCAL HEAD, not `origin/<base>`**; the `--base` / `$BASE_BRANCH` value there is only metadata, not a remote fetch. So a wave's worktrees inherit exactly whatever the orchestrator's local base tip points at *at the moment Step 5 runs*. That is why the inter-wave pull (below) is mandatory between waves.
6. **Execute (wave N)** — launch wave N's worktrees via the tmux queue runner with skip-permissions enabled (equivalent to user answering "tmux / y" at the launch prompt). Scope `run-queue.sh` to ONLY wave N's issue numbers — never mix issues from a later wave into the same queue (no cross-wave concurrency). **Within-wave parallelism is preserved:** same-wave issues that have no dependency or file-conflict edge between them still run concurrently up to run-queue's `MAX_AGENTS` cap — do not over-serialize within a wave. Launch the queue runner via `Bash` with `run_in_background: true` — do NOT use a foreground `while ... sleep ... grep` poll loop. Wait for terminal events with a single `Monitor` invocation against the queue runner's captured stdout stream — the `Bash` tool's `run_in_background: true` task captures the runner's stdout, queryable via the `BashOutput` tool. That captured stdout is the always-on wake channel because `log()` (`scripts/run-queue.sh:136-142`) emits every `EVENT:` line to stdout unconditionally, even when `PIPELINE_LOGS_ENABLED=false` (the `queue-*.log` file is gated and may not exist on consumer hosts — do NOT tail it). Invocation shape: `Monitor` on the bash task's stdout stream with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000` (preserves the existing 2h worst-case wait budget). Per Monitor's coverage rule, the filter MUST cover every terminal state (failure + completion) so a crash is never silent — `agent-finished outcome=failed` IS the per-agent failure signal (the runner does not emit a separate `agent-failed`). Status updates are emitted automatically by the queue runner every 3 minutes (configurable via `STATUS_INTERVAL`).

   **Split dispatch for PATH D (#700) + PATH B (#748).** Within wave N, partition the wave's issues by path. Only PATH C issues launch via the tmux **C-only run-queue** backgrounded with `run_in_background` exactly as described above — that queue's `MAX_AGENTS` cap (max 3 slots) is unchanged. The wave's **conflict-free PATH A/B/D issues fan out CONCURRENTLY as an inline `Agent` batch in the FOREGROUND** at the same wall-clock — dispatched together in a single foreground batch. PATH B uses `Agent(subagent_type='general-purpose', ...)` (its red→green discipline comes from the plan's Task 0 `superpowers:test-driven-development` bookend inside execute-issue-plan, NOT a fresh transport) and PATH D uses `Agent(subagent_type='tdd-implementer', ...)`. The PATH D inline `Agent` is additionally the SINGLE collapsed context that carries classify+plan+execute forward in ONE dispatch — it is NOT a fresh execute dispatch that re-reads a plan posted by an upstream Step 1b plan Agent (D was EXCLUDED from Step 1b's per-stage classify/plan dispatch precisely so that its classify+plan run inline here); PATH B is classified+planned per-stage upstream as normal and its inline `Agent` only runs execute. The collapsed D agent's pr-eval — and PATH B's pr-eval — is NOT folded into the execute context: each stays the separate Step 7 `evaluate-issue-pr` dispatch (evaluator independence). The inline foreground batch **consumes zero queue slots** — it costs no run-queue slot and is free concurrency *atop* the C-only run-queue capacity, not carved out of it. Bound the foreground batch at **max 3 concurrent inline** agents. Policy: fire the inline foreground batch FIRST / alongside the C-only run-queue launch — the inline agents (especially D) typically finish fast while the C run-queue grinds for far longer, so launching the foreground batch first costs essentially no added wall-clock.

   **D is NOT exempt from wave discipline.** The wave plan from `plan-waves.sh --stage=execute` already orders ALL paths (A/B/C/D) together over a **unified file-conflict graph** (there is no path-label gate — see `scripts/plan-waves.sh` and `tests/test-plan-waves-unified-graph.sh`). So a PATH D (or PATH B) issue that shares a file with another in-flight issue (any path) is ALREADY serialized into a later wave by the planner — the inline foreground dispatch does NOT exempt it from wave serialization. Only the wave's **conflict-free** foreground issues fan out in the batch; issues that collide with this wave's other in-flight work were already deferred to a later wave and are dispatched there.

   **Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D `/pipeline:execute-issue-plan N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: **(a)** the PR is opened and the issue is flipped to `pr-open`, reporting the success line (PR number + final test status); or **(b)** the work failed, reporting a FAILED line. Narrating an intention to "wait" (e.g. *"I'll wait for the suite notification."*) — or returning prose/edits instead of committing, pushing, and opening the PR — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the subagent with uncommitted work in progress (the #752/#764 drop-out). The subagent must instead run to completion (commit → push → `gh pr create` → label flip) or actually block on the suite via `Monitor`/`BashOutput` before yielding. A `general-purpose`/`tdd-implementer` subagent may never load `skills/execute-issue-plan/SKILL.md` (it can treat `/pipeline:execute-issue-plan N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. (Mirrors the Step 1b plan-issue dispatch prompt contract.)

   ### Triage on agent-stalled wakes

   **Wake-loop semantics.** Each line matching the filter wakes the orchestrator. Dispatch by event:
   - `EVENT: queue-complete` — terminal; exit the Monitor wait and proceed to Step 6b / Step 7's next phase.
   - `EVENT: agent-stalled issue=<N>` — runner reports worker at idle CPU **and** no forward progress (frozen tmux pane) across `PIPELINE_STALL_POLL_THRESHOLD` polls (#641); a healthy API-bound agent emitting pane output is no longer flagged. Runner took no action. Run the four-option triage below; then re-enter `Monitor` with the SAME `timeout_ms` budget (the elapsed wait is preserved by the harness).
   - `EVENT: agent-finished outcome=failed issue=<N>` — per-agent failure. Optional triage (capture pane, inspect PR/branch state); re-enter `Monitor` so the rest of the queue continues to be watched.
   - `EVENT: agent-finished outcome=success issue=<N>` — no-op wake; re-enter `Monitor`.
   - `EVENT: agent-finished outcome=manual-merge-required reason=<block-reason> issue=<N>` — no-op wake (issue #489); the runner freed a wedged evaluator slot whose PR is awaiting manual merge per the evaluator's Step 11.4 block-* skip. The `reason=` field carries the gate's actual block token (`block-verdict`, `block-ci`, `block-mergeable`, `block-mergestate`, `block-label`, `block-flag`, `block-base-mismatch`, or `unknown` if unrecoverable) so the token is NEVER read as an "approved" verdict — a `block-verdict` reason means the evaluator FLAGGED the PR (issue #654). Re-enter `Monitor`. The operator merges the PR by hand (`gh pr merge <PR> --merge --delete-branch`) or via Step 8 of `run/SKILL.md`. Note: `run/SKILL.md`'s live-events `Monitor` match is the generic `EVENT: agent-finished` substring and is intentionally token-agnostic, so it needs no per-token update.

   **Triage on `agent-stalled`.** The event already implies the pane was frozen (no forward progress) across the whole window (#641), so the first triage action is to re-`capture-pane` and confirm it is *still* frozen before acting. Inspect the worker first (tmux pane via `tmux capture-pane -t "$PIPELINE_TMUX_SESSION:issue-<N>" -p`; process tree via `pstree -p <pid>`). Then surface the four-option prompt to the user:
   1. **Kill the wedged subscript only** — `kill <child-pid>` from the pstree output; executor may recover.
   2. **Kill the whole executor** — `tmux send-keys -t "$PIPELINE_TMUX_SESSION:issue-<N>" C-c` and let the runner record `agent-finished outcome=failed`.
   3. **Wait out the timeout** — re-enter `Monitor` with the same `timeout_ms` budget remaining.
   4. **Skip the issue** — `tmux kill-window -t "$PIPELINE_TMUX_SESSION:issue-<N>"`; runner picks the next from the bucket.

   Runner NEVER kills autonomously. The orchestrator's prompt to the user is the kill gate.

6b. CI-fix loop (wave N) — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED:-false}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED:-false}" = "true" ]`. For each of wave N's `pr-open` issues, fullsend invokes `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and parses the emitted `ACTION=` line. Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` is the authoritative source for retry-counter encoding (`pipeline.ci-retries: <n>` issue comment), tail-truncated failure-log path (`.claude/logs/ci-fix-<N>-attempt-<n>.log`), and `human` label application on budget-exhaust.

7. **Evaluate PRs (wave N)** — once wave N's agents finish (queue complete), run `/pipeline:evaluate-issue-pr N` for every wave-N `pr-open` issue (via `run-queue.sh --skip-permissions --skill evaluate-issue-pr`), and apply the per-PR greenlight auto-merge gate from the `## Greenlight matrix` above to each. Launch this queue via `Bash` with `run_in_background: true` as described in step 6, then wait on it with the same event-driven waiter (identical to Step 6's waiter): a single `Monitor` invocation against the bash task's captured stdout stream (queried via the `BashOutput` tool — do NOT tail `queue-*.log`), with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000`. Apply the same wake-loop dispatch and "Triage on agent-stalled wakes" sub-section above — `agent-finished outcome=failed` is the per-agent failure signal (no separate `agent-failed`), `queue-complete` is terminal.

   **Inline PR-eval dispatch prompt contract (mandatory).** Whenever an `evaluate-issue-pr` evaluation is dispatched as an inline `Agent` (PATH A/B/D re-dispatch, or any pr-open issue evaluated inline rather than via the run-queue), the Agent prompt MUST end with a directive stating the dispatched evaluator's *only* valid terminal states are: **(a)** a `## Evaluation` comment posted with an explicit `**Verdict:**` line AND the greenlight gate fired (merged on `green`, or left with a `block-*` reason token); or **(b)** the eval failed, reporting a FAILED line. Narrating an intention to "wait" / "await CI" (e.g. *"All plan items verified. Awaiting the suite/CI output."*) — or returning verification prose instead of posting the verdict and firing the gate — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the PR un-evaluated at `pr-open` and forces a fresh re-dispatch (the #765 drop-out). The evaluator must instead run to completion (post `## Evaluation` → fire greenlight gate) or actually block on pending CI via `Monitor`/`BashOutput` before yielding. A `general-purpose` subagent may never load `skills/evaluate-issue-pr/SKILL.md`, so this dispatch-site directive — not the skill body — is the binding contract. (Verbatim with `skills/run/SKILL.md` Step 6 — the two PR-eval dispatch sites are one contract in two places, mirroring the #764/#771 execute precedent.)
7b. **Auto-merge green release PRs (opt-in)** — runs after step 7 (Evaluate PRs) and before step 8 (Report). Only fires when `PIPELINE_RELEASE_PR_AUTO_MERGE=true` AND at least one release PR has `ci=pass`. Feature PRs land first; the release PR consolidates them so version bumps + CHANGELOG stay coherent.

   ```bash
   if [ "${PIPELINE_RELEASE_PR_AUTO_MERGE:-false}" = "true" ]; then
     while IFS= read -r line; do
       [ -z "$line" ] && continue
       PR_NUM=$(echo "$line" | sed -n 's/^pr=\([0-9][0-9]*\).*/\1/p')
       CI=$(echo "$line" | sed -n 's/.* ci=\([a-z]*\) .*/\1/p')
       if [ "$CI" = "pass" ] && [ -n "$PR_NUM" ]; then
         gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch \
           || echo "WARN: failed to merge release PR #$PR_NUM"
       else
         echo "SKIP: release PR #$PR_NUM ci=$CI (auto-merge only on green)"
       fi
     done <<< "$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)"
   fi
   ```

   Default is **off** — existing repos that gate releases behind manual review are not surprised on upgrade. Step 8's final-report table should include any merged release PRs as their own section.

### Inter-wave pull (advance the local base tip before wave N+1)

After wave N's feature PRs **merge to the remote**, and **before** setting up wave N+1's worktrees (Step 5), the orchestrator advances its LOCAL base tip from the main repo. **Wait for wave N's PRs to merge before setting up wave N+1**, then run:

```bash
git -C "$MAIN_REPO" checkout "$PIPELINE_BASE_BRANCH"
git -C "$MAIN_REPO" pull --ff-only --quiet origin "$PIPELINE_BASE_BRANCH"
```

The inter-wave step is a `git pull --ff-only --quiet origin` of the base branch, run against the main repo (`git -C "$MAIN_REPO" ...`).

**Why this is mandatory (the #626 fix).** `setup-worktree.sh` branches each new worktree off `$MAIN_REPO`'s **LOCAL HEAD** via `git worktree add -b` — **not** off `origin/<base>`; the `$BASE_BRANCH` argument there is only metadata. PR merges land on the **remote**. So without this pull, wave N+1's worktrees branch off the stale, pre-merge local tip and are missing every earlier wave's merged work — the exact staleness bug this issue fixes. The pull **advances the orchestrator's LOCAL base tip** so the next wave's worktrees inherit the merged work. `--quiet` keeps the fast-forward file list out of orchestrator context. `$MAIN_REPO` is the orchestrator's own checkout root; `run-queue.sh` / `setup-worktree.sh` operate inside worktrees, so the orchestrator is free to `checkout` / `pull` on the main repo between waves without disturbing any in-flight worktree.

### Scoped halt-and-report (closure sourced from `--emit-edges`)

If a wave-N PR fails to merge, fullsend does **not** blindly halt every later wave. First discriminate transient from hard blocks:

- **Transient (defer, do NOT halt):** a wave-N PR that lands `block-ci` or `pending` is NOT an immediate halt — let the existing **Step 6b** CI-fix loop run to terminal. If it resolves green, proceed. If it exhausts the red-retry budget (`red-budget-exhausted`, PR is `human`-flagged), only then treat it as a hard block.
- **Hard block (triggers a scoped halt):** `block-mergestate`, `block-mergeable`, `block-verdict`, `block-base-mismatch`, or a CI failure whose retry budget is exhausted. When such a block leaves a wave-N issue's PR unmerged, compute its **dependency closure** and halt only that closure.

**Closure computation — from the `--emit-edges` edge map, NOT the human-readable `Wave N:` lines.** Seed the closure with `{blocked issue}`. Then walk the parsed `EDGE` map to a fixpoint: add any issue whose `blockers=` csv contains a current closure member, and add any issue whose `files=` csv shares a path with any closure member; repeat **transitively** until no new issue is added. The closure is computed from the **emitted edges**, **not** from the human-readable `Wave N:` lines — because multi-issue waves print **no per-issue reason** strings, so a grouped issue's blocker would be invisible there; `--emit-edges` emits every issue's edges regardless of wave grouping, which is why the closure is reliable even for multi-issue waves.

Then:

- Later-wave issues **in** the closure are reported `Skipped (depends on blocked #<N>)`.
- **Independent later-wave issues that are NOT in the closure MAY still proceed** off the current merged base — honoring the issue body's "don't over-serialize" constraint.
- Earlier-wave and this-wave issues that already merged are **preserved** — a scoped halt never rolls back merged work.

The Step 8 report names the issue that hard-blocked, its `block-*` reason token, and which downstream issues were skipped (with the dependency chain read from the edge map), so the operator can merge the blocker by hand and re-run `/pipeline:fullsend` for the remainder.

### Self-mutation callout

This issue edits the fullsend machinery the pipeline itself runs. This is a self-mutation: the change takes effect **only after merge** — that is, after the PR merges and the operator pulls the base branch into their orchestrator checkout. There is **no live-mutation risk** during this issue's own execution, because the work happens in an isolated **worktree** and the running orchestrator keeps its already-loaded skill body until it is restarted.
8. **Report** — print a summary table of all issues with their final stage and any flags. Include a **Classification mismatch** column showing, for each issue, the current-label path vs. the recommended path when they diverged (else blank):
   ```
   FULL SEND COMPLETE
   ================================================================
   Issue  Title                    Classification mismatch   Auto-merged?   Result
   --------------------------------------------------------------------------------
   #N     <title>                  B / C (med)               no (block-ci)  PR approved / Flagged / Skipped (plan failed)
   #N     <title>                                            yes (step8)    PR merged
   ================================================================
   The `Auto-merged?` column reflects Step 8's outcome per PR: `yes (eval)` — the evaluator's Step 11 already merged it; `yes (step8)` — Step 8 merged it on the greenlight path; `no (<block-reason>)` — manual merge required.
   ```
9. **Stop** — do NOT merge unless the greenlight matrix held in Step 8. Auto-merged PRs are already listed in the report's `Auto-merged?` column. Wait for explicit user confirmation before any non-greenlight merge.

**Constraints during full send:**

Slate-pre-hygiene (housekeeping, worktree cleanup, discovery) is owned by `/pipeline:run`; fullsend assumes a clean slate and does not re-implement that flow.

- Issues labeled `PIPELINE_LABELS_EXCLUDED` are always skipped.
- Issues labeled `PIPELINE_LABELS_LATER` are shown in the final report (stage = `PIPELINE_LABELS_LATER`) but not processed.
- Issues labeled `PIPELINE_LABELS_HUMAN` are shown in the final report (stage = `PIPELINE_LABELS_HUMAN`) but never processed by autonomous full send. These need a human in the loop — usually for architecture decisions, cross-platform validation, production deploy risk, or items where the planner can't make the right call without you. They must be picked up manually with `/pipeline:plan-issue` / `/pipeline:execute-issue-plan`, never via full send.
- Issues labeled `PIPELINE_LABELS_BRAINSTORM` are shown in the final report (stage = `PIPELINE_LABELS_BRAINSTORM`) but never processed by autonomous full send — same handling as `PIPELINE_LABELS_HUMAN`. The body is open-ended discussion/architectural critique, not a commit-to-act spec. Manual pickup via `/pipeline:plan-issue` is allowed once the idea crystallizes.
- Blocked issues (blocked-by dependency not yet merged) are skipped; noted in final report as "Blocked".
- The re-plan loop cap of 3 prevents infinite loops on stubborn issues.
- If any stage fails unexpectedly (script error, API failure), stop full send and report the failure with enough detail for the user to diagnose.
