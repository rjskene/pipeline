---
name: fullsend
description: Run the full pipeline autonomously end-to-end (plan (classify inline) → evaluate → execute → evaluate PR → auto-merge greenlit PRs) without intermediate confirmations. Usage: /pipeline:fullsend [issue_numbers...] [--manual-merge] [--spawn] [--campaign] [--debug-first]
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Agent
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$([ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = true ] && git rev-parse --show-toplevel 2>/dev/null | sed 's|$|/|')}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
# Orchestrator's own checkout root — the target of every `git -C "$MAIN_REPO" ...`
# in this skill. Mirrors scripts/setup-worktree.sh so skill and script resolve
# identically. Empty PIPELINE_PROJECT_ROOT falls back to the Bash tool's cwd (#1215).
MAIN_REPO="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
```

Each `scripts/fullsend-*.sh` helper takes issue numbers, self-resolves config, and answers `--help`.

# Full Send — the autonomous entry point

`/pipeline:fullsend` is the **sole** autonomous entry point: plan (classify inline) → eval-plan → execute → eval-pr → greenlight-merge across a slate. `/pipeline:run` is a deprecated alias for read-only `/pipeline:status` and does NOT intercept `full send`.

```
slate → wave plan → plan (waves) → eval-plan → approve → execute → eval-pr → greenlight → merge
```

Argv: `[issue_numbers...] [--manual-merge] [--spawn] [--campaign] [--debug-first]` — flags are position-independent and compose.
- `--manual-merge` — merge opt-out (`## Greenlight matrix`).
- `--spawn` — transport only: Step 6 execute and Step 7 PR-eval go through the tmux run-queue. **When `--spawn` is absent, all paths execute inline** (A/B/C/D, PR-eval too).
- `--campaign` — wrap the slate in `## Campaign mode`'s leg loop; absent ⇒ one wave-by-wave pass.
- `--debug-first` — every Step 1b plan dispatch runs plan-issue's Step 4a diagnosis gate; absent ⇒ only `needs-debug` issues.

PATH D lifecycle (auto-flip plan-pending → plan-approved, collapsed inline execute, Step 8 skip) is owned by `## Dispatch routing by path tier (reference)` and `/pipeline:execute-issue-plan`.

## Slate constraints

Pre-hygiene belongs to `/pipeline:status`. Slate rules:
- `PIPELINE_LABELS_EXCLUDED` issues are always skipped.
- `PIPELINE_LABELS_LATER` / `PIPELINE_LABELS_HUMAN` / `PIPELINE_LABELS_BRAINSTORM` issues are reported under that stage, never processed.
- Blocked issues (blocked-by dependency unmerged) are skipped and reported "Blocked".
- On any unexpected failure (script error, API failure) stop and report enough detail to diagnose.

## Wave plan (pre-think)

Before any dispatch run `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=plan <ready-issue-numbers>` and keep stdout as the wave plan. Waves run serially, issues within a wave in parallel; ordering is priority, then `blocked by #N` / `depends on #N`, then shared paths. `--stage=plan` skips file-conflict detection.

```
Wave 1: plan #11, #12, #13 in parallel
Wave 2: plan #14 (serial — shares skills/status/SKILL.md with #11)
Wave 3: plan #15 (serial — blocked by #14)
```

`PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false` (default `true`) falls back to one parallel blast. Step 1b reuses this plan.

## Usage gate

Read [references/usage-gate.md](references/usage-gate.md) at the first wave top. Decision line: `proceed`/`skip` → continue, `pause-5h`/`halt-7d` → obey. It runs before wave 1 and at the top of every plan wave, execute wave and campaign leg — never mid-wave.

## Headless contract

When `PIPELINE_HEADLESS=true`, fullsend and every dispatched stage MUST NOT end a turn on a question — apply the named default, log one `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>` line in the turn's TEXT (never via `echo`), continue.

- **merge-policy** (Step 9 non-greenlight merge). `HEADLESS-DEFAULT: merge-policy decision=apply-greenlight-gate reason=flag-is-the-answer` — gate the green subset (`--manual-merge` opts out); leave the rest.
- **unread-config-knob** (config key with no read site). `HEADLESS-DEFAULT: unread-config-knob decision=ignore-and-continue reason=not-a-contradiction`.
- **stall-triage** (Step 6/7 `agent-stalled`). `HEADLESS-DEFAULT: stall-triage decision=wait-out-timeout reason=never-kill-autonomously` — re-enter `Monitor` with the remaining budget.
- **ci-red-budget** (Step 6b `red-retry`/`red-budget-exhausted`). `HEADLESS-DEFAULT: ci-red-budget decision=autonomous-retry-then-flag reason=continue-the-wave`.
- **permission-denied** (`PermissionRequest` bridge timeout/deny, or a Bash result containing `denied by the Claude Code auto mode classifier`). `HEADLESS-DEFAULT: permission-denied decision=skip-step reason=classifier-deny site=<step> issue=#<N>` — retry an identical classifier-denied command ONCE, then skip the step, label unchanged, list it Flagged in Step 8's table, continue the slate; a bridge timeout/deny skips without retry.
- **ci-wait** (any PR-CI wait). `HEADLESS-DEFAULT: ci-wait decision=foreground-poll reason=print-mode-exits-on-idle` — poll FOREGROUND via `timeout 590 gh pr checks --watch` until terminal.

## Campaign mode

Read [references/campaign-mode.md](references/campaign-mode.md) when `--campaign` is in argv.

## Greenlight matrix

On an Approved `/pipeline:evaluate-issue-pr` verdict fullsend auto-merges (merge-commit) iff all four hold; otherwise the PR waits for manual merge with a `block-*` token.

```
| # | Condition                                                | Source                              |
|---|----------------------------------------------------------|-------------------------------------|
| 1 | Latest `## Evaluation` has `**Verdict:** Approved`       | scripts/auto-merge-gate.sh          |
| 2 | Every statusCheckRollup entry `conclusion == SUCCESS`    | gh pr view --json statusCheckRollup |
| 3 | `mergeable == MERGEABLE`                                 | gh pr view --json mergeable         |
| 4 | `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE) | gh pr view --json mergeStateStatus |
```

**block-capability-refused** — the caller threaded `PIPELINE_CAPABILITY_REFUSAL_SOURCES` and `scripts/check-capability-refusal.sh` resolves `CAPABILITY_REFUSAL=block`. Unset knob is a no-op.

**block-cage-tests-diff** — the PR modifies, removes or renames any `tests/test-cage-invariant-*.sh` (added cage tests never fire; an unreadable file list blocks with a WARN). A **hard block**: only an operator may weaken the cage.

**block-base-mismatch** — `baseRefName` must equal `PIPELINE_BASE_BRANCH`; `${PIPELINE_NEXT_BRANCH:-next}` is ALSO accepted ONLY when the issue carries `${PIPELINE_NEXT_LABEL:-next}` or legacy `next-major-release`; an empty base fails closed. Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → `block-cage-tests-diff` → verdict → `block-capability-refused` → `block-base-mismatch` → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, else one `block-*` per arm.

**Three opt-outs:** (1) `FULL SEND --manual-merge` — flag may appear anywhere in argv; (2) `/pipeline:evaluate-issue-pr <N> --manual-merge` — records the opt-out for the orchestrator's gate; a direct evaluator invocation never merges (finish via `scripts/finish-manual-merge.sh`); (3) a `manual-merge` issue label. `--spawn` is transport, not an opt-out.

## Auto-merge ownership

`scripts/auto-merge-gate.sh` (`auto_merge_should_fire <issue> <pr>`) returns one token and performs NO merge. **THE ORCHESTRATOR fires the gate** at Step 7, ONE batched call per wave, inline and `--spawn` PRs alike; `/pipeline:evaluate-issue-pr` posts a verdict and stops. Step 8 is the **fallback**: re-run the gate for any `pr-open` issue Step 7 did not merge. Release-please PRs go through Step 7b. Post-token procedure: [references/auto-merge-gate.md](references/auto-merge-gate.md).

1. **Plan**

   **1a. Ingest attachments.** Run the sanctioned `filter-trusted-comments.sh fetch-attachments` wrapper once per slate (a direct `fetch-issue-attachments.sh` call is hook-denied); idempotent, one line per issue:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-fetch-attachments.sh" <slate-issue-numbers>
   ```

   **1b. Dispatch plan (classify inline).** Wave by wave per `## Wave plan (pre-think)`, run `/pipeline:plan-issue N` for every ready issue with no pipeline label (one parallel Agent per issue, `description='plan-issue #<N> (PATH <X>)'`, or `plan-issue #<N>` pre-classification); wait for all. The planner consumes a fresh trusted `## Classification` (`createdAt >= issue.updatedAt`) or posts one and applies the path label — NO `/pipeline:classify-issue N` Agent. **PATH D exclusion.** Issues already carrying `quick-fix` or a `<!-- pipeline:path=D -->` marker are EXCLUDED here: their collapsed Step 6 Agent PRODUCES `## Classification`+`quick-fix` and `## Implementation Plan`+`plan-pending`. A planner-classified D lands `quick-fix`+`plan-pending`, takes the D auto-flip, and Step 6 CONSUMES those comments. The wave plan still includes D.
   - **Stage-model pin (mandatory):** before EACH plan dispatch resolve the model:
     ```bash
     PLAN_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan)
     ```
     It emits `ISSUE=`/`STAGE=`/`PATH=`/`MODEL=`/`REASON=` (exit 0; `MODEL=` always named). **ALWAYS pass `model=$MODEL`** — an unpinned dispatch inherits the session model — and relay `REASON=`. PATH A/B ⇒ `opus`; PATH C ⇒ `PIPELINE_PATH_C_MODEL_PLAN` (unset ⇒ `fable`); the W2 high-uncertainty carve-out forces `opus`. Unlabelled ⇒ PATH=B; pre-labelled D skips this (its collapsed dispatch carries the EXECUTE model).
   - **Usage gate** at the top of every plan wave per `## Usage gate`.
   - **Dispatch prompt contract (mandatory):** each plan-issue prompt MUST end with a directive that the *only* valid terminal states are (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 → success line, or (b) it exited non-zero → FAILED line. Returning the plan body in chat is a failure — the plan exists only once `post-plan.sh` posted `## Implementation Plan` and applied `plan-pending`. **Friction capture:** the prompt MUST also direct the subagent to end its report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines.
   - **`--debug-first` propagation:** under `--debug-first` each prompt carries `/pipeline:plan-issue N --debug-first` (Step 4a).
   - **Verify plan comments** after all plan agents complete:
     ```bash
     PLAN_COUNT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json <N> \
       | jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     ```
     `PLAN_COUNT == 0` (regardless of `plan-pending`) ⇒ re-run `/pipeline:plan-issue N` once; still missing ⇒ "Skipped (plan not posted)".
2. **Evaluate plans** — run `/pipeline:evaluate-issue-plan N` for every `plan-pending` issue (parallel, `description='evaluate-issue-plan #<N>'`); wait for all.

   **Stage-model pin (mandatory)** — **ALWAYS pass `model=$MODEL`**:
   ```bash
   PLAN_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan-eval)
   ```
   It emits `tier-max(plan model, PIPELINE_STAGE_MODEL_PLAN_EVAL)` (unset ⇒ `opus`): the **gate never lands below its producer** (`REASON=follows-producer`).
   **Trust profile:** `PLAN_EVAL_SPEC` carries `SKIP=true` (`PIPELINE_TRUST_PROFILE=lean`, non-W2 PATH A/D) ⇒ do NOT dispatch: run `transition-issue.sh <N> --to plan-approved --from plan-pending --comment "plan-eval skipped: lean profile"` (Step 4's helper) and record `plan_eval=skip`.
   **Plan gate:** read `GATE=<full|single|none|annotate>` (absent ⇒ `annotate`). `GATE=none` → the `SKIP=true` path via `transition-issue.sh`, comment `plan-eval skipped: plan-gate=none`, record `plan_eval=skip`. `GATE=single` → evaluate ONCE, then Step 3's capped arm. `GATE=full` → the full loop. `SKIP=true` wins.
   **Plan gate — annotate:** `GATE=annotate` → evaluate exactly once, then Step 3's annotate arm (approve via `transition-issue.sh`). `SKIP=true` still wins.
3. **Re-plan loop** — on "Revise": re-run `/pipeline:plan-issue N` then `/pipeline:evaluate-issue-plan N` (same descriptions), **each re-dispatch re-resolving its stage pin** (`resolve-stage-model.sh <N> plan` / `<N> plan-eval`, `model=$MODEL`). Max 3 iterations; still failing ⇒ skip and flag.

   **Binding rule:** from round 2, the re-plan prompt quotes the `Revise` prescription verbatim with "apply exactly this; add no new scenarios, tests or sections"; the re-evaluate prompt says "verify only that the prescribed change landed; a new finding is a new round only if BLOCKING".

   **Plan gate:** `GATE=single` ⇒ ONE evaluate + ONE binding re-plan, then approve HERE via `transition-issue.sh` (`plan-pending`→`plan-approved`), no second evaluate; record `plan_rounds=1`. `GATE=full` keeps the 3-iteration cap.

   **Plan gate — annotate:** under `GATE=annotate` a `Revise` triggers NO re-plan: approve HERE via `transition-issue.sh` (`plan-pending`→`plan-approved`) `--comment "plan-eval: Revise carried into execute (plan-gate=annotate)"`, record `plan_gate=annotate`, `plan_rounds=1`; execute applies `**Recommendations:**` as binding amendments. Exception: `**Scope:** structural` runs ONE binding re-plan, then approves without re-evaluating.

4. **Approve** — ONE wave call for every `plan-reviewed` issue; it runs `transition-issue.sh <N> --to plan-approved --from plan-reviewed` per issue (one `TRANSITION=` line each). Steps 2/3 call it with `--from plan-pending --comment "<text>"`:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-approve.sh" <issues now at plan-reviewed>
   ```
### Execute the slate WAVE BY WAVE (Steps 5–7 per wave)

Each wave's worktrees are cut from **`origin/<base>`'s tip** (Step 5's explicit `--base`), so wave N+1 inherits wave N's merged work.

**Pass A — wave order (`--stage=execute`, file-conflict waving on).** Parse the `Wave N:` lines:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=execute <approved-slate>
```

**Pass B — the edge map (`--emit-edges`).** Parse `EDGE #<N> blockers=<csv> files=<csv>` lines:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=execute --emit-edges <approved-slate>
```

The scoped-halt closure comes from the emitted edges, NOT from the human-readable `Wave N:` lines: multi-issue waves print no per-issue reason strings.

Per wave N: usage gate, then Steps 5 → 6 → 6a → 6b → 7 on ONLY that wave's issues, then the inter-wave base refresh.

5. **Set up worktrees** — per wave-N issue, sequentially:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base>] <branch-name> <issue-number>
   ```

   Both positionals required: `<branch-name>` is `feature/<slug>` (slug from the title, lowercase-hyphenated — the `skills/status/SKILL.md` "Branch and worktree naming convention"), `<issue-number>` a bare integer. Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh --base "$PIPELINE_BASE_BRANCH" feature/gmail-ci-filter 81
   ```

   **ALWAYS pass `--base`**: it cuts from the fetched `origin/<base>` tip (omitting it falls back to local HEAD). **Next-branch routing:** `${PIPELINE_NEXT_LABEL:-next}` or legacy `next-major-release` ⇒ `--base "${PIPELINE_NEXT_BRANCH:-next}"` (worktree and PR on the next branch); else `--base "$PIPELINE_BASE_BRANCH"`. **Do NOT invoke with only the issue number** — `setup-worktree.sh 81` fails the branch-prefix guard.
6. **Execute (wave N)** — dispatch ONLY wave N's issues (no cross-wave concurrency); conflict-free same-wave issues run concurrently.

   **`--spawn` override.** When `--spawn` is present, skip the inline batch: route all paths through the tmux `run-queue.sh` (skip-permissions, wave N's issues, `MAX_AGENTS` cap). PATH C reverts to `spawn-claude.sh` → `claude -p` — transport only; the session honors `PIPELINE_PATH_C_FANOUT` (`true` ⇒ its own `tdd-implementer` fan-out). Launch via `Bash` with `run_in_background: true` (never a foreground `sleep` poll) and wait with ONE `Monitor` on its stdout (queryable via `BashOutput`): filter `EVENT: (agent-stalled|agent-finished|queue-complete)`, `timeout_ms=7200000`. The runner writes `EVENT:` lines to stdout even with logs disabled — do NOT tail `queue-*.log`. `agent-finished outcome=failed` IS the failure signal; status lines every 3 minutes.

   **Split dispatch for PATH D + PATH B + PATH C.** Without `--spawn`, the wave's conflict-free PATH A/B/D issues — and PATH C — fan out as a **concurrent inline `Agent` batch in the FOREGROUND**, **max 3 concurrent inline**, consuming zero queue slots (a PATH C run-queue exists only under `--spawn`). Resolve specs in ONE call, then dispatch per `## Dispatch routing by path tier (reference)` with `model=$MODEL` from the `DISPATCH` line: PATH A/B — ONE `Agent(subagent_type='general-purpose', model=$MODEL, description='execute-issue-plan #<N> (PATH B inline)', ...)` (`(PATH A inline)` on A) applying the `tdd-implementer` discipline and the FULL suite before `gh pr create`. PATH C, `PATH_C_FANOUT=off` (default) — ONE `Agent(subagent_type='general-purpose', model=$MODEL, description='execute-issue-plan #<N> (PATH C inline)', ...)` as B; `PATH_C_FANOUT=on` — one `Agent(subagent_type='pipeline:tdd-implementer', ...)` per `target=<dir>` in its OWN per-leaf worktree (`scripts/path-c-split-worktree.sh`), same max-3 bound. PATH D — `Agent(subagent_type='pipeline:tdd-implementer', ...)`; the plugin-namespaced key resolves, the bare name never does. It is **one collapsed inline Agent** carrying classify+plan+execute forward in one context — not three separate dispatches; it CONSUMES carried-forward `## Classification`/`## Implementation Plan` comments, producing them only when absent. pr-eval stays a separate inline agent on every path (evaluator independence).

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-dispatch-specs.sh" <wave-N issues>
   ```

   **D is NOT exempt from wave discipline**: `plan-waves.sh --stage=execute` orders ALL paths over one file-conflict graph.

   **Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D (and PATH C under PATH_C_FANOUT=off) execute-issue-plan prompt MUST end with: the *only* valid terminal states are **(a)** PR opened and issue flipped to `pr-open`, reporting PR number + test status; **(b)** a FAILED line. Narrating an intention to "wait" — or returning prose instead of commit → push → `gh pr create` → label flip — is a **failure**: the turn ends when tool calls stop, so run to completion or block via `Monitor`/`BashOutput`. It MUST carry: stage ONLY plan paths via `git add <paths>`, never `git add -A|.|-u`; run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh"` pre-PR, abort on failure; the `tdd-implementer` discipline (failing test, `$PIPELINE_TEST_CMD` red, minimum impl, green, commit; ALL plan deliverables; FULL suite green before `gh pr create`). **Closing-review dispatch directive.** The resolver's `PRE_PR_REVIEW=` is truth: `on` ⇒ the execute agent runs Step 8's review before `gh pr create`, description `code review #<N>`; `off` ⇒ carry `PRE_PR_REVIEW=off`, log `PRE-PR-REVIEW: skipped reason=knob`. PATH D excluded. It may edit tests the plan names under `**Test changes:**`; one it finds WRONG is reported, never contorted around. **Git-anchoring + branch-assert.** Anchor every git command `git -C <worktree-abs-path>`; before ANY commit assert `git -C <worktree-abs-path> symbolic-ref --short HEAD` is the feature branch, else **STOP and report**. **Worktree-index staging.** `git -C <worktree-abs-path> add <paths>` into its OWN worktree index — never a bare `git add`, never `git -C <main-repo> add`. **Never `run_in_background` a test run.** Run the suite in the FOREGROUND, in chunks if needed — `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh" --chunk 1/4` … `--chunk 4/4`, one call each; every chunk must report `RESULT=pass` before `gh pr create`. Chunk it instead of backgrounding it. **No hypothesised concurrent writer.** If changes turn up somewhere you did not expect, report the observed facts (`git -C <dir> status --short`, `log --oneline -5`, the commands you ran) and STOP; never blame a hypothesised concurrent writer you have not directly observed — the likely cause is your own unanchored `git`. **Boot-fence `CLAUDE_PLUGIN_ROOT`.** `${CLAUDE_PLUGIN_ROOT}` is valid only in a Bash call that ran the Boot fence first. **Friction capture:** end the report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines. **One test file per `bash` invocation.** **Headless:** under `PIPELINE_HEADLESS=true` never end your turn on a question — apply the documented default, log `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>`, continue.

   **Per-dispatch clean-main attribution (mandatory).** A Step 6a boundary `CLEAN=dirty` names no one, so check PER DISPATCH.
   - **BEFORE each execute `Agent` dispatch** (single, collapsed-D, each PATH C leaf; role = `collapsed-D` | `single`) capture a baseline in a temp path (the gated logs tree is absent on default hosts ⇒ `CLEAN=error REASON=missing-baseline`):
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main-baseline "$MAIN_REPO" "${TMPDIR:-/tmp}/pipeline-clean-main/<N>-<role>.baseline"
     ```
   - **IMMEDIATELY AFTER that `Agent` returns** — before any other action on the issue or Step 6a:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main "$MAIN_REPO" --since "${TMPDIR:-/tmp}/pipeline-clean-main/<N>-<role>.baseline" --issue <N>
     ```
   - `CLEAN=ok` / `CLEAN=untracked-only` / `CLEAN=pre-existing` → continue (on `untracked-only`, do NOT stash operator paths; `pre-existing` = dirty path set unchanged — the 6a check still sees writes onto it).
   - `CLEAN=leak ISSUE=<N> PATHS=<...>` → WARN naming that agent's `ISSUE=`, role and `PATHS=`. Recovery is **orchestrator-owned**: `git -C "$MAIN_REPO" restore --staged -- <paths>` then `git -C "$MAIN_REPO" stash push -- <paths>` (path-scoped, never untracked-sweeping or whole-tree). MUST NOT resume, re-prompt or `SendMessage` the leaking agent. Re-capture the baseline.
   - `CLEAN=error REASON=missing-baseline` → advisory; re-capture and continue.
   - Step 6a's `--clean-main "$MAIN_REPO"` (no `--since`) stays the backstop, notably for `--spawn`. Neither check halts the wave.

   ### Triage on agent-stalled wakes

   Each filter match wakes the orchestrator:
   - `EVENT: queue-complete` — terminal; proceed to the next phase.
   - `EVENT: agent-stalled issue=<N>` — idle CPU **and** frozen pane across `PIPELINE_STALL_POLL_THRESHOLD` polls; run the triage below, re-enter `Monitor` with the SAME `timeout_ms` budget.
   - `EVENT: agent-finished outcome=failed issue=<N>` — optional triage; re-enter `Monitor`.
   - `EVENT: agent-finished outcome=success issue=<N>` — no-op wake; re-enter `Monitor`.
   - `EVENT: agent-finished outcome=manual-merge-required reason=<block-reason> issue=<N>` — no-op wake (the gate skipped the merge); `reason=` is its token (`block-verdict`, `block-ci`, `block-mergeable`, `block-mergestate`, `block-label`, `block-flag`, `block-cage-tests-diff`, `block-capability-refused`, `block-base-mismatch`, `unknown`), NEVER an approval. Re-enter `Monitor`; merge by hand (`gh pr merge <PR> --merge --delete-branch`) or via `## Merge orchestration (reference)`.

   **Triage on `agent-stalled`.** Re-`capture-pane` to confirm it is *still* frozen, inspect (`tmux capture-pane -t "$PIPELINE_TMUX_SESSION:issue-<N>" -p`; `pstree -p <pid>`), and offer the user:
   1. **Kill the wedged subscript only** — `kill <child-pid>`.
   2. **Kill the whole executor** — `tmux send-keys -t "$PIPELINE_TMUX_SESSION:issue-<N>" C-c`.
   3. **Wait out the timeout** — re-enter `Monitor`.
   4. **Skip the issue** — `tmux kill-window -t "$PIPELINE_TMUX_SESSION:issue-<N>"`.

   Runner NEVER kills autonomously; the user prompt is the kill gate.

6a. **Post-dispatch completion verification (mandatory).** Read [references/post-dispatch-verification.md](references/post-dispatch-verification.md) once the inline batch returns, before Step 6b.

6b. CI-fix loop (wave N) — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]` (colon-LESS: unset ⇒ ON, `=""` ⇒ OFF). Per wave-N `pr-open` issue run `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and act on `ACTION=`:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` owns issue→PR resolution, the retry counter, the failure log and the `human` label.

7. **Evaluate PRs (wave N)** — preflight every wave-N `pr-open` issue, run `/pipeline:evaluate-issue-pr N` for each `PREFLIGHT=ok`, then fire the gate (`## Greenlight matrix`).

   **Preflight.** One call per wave; each `PREFLIGHT issue=#N` line wraps `pr-eval-preflight.sh`'s verdict. `block` ⇒ dispatch nothing, report `block-<REASON>`; `PREFLIGHT=ok` ⇒ dispatch with the line VERBATIM in the prompt. Tokens and fallbacks: [references/pr-eval-preflight.md](references/pr-eval-preflight.md).
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-preflight.sh" <wave-N pr-open issues>
   ```

   **Stage-model pin (mandatory)** — inline or queued, **ALWAYS pass `model=$MODEL`**:
   ```bash
   PR_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> pr-eval)
   ```
   `PIPELINE_STAGE_MODEL_PR_EVAL` (unset ⇒ `opus`) is a REAL pin; relay any stderr WARN.

   **PR-eval invocation mode.** Same evaluator steps, only CWD differs:
   1. **Inline `Agent(...)` (default — PATH A, PATH B, PATH C, PATH D).** The prompt carries the worktree path + issue number; the evaluator first runs `cd <worktree-absolute-path>`. Thread the opt-out as `MANUAL_MERGE=1` in the prompt.
   2. **`--spawn` — `${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh` / `claude -p` via the run-queue (all paths; the legacy PATH C transport).** Starts in the worktree, no `cd`; `spawn-claude.sh --manual-merge` exports `MANUAL_MERGE=1`.

   **`--spawn` override.** Route PR-eval through `run-queue.sh --skill evaluate-issue-pr` (`PREFLIGHT=ok` issues only), `run_in_background: true`, awaited with Step 6's waiter (one `Monitor` via `BashOutput`, filter `EVENT: (agent-stalled|agent-finished|queue-complete)`, `timeout_ms=7200000`) and triage.

   **Inline PR-eval dispatch prompt contract (mandatory).** Every inline `evaluate-issue-pr` prompt MUST end with: the *only* valid terminal states are **(a)** a `## Evaluation` comment with an explicit `**Verdict:**` line; **(b)** a FAILED line. The ORCHESTRATOR, not the evaluator, fires the greenlight gate — the prompt says so and demands no `block-*` token. Narrating an intention to "wait" / "await CI" instead of posting the verdict is a **failure**; block on CI via `Monitor`/`BashOutput`. **Preflight trust:** carry the preflight line verbatim; the evaluator re-runs none of its checks. **Friction capture:** end with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines. **Headless:** under `PIPELINE_HEADLESS=true` never end your turn on a question — apply the documented default, log `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>`, continue.

   **Fire the gate per WAVE (mandatory).** Once the wave's evaluators return, ONE call — inline and `--spawn` alike. It sources `scripts/auto-merge-gate.sh`, threads `PIPELINE_CAPABILITY_REFUSAL_SOURCES` via `check-capability-refusal.sh --resolve-sources`, and prints `GATE: issue=#<N> pr=#<P> reason=<token>` per issue:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-gate.sh" <wave-N issues whose evaluator returned>
   ```
   On any token, follow [references/auto-merge-gate.md](references/auto-merge-gate.md).
7b. **Auto-merge green release PRs (opt-in)** — after step 7 (Evaluate PRs), before step 8. Fires only when `PIPELINE_RELEASE_PR_AUTO_MERGE=true` (default **off**) AND a release PR has `ci=pass`.

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_RELEASE_PR_AUTO_MERGE="${PIPELINE_RELEASE_PR_AUTO_MERGE:-false}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-release-prs.sh"
   ```

### Inter-wave base refresh (fetch-only, before wave N+1)

**Wait for wave N's PRs to merge before setting up wave N+1**, then:

```bash
git -C "$MAIN_REPO" fetch --quiet origin "$PIPELINE_BASE_BRANCH"
```

It moves no local ref; Step 5's `--base` then cuts wave N+1 from the refreshed `origin/<base>`, which inherits wave N's merged work.

### Scoped halt-and-report (closure sourced from `--emit-edges`)

A wave-N PR that fails to merge does **not** halt every later wave:

- **Transient (defer, do NOT halt):** `block-ci` or `pending` — let Step 6b run to terminal; green ⇒ proceed, `red-budget-exhausted` ⇒ hard block.
- **Hard block (scoped halt):** `block-mergestate`, `block-mergeable`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-cage-tests-diff`, or an exhausted CI retry budget.

**Dependency closure.** Seed `{blocked issue}`; walk the `EDGE` map to a fixpoint, adding any issue whose `blockers=` names a member or whose `files=` shares a path with one, **transitively** — computed from the emitted edges, NOT from the human-readable `Wave N:` lines. In-closure issues are reported `Skipped (depends on blocked #<N>)`; **independent later-wave issues outside the closure may still proceed**; merged work is never rolled back.

### Self-mutation callout

An issue editing the fullsend machinery is a self-mutation: it takes effect **only after merge** (and the operator's pull). Work happens in an isolated **worktree**.
8. **Report** — a summary table of every issue's final stage and flags, with a **Classification mismatch** column (current-label path vs recommended, when they diverged):
   ```
   FULL SEND COMPLETE
   ================================================================
   Issue  Title                    Classification mismatch   Auto-merged?   Result
   --------------------------------------------------------------------------------
   #N     <title>                  B / C (med)               no (block-ci)  PR approved / Flagged / Skipped (plan failed)
   #N     <title>                                            yes (step8)    PR merged
   ================================================================
   The `Auto-merged?` column reflects the per-PR gate outcome: `yes (step7)` — the orchestrator's Step 7 gate merged it when that PR's evaluator returned; `yes (step8)` — Step 8's fallback pass merged it; `no (<block-reason>)` — manual merge required.
   ```
9. **Stop** — do NOT merge unless the greenlight matrix held at Step 7 (or Step 8’s fallback pass). Wait for explicit user confirmation before any non-greenlight merge.

## Dispatch routing by path tier (reference)

Read [references/dispatch-routing.md](references/dispatch-routing.md) when resolving a path tier's dispatch shape.

## Merge orchestration (reference)

The Step 7 gate merges the green subset. Before the sequential merge loop run the advisory overlap scan (never blocks):

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/fullsend-merge-order.sh"
```

It runs `detect_merge_overlap` pairwise over `pr-open` PRs and `recommend_merge_order` (fewest-overlap-first); merge in its `ORDER:` order. Per merge: base diverges ⇒ `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE`; `mergeable` conflict ⇒ rebase in the worktree, push `--force-with-lease`, retry; check the title with `scripts/check-conventional-title.sh`.
