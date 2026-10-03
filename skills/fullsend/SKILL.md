---
name: fullsend
description: Run the full pipeline autonomously end-to-end (classify → plan → evaluate → execute → evaluate PR → auto-merge greenlit PRs) without intermediate confirmations. Usage: /pipeline:fullsend [issue_numbers...] [--manual-merge] [--spawn] [--campaign] [--debug-first]
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

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Full Send — the autonomous entry point

`/pipeline:fullsend` is the canonical autonomous entry to the pipeline. It chains classify → plan → eval-plan → execute → eval-pr → greenlight-merge across a slate of issues without intermediate confirmations.

```
slate → wave plan → classify+plan (waves) → eval-plan → approve → execute → eval-pr → greenlight → merge
```

Invoked directly as `/pipeline:fullsend [issue_numbers...] [--manual-merge]` — the **sole** autonomous entry point. The legacy `full send` magic-string delegator in the old `/pipeline:run` skill is retired: `/pipeline:run` is now a thin deprecated alias for the read-only `/pipeline:status` and does NOT intercept `full send` / `full-send` / `fullsend`. Autonomous advancement always starts here.

Argv shape: `[issue_numbers...] [--manual-merge] [--spawn] [--campaign] [--debug-first]`, position-independent (the flag-parsing rule below preserves the prior behavior). The `--spawn` flag (position-independent, cannot collide with bare-integer issue numbers — same parse rule as `--manual-merge`) forces the tmux run-queue transport for everything fullsend would otherwise run inline (Step 6 execute + Step 7 PR-eval, all paths → run-queue). **When `--spawn` is absent, all paths execute inline** (A/B/C/D execute inline — C as a per-leaf-worktree fan-out; B PR-eval inline, C PR-eval inline by default) — the `--spawn` flag is purely additive, reverting C to the legacy run-queue transport. The `--campaign` flag (also position-independent, same bare-integer-safe parse rule, composes freely with `--spawn` and `--manual-merge`) wraps the whole slate in the coordinated-leg OUTER loop documented in `## Campaign mode` below — when absent, fullsend runs the single wave-by-wave pass exactly as today. The `--debug-first` flag (also position-independent, cannot collide with bare-integer issue numbers — same parse rule as `--manual-merge`/`--spawn`, composes freely with the other flags) forces every dispatched `/pipeline:plan-issue N` (Step 1b) to run plan-issue's Step 4a diagnosis gate before drafting — propagated to the subagent prompt as documented in Step 1b below; when absent, plan-issue's gate fires only for issues carrying the durable `needs-debug` label.

PATH D (quick-fix) is NO LONGER path-agnostic to fullsend at the execute stage: fullsend now DOES branch D into a SPLIT DISPATCH (see Step 6). PATH-D-specific *lifecycle* behavior (auto-flip plan-pending → plan-approved, inline tdd-implementer execute dispatch, Step 8 skip) is owned by fullsend's `## Dispatch routing by path tier (reference)` section below and by /pipeline:execute-issue-plan (skills/execute-issue-plan/SKILL.md Step 8 early-return). What fullsend adds on top is a DISPATCH split: within each wave, by DEFAULT (no `--spawn`) all conflict-free A/B/C/D issues fan out as a **concurrent inline `Agent` batch in the FOREGROUND** at the same wall-clock (Step 6). Per #748, PATH B execute joined the inline foreground side alongside A/D (no `spawn-claude.sh` / `claude -p`); per #749/#891/#896, PATH C joined too — each `target=<dir>` leaf runs inline in its own per-leaf worktree, reassembled by cherry-pick. The tmux run-queue is used ONLY under `--spawn` (#750), which reverts PATH C to the legacy `spawn-claude.sh` transport and routes A/B/D onto the queue as well.

## Wave plan (pre-think)

Before any dispatch, fullsend pre-thinks the slate via `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=classify <ready-issue-numbers>` and captures stdout as the wave plan. Waves are processed serially; within a wave, issues dispatch in parallel. `plan-waves.sh` groups issues honoring (1) priority tiers, (2) explicit `blocked by #N` / `depends on #N` annotations in issue bodies, and (3) shared-file conflicts extracted via body-substring grep — when two issues touch the same file path, the second is deferred. The `--stage=classify` flag skips file-conflict detection because classify/plan agents are read-only, so cross-references in issue bodies must not over-serialize them.

```
Wave 1: classify #101, #102, #103 in parallel
Wave 2: classify #104 (serial — shares skills/status/SKILL.md with #101)
Wave 3: classify #105 (serial — blocked by #104)
Wave 4: classify #106, #107 in parallel
Wave 5: classify #108 in parallel
```

Gated by `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED` (default `true`); when `false`, fullsend falls back to single-blast parallel dispatch. The same wave-by-wave discipline applies to plan-issue dispatch in Step 1b — the wave plan is reused; the planner is not re-run.

## Usage gate (#969)

Read [references/usage-gate.md](references/usage-gate.md) at the first wave top; the decision-line branch is: `proceed` → continue, `pause-5h`/`halt-7d` → obey it.

## Headless contract

When `PIPELINE_HEADLESS=true`, fullsend and every dispatched stage MUST NOT end a turn on a question — at each site below apply the named default, log one `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>` line, and continue.

- **merge-policy** covers Step 9's non-greenlight-merge confirmation. `HEADLESS-DEFAULT: merge-policy decision=apply-greenlight-gate reason=flag-is-the-answer` — gate the green subset (`--manual-merge` opts out); leave non-greenlight PRs unmerged, reported.
- **unread-config-knob** covers any config key with no read site. `HEADLESS-DEFAULT: unread-config-knob decision=ignore-and-continue reason=not-a-contradiction` — ignore and continue.
- **stall-triage** covers Step 6/7's four-option `agent-stalled` prompt. `HEADLESS-DEFAULT: stall-triage decision=wait-out-timeout reason=never-kill-autonomously` — re-enter `Monitor` with the remaining budget.
- **ci-red-budget** covers Step 6b's `red-retry`/`red-budget-exhausted` rows. `HEADLESS-DEFAULT: ci-red-budget decision=autonomous-retry-then-flag reason=continue-the-wave` — retry autonomously; on exhaustion mark Flagged, skip `evaluate-issue-pr`, continue the wave.
- **permission-denied** covers a `PermissionRequest` bridge timeout or deny. `HEADLESS-DEFAULT: permission-denied decision=skip-step reason=bridge-timeout|operator-deny` — skip the step, never retry.
- **ci-wait** covers every wait on PR CI; never end a turn while CI or an agent is still running. `HEADLESS-DEFAULT: ci-wait decision=foreground-poll reason=print-mode-exits-on-idle` — the orchestrator waits FOREGROUND via `timeout 590 gh pr checks <PR> --repo "$PIPELINE_REPO" --watch --interval 30`, repeated across turns until terminal; never `Monitor`, never `run_in_background`, never narrate waiting.

Interactive mode (knob unset/false) is unchanged — operator prompts stay.

## Campaign mode

Read [references/campaign-mode.md](references/campaign-mode.md) when `--campaign` is in argv.

## Greenlight matrix

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, fullsend auto-merges (merge-commit) if and only if all four conditions hold; otherwise the PR is left for manual merge with a `block-*` reason token.

```
| # | Condition                                                | Source                              |
|---|----------------------------------------------------------|-------------------------------------|
| 1 | Latest `## Evaluation` has `**Verdict:** Approved`       | scripts/auto-merge-gate.sh          |
| 2 | Every statusCheckRollup entry `conclusion == SUCCESS`    | gh pr view --json statusCheckRollup |
| 3 | `mergeable == MERGEABLE`                                 | gh pr view --json mergeable         |
| 4 | `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE) | gh pr view --json mergeStateStatus |
```

**block-capability-refused** (#1233) fires when the caller threaded `PIPELINE_CAPABILITY_REFUSAL_SOURCES` and `scripts/check-capability-refusal.sh` resolves a `CAPABILITY_REFUSAL=block` verdict for the issue — a leaf emitted the `CAPABILITY-REFUSED:` sentinel (#1225's contract) and the work is incomplete. Unset/empty knob is a no-op.

**block-cage-tests-diff** (#1304) fires when the PR modifies, removes, or renames (either direction — the old path is matched too) any `tests/test-cage-invariant-*.sh`, the behaviour tests pinning each guard hook's deny contract. Newly added cage tests never fire it; an unreadable file list blocks with a WARN. It is a **hard block**: only an operator may weaken the cage.

**block-base-mismatch** is enforced as defense-in-depth — PR `baseRefName` must equal `PIPELINE_BASE_BRANCH` (see #295). **Next-branch aware (#1148):** `baseRefName == ${PIPELINE_NEXT_BRANCH:-next}` is ALSO accepted, but ONLY when the PR's issue is next-routed — carries `${PIPELINE_NEXT_LABEL:-next}` or the legacy alias `next-major-release` (resolved via `gh issue view --json labels`). A PR targeting the next branch for a non-next issue still `block-base-mismatch`; an empty base still fails closed. Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → `block-cage-tests-diff` → verdict → `block-capability-refused` → `block-base-mismatch` → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, `block-flag`, `block-label`, `block-cage-tests-diff`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-ci`, `block-mergeable`, `block-mergestate`.

**Three opt-outs:** (1) `FULL SEND --manual-merge` — flag may appear anywhere in argv (cannot collide with issue numbers, which are bare integers); (2) `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations; (3) a `manual-merge` label on the issue for per-issue control without re-typing the flag. (`--spawn` is the orthogonal transport flag — see Step 6/7 — not a merge opt-out.)

## Auto-merge ownership

The gate logic lives in `scripts/auto-merge-gate.sh` (function `auto_merge_should_fire <issue> <pr>` returning a single token — it performs NO merge). **THE ORCHESTRATOR fires the gate** at Step 7, once per `pr-open` PR, immediately after that PR's evaluator returns its verdict (#1444): inline PATH A/B/C/D evaluations and `--spawn` queued ones alike. `/pipeline:evaluate-issue-pr` posts a verdict and stops — it no longer merges. Step 8 (Report) remains the **fallback** pass: it re-runs the gate for any `pr-open` issue Step 7 did not merge (e.g. the orchestrator was interrupted between verdict and gate fire). Release-please PRs are out of scope of this gate; they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` (Step 7b), unchanged. The post-token merge procedure lives in [references/auto-merge-gate.md](references/auto-merge-gate.md); do not re-document it here.

1. **Plan**

   **1a. Ingest attachments for the slate.** For each issue in the slate (the ready-issue set being processed this wave), run the sanctioned `filter-trusted-comments.sh fetch-attachments <N>` fence (#1340 — a direct fetch-issue-attachments.sh call is denied by the enforce-comment-trust hook) so downstream classify/plan/execute/evaluate-pr agents have screenshots and binary evidence available locally:

   ```bash
   for N in <slate-issue-numbers>; do
     PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" fetch-attachments "$N" 2>/dev/null \
       | head -1
   done
   ```

   The helper is idempotent — repeat invocations cost zero `gh api` calls. The `head -1` cap keeps wave-log output to one line per issue. This is the autonomous-mode ingestion site; `/pipeline:status` step 0 does NOT fetch attachments. Interactive single-issue planning fetches at `/pipeline:plan-issue` step 3b instead.

   **1b. Dispatch classify and plan.** Process wave by wave per the `## Wave plan (pre-think)` section above — before dispatching plan-issue, run `/pipeline:classify-issue N` for every ready issue that lacks a fresh `## Classification` comment (the comment's `createdAt >= issue.updatedAt`) (dispatch in parallel, one Agent per issue). Each classify run writes the Classification comment AND applies the path label (`docs-only` or `multi-task`). Cached issues skip dispatch. Then run `/pipeline:plan-issue N` for every issue with no pipeline label (in parallel, one Agent per issue). Wait for all to complete. **PATH D exclusion.** PATH D (`quick-fix`) issues are EXCLUDED from this per-stage classify/plan dispatch — their classify+plan stages run INSIDE the single collapsed foreground inline `Agent` dispatched at execute (Step 6), emitting `## Classification`+`quick-fix` and `## Implementation Plan`+`plan-pending` as inline side-effect checkpoints. Only A/B/C issues go through this Step 1b per-stage classify/plan dispatch. (The `## Wave plan (pre-think)` ordering still includes D — only the per-stage classify/plan *dispatch* is what D skips.)
   - **Stage-model pin (#1186, mandatory):** before EACH `/pipeline:plan-issue N` Agent dispatch, resolve the plan model from the single-source stage resolver and pass it verbatim — a plan dispatch with no `model=` does not "inherit Opus", it inherits whatever the session model is:
     ```bash
     PLAN_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan)
     ```
     It emits `ISSUE=`/`STAGE=`/`PATH=`/`MODEL=`/`REASON=` (always exits 0; `MODEL=` is ALWAYS a named model). **ALWAYS pass `model=$MODEL`** on the plan `Agent(...)`, and relay `REASON=` in the wave log. Defaults: PATH A/B ⇒ `opus`, PATH C ⇒ `PIPELINE_PATH_C_MODEL_PLAN` (unset ⇒ `fable` — cross-unit leaf-boundary meshing is Fable's edge), with the W2 high-uncertainty carve-out forcing `opus` over both the default and an explicit knob. The **classify** dispatch is deliberately NOT pinned (it still inherits — the cheap-stage open item); PATH D is excluded from this step entirely and its collapsed inline dispatch carries the resolved EXECUTE model instead.
   - **Usage gate at every wave top (#969):** before dispatching wave 1 (the pre-flight) and again at the top of EVERY classify/plan wave iteration, run the gate and obey its decision line per `## Usage gate (#969)`.
   - **Dispatch prompt contract (mandatory):** each `/pipeline:plan-issue N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 and it reports the success line, or (b) `post-plan.sh` exited non-zero and it reports the FAILED line. Returning the plan body in chat is a failure — the plan does not exist until `post-plan.sh` has posted the `## Implementation Plan` comment and applied the `plan-pending` label. A `general-purpose` subagent may never load `skills/plan-issue/SKILL.md` (it can treat `/pipeline:plan-issue N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. **Friction capture:** the prompt MUST also direct the subagent to end its final report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines, one per doc/skill/hook claim that disagreed with reality.
   - **`--debug-first` propagation (#997):** when fullsend was invoked with `--debug-first`, each dispatched plan-issue Agent's prompt MUST carry the flag (e.g. `/pipeline:plan-issue N --debug-first`) so the subagent runs plan-issue's Step 4a diagnosis gate. The flag is a one-off invocation toggle and does NOT live on the issue, so it has to be threaded through the dispatch explicitly. The durable `needs-debug` LABEL, by contrast, flows through for free — the dispatched plan-issue resolves it from the issue's OWN labels, so an issue already tagged `needs-debug` hits the gate with or without the flag. Propagation is therefore needed only for the one-off `--debug-first` flag, never for the label.
   - **Verify plan comments:** After all plan-issue agents complete, for each issue that was targeted (had no pipeline label at the start of this step), confirm a plan comment was posted:
     ```bash
     PLAN_COUNT=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json <N> \
       | jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     ```
     If any targeted issue has `PLAN_COUNT == 0` (regardless of whether `plan-pending` was added), the plan-issue agent failed. Re-run `/pipeline:plan-issue N` for that issue (max 1 retry). If still missing after retry, skip the issue and flag it in the final report as "Skipped (plan not posted)".
2. **Evaluate plans** — run `/pipeline:evaluate-issue-plan N` for every `plan-pending` issue (in parallel, one Agent per issue). Wait for all to complete.

   **Stage-model pin (#1186, mandatory).** Before each `evaluate-issue-plan` Agent dispatch, resolve `PIPELINE_STAGE_MODEL_PLAN_EVAL` through the same single source and **ALWAYS pass `model=$MODEL`**:
   ```bash
   PLAN_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan-eval)
   ```
   The resolver emits `tier-max(this issue's plan model, PIPELINE_STAGE_MODEL_PLAN_EVAL)` (unset ⇒ `opus`), so the **gate never lands below its producer** — a PATH C plan produced on `fable` is gated on `fable` (`REASON=follows-producer`), and a knob set below the producer cannot drop it. Plan approval is an auto-gate with no human behind it in fullsend, which is why equal-tier is acceptable but below-tier is not.
   **Trust profile (#1291):** if `PLAN_EVAL_SPEC` carries `SKIP=true` (`PIPELINE_TRUST_PROFILE=lean`, non-W2 PATH A/D), do NOT dispatch the evaluator: run `gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-pending"`, post the audit comment `plan-eval skipped: lean profile`, and record `plan_eval=skip` for Step 6's log line.
   **Plan gate (#1429):** read the optional `GATE=<full|single|none|annotate>` token from `PLAN_EVAL_SPEC` (absent ⇒ `annotate`). `GATE=none` → do NOT dispatch the evaluator: same skip path as `SKIP=true` above, audit comment `plan-eval skipped: plan-gate=none`, record `plan_eval=skip`. `GATE=single` → dispatch the evaluator exactly ONCE, then hand its verdict to Step 3's capped arm. `GATE=full` → today's loop. `SKIP=true` wins when both fire.
   **Plan gate — annotate (#1435):** `GATE=annotate` → dispatch the evaluator exactly once, then hand its verdict to Step 3's annotate arm. `SKIP=true` still wins.
3. **Re-plan loop** — for any issue whose evaluation verdict is "Revise": re-run `/pipeline:plan-issue N`, then `/pipeline:evaluate-issue-plan N` — **each re-dispatch re-resolves its stage pin** exactly as in Step 1b / Step 2 (`resolve-stage-model.sh <N> plan` / `<N> plan-eval`) and always passes `model=$MODEL`. Repeat until all pass (max 3 iterations per issue). If an issue still fails after 3 iterations, skip it and flag it in the final report.

   **Binding rule (#1317):** from round 2 on, the re-plan dispatch prompt MUST quote the evaluator's `Revise` prescription verbatim with "apply exactly this; add no new scenarios, tests or sections". The follow-up evaluate dispatch MUST say "verify only that the prescribed change landed; a new finding is a new round only if BLOCKING".

   **Plan gate (#1429):** `GATE=single` caps this loop at ONE evaluate dispatch plus ONE re-plan — on `Revise`, re-plan once with the binding #1317 prescription above, then approve HERE with `gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-pending"` (Step 4's `plan-reviewed` filter never sees it) and NO second `evaluate-issue-plan` dispatch; record `plan_rounds=1`. `GATE=full` keeps the 3-iteration cap.

   **Plan gate — annotate (#1435):** under `GATE=annotate` a `Revise` triggers NO re-plan and NO re-evaluate: approve HERE with `gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-pending"`, post the audit comment `plan-eval: Revise carried into execute (plan-gate=annotate)`, and record `plan_gate=annotate`, `plan_rounds=1` — execute reads the evaluation's `**Recommendations:**` as binding amendments. The ONE exception: a `Revise` carrying `**Scope:** structural` runs ONE binding #1317 re-plan, then approves the same way without re-evaluating.

4. **Approve** — for every issue now at `plan-reviewed`, run:
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-reviewed"
   ```
### Execute the slate WAVE BY WAVE (Steps 5–7 per wave)

The execute stage runs the approved slate **wave by wave**, not as a single blast. Each wave's worktrees are cut from **`origin/<base>`'s tip** (Step 5 always passes an explicit `--base`) so that wave N+1 inherits wave N's merged work. Two distinct `plan-waves.sh` passes drive this loop:

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

For each wave N, in wave order, serially run Steps 5 → 6 → 6b → 7 against ONLY that wave's issue numbers, then perform the **inter-wave base refresh** before starting wave N+1. **At the top of each execute wave (before Step 5), run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"` and obey its decision line per `## Usage gate (#969)`** — pause/halt happens between waves, never mid-wave.

5. **Set up worktrees** — for wave N, run `setup-worktree.sh` for each issue in wave N (sequentially), cut from **`origin/<base>`'s tip** via an explicit `--base`. Full invocation signature:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base>] <branch-name> <issue-number>
   ```

   Both positional args are required. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short) — same convention as `skills/status/SKILL.md` ("Branch and worktree naming convention"). `<issue-number>` is the bare integer.

   Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh --base "$PIPELINE_BASE_BRANCH" feature/gmail-ci-filter 81
   ```

   **ALWAYS pass `--base` explicitly.** An explicit `--base` actuates a fetch + cut from `origin/<base>`; omitting it falls back to LOCAL HEAD, which is exactly the staleness this loop avoids.

   **Next-branch routing (#1128).** Before invoking `setup-worktree.sh`, resolve the issue's labels. If the issue carries `${PIPELINE_NEXT_LABEL:-next}` OR the legacy `next-major-release` alias, pass `--base "${PIPELINE_NEXT_BRANCH:-next}"` so the worktree is cut from — and the PR targets — the next-integration branch (`setup-worktree.sh` fetches/creates it; see the actuation in `scripts/setup-worktree.sh`). For all other issues, pass `--base "$PIPELINE_BASE_BRANCH"`. Example for a next-labelled issue: `setup-worktree.sh --base next feature/<slug> <issue-number>`.

   **Do NOT invoke with only the issue number** — the script will reject it as of #350. A bare integer like `setup-worktree.sh 81` fails the branch-prefix guard because `81` is not a `feature/<slug>` shape; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.

   **Base-tip note (the #626 fix, refreshed by #1214).** An explicit `--base` is an actuating declaration: `setup-worktree.sh` fetches `origin/<base>` and adds the worktree from that remote tip, so a wave inherits every merged-on-remote PR. The local base ref is neither consulted nor moved by this actuation. The #626 staleness class stays closed by this fresher mechanism — no inter-wave local-branch advance is needed anymore, only the fetch-only base refresh (below), because Step 5 reads directly off `origin/<base>`.
6. **Execute (wave N)** — launch wave N's worktrees via the tmux queue runner with skip-permissions enabled (equivalent to user answering "tmux / y" at the launch prompt). Scope `run-queue.sh` to ONLY wave N's issue numbers — never mix issues from a later wave into the same queue (no cross-wave concurrency). **Within-wave parallelism is preserved:** same-wave issues that have no dependency or file-conflict edge between them still run concurrently up to run-queue's `MAX_AGENTS` cap — do not over-serialize within a wave. Launch the queue runner via `Bash` with `run_in_background: true` — do NOT use a foreground `while ... sleep ... grep` poll loop. Wait for terminal events with a single `Monitor` invocation against the queue runner's captured stdout stream — the `Bash` tool's `run_in_background: true` task captures the runner's stdout, queryable via the `BashOutput` tool. That captured stdout is the always-on wake channel because `log()` (`scripts/run-queue.sh:136-142`) emits every `EVENT:` line to stdout unconditionally, even when `PIPELINE_LOGS_ENABLED=false` (the `queue-*.log` file is gated and may not exist on consumer hosts — do NOT tail it). Invocation shape: `Monitor` on the bash task's stdout stream with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000` (preserves the existing 2h worst-case wait budget). Per Monitor's coverage rule, the filter MUST cover every terminal state (failure + completion) so a crash is never silent — `agent-finished outcome=failed` IS the per-agent failure signal (the runner does not emit a separate `agent-failed`). Status updates are emitted automatically by the queue runner every 3 minutes (configurable via `STATUS_INTERVAL`).

   **`--spawn` override (#750).** When `--spawn` is present in the fullsend argv, SKIP the inline foreground `Agent` batch entirely and route **every path's execute through the tmux `run-queue.sh`** — no inline at all. Scope the queue to wave N's issue numbers exactly as below. **PATH C execute is now inline-by-default (#749), so `--spawn` routes it back to the legacy `spawn-claude.sh` → `tdd-implementer` fan-out** (its reversible escape hatch — a LIVE effect on C, no longer a no-op); A/B/D execute also route onto the run-queue as before. When `--spawn` is absent, the split-dispatch default below applies unchanged (A/B/C/D inline foreground, all bounded at the same **max-3 foreground** concurrency — per-leaf worktrees mean C is no longer git-index-capped, #896).

   **Split dispatch for PATH D (#700) + PATH B (#748) + PATH C (#749).** Within wave N, partition the wave's issues by path. By DEFAULT (no `--spawn`) the wave's **conflict-free PATH A/B/C/D issues fan out as the inline foreground batch** at the same wall-clock — the C-only tmux **run-queue is now used ONLY when `--spawn` is set** (#750). The conflict-free PATH A/B/D issues fan out CONCURRENTLY as an inline `Agent` batch in the FOREGROUND, dispatched together in a single foreground batch, bounded at **max 3 concurrent inline** agents. **PATH C fans out inline too** — the orchestrator reads the plan and dispatches one `Agent(subagent_type='pipeline:tdd-implementer', ...)` per `target=<dir>`, each in its OWN per-leaf worktree (`scripts/path-c-split-worktree.sh` setup/reassemble/teardown, #896) so concurrent leaves never share a git index (the #894 c+d collision). With isolated indexes the fan-out is **bounded only by orchestrator context, not a git-index cap** — the #894/#896 live branch test confirmed leaf returns are ~one line each with negligible context cost, so non-overlapping targets fan out concurrently up to the same **max-3 foreground bound** as A/B/D (keep leaf returns terse). The earlier conservative 1–2 cap is retired by the per-leaf-worktree fix. **PATH B dispatch shape is resolver-driven.** Resolve the dispatch spec via `scripts/resolve-execute-dispatch.sh` before dispatching, then dispatch **ONE execute agent in the worktree** — `ROLES=single` is the only shape (#1420) — as `Agent(subagent_type='general-purpose', model=$MODEL, description='execute-issue-plan #<N> (PATH B inline)', ...)`: it applies the `tdd-implementer` discipline per plan task and runs the FULL local suite green before `gh pr create` (#1108). PATH D uses `Agent(subagent_type='pipeline:tdd-implementer', ...)`. The PATH D inline `Agent` is additionally the SINGLE collapsed context that carries classify+plan+execute forward in ONE dispatch — it is NOT a fresh execute dispatch that re-reads a plan posted by an upstream Step 1b plan Agent (D was EXCLUDED from Step 1b's per-stage classify/plan dispatch precisely so that its classify+plan run inline here); PATH B is classified+planned per-stage upstream as normal and its inline `Agent` only runs execute. The collapsed D agent's pr-eval — and PATH B's pr-eval — is NOT folded into the execute context: each stays the separate Step 7 `evaluate-issue-pr` dispatch (evaluator independence). The inline foreground batch **consumes zero queue slots** — it costs no run-queue slot and is free concurrency *atop* the C-only run-queue capacity, not carved out of it. Bound the foreground batch at **max 3 concurrent inline** agents. Policy: fire the inline foreground batch FIRST / alongside the C-only run-queue launch — the inline agents (especially D) typically finish fast while the C run-queue grinds for far longer, so launching the foreground batch first costs essentially no added wall-clock.

   **D is NOT exempt from wave discipline.** The wave plan from `plan-waves.sh --stage=execute` already orders ALL paths (A/B/C/D) together over a **unified file-conflict graph** (there is no path-label gate — see `scripts/plan-waves.sh` and `tests/test-plan-waves-unified-graph.sh`). So a PATH D (or PATH B) issue that shares a file with another in-flight issue (any path) is ALREADY serialized into a later wave by the planner — the inline foreground dispatch does NOT exempt it from wave serialization. Only the wave's **conflict-free** foreground issues fan out in the batch; issues that collide with this wave's other in-flight work were already deferred to a later wave and are dispatched there.

   **Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D `/pipeline:execute-issue-plan N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: **(a)** the PR is opened and the issue is flipped to `pr-open`, reporting the success line (PR number + final test status); or **(b)** the work failed, reporting a FAILED line. Narrating an intention to "wait" (e.g. *"I'll wait for the suite notification."*) — or returning prose/edits instead of committing, pushing, and opening the PR — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the subagent with uncommitted work in progress (the #752/#764 drop-out). The subagent must instead run to completion (commit → push → `gh pr create` → label flip) or actually block on the suite via `Monitor`/`BashOutput` before yielding. A `general-purpose`/`tdd-implementer` subagent may never load `skills/execute-issue-plan/SKILL.md` (it can treat `/pipeline:execute-issue-plan N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. The prompt MUST also carry the staging directive verbatim: **Stage ONLY explicit plan paths via `git add <paths>`; never `git add -A|.|-u` (the #1028 cruft-sweep contract). The `scripts/check-branch-cruft.sh` pre-PR guard backstops this by failing the open if cruft reached any commit on the branch.** **Cross-cutting guards dispatch directive (#1132).** The dispatched subagent MUST run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh"` pre-PR and abort on failure — a `general-purpose`/`tdd-implementer` subagent that never loads the skill body still sees this dispatch-site binding (defense-in-depth so the fast diff-independent invariant floor is always run, even by agents that skip the SKILL.md body). **The `tdd-implementer` discipline rides the dispatch-site prompt (#1420).** The prompt carries it because a dispatched `general-purpose` subagent never loads `skills/execute-issue-plan/SKILL.md` and therefore cannot inherit the execute contract from that skill body: the prompt MUST direct the execute agent to take the approved plan's tasks one at a time — failing test first, `$PIPELINE_TEST_CMD` red for the right reason, minimum implementation, green, commit — to complete ALL plan deliverables including the non-test ones (a green suite alone is not plan-complete), and to run the FULL local suite green before `gh pr create`, so a break in a test the task does not exercise is caught locally rather than in CI (#1108). **Closing-review dispatch directive (#1387).** The prompt MUST direct the execute agent to run `execute-issue-plan` Step 8's closing independent code review before `gh pr create`, dispatching it with the FIXED description `code review #<N>` (append nothing); PATH D is excluded (Step 8 early-returns for `quick-fix`). The execute agent may edit an existing test file the approved plan names under `**Test changes:**`, and a test it concludes is WRONG is reported — never contorted around. **Git-anchoring + branch-assert (#1106 root-cause fix — dispatch-site, mandatory for the execute and collapsed-D dispatches).** Every git command in a dispatched prompt MUST be anchored with `git -C <worktree-abs-path>` — do NOT rely on cwd persisting across Bash calls (the Bash tool resets to the project root on each fresh invocation; the #1106 RED commit landed on `staging` this way). AND: before ANY commit, the agent MUST assert `git -C <worktree-abs-path> symbolic-ref --short HEAD` equals the dispatched feature branch — if it does not, **STOP and report** (do not commit). **Worktree-index staging precondition (#1122).** Before ANY `git add`, the dispatched agent MUST stage into its OWN worktree index — every `git add` MUST be anchored `git -C <worktree-abs-path> add <paths>`, NEVER a bare `git add` (cwd may resolve to the main checkout) and NEVER `git -C <main-repo> add`. Linked worktrees have separate index files, so a correctly-anchored add cannot leak into the main checkout index (the #1122 leak: an execute subagent's bare `git add` hit the MAIN checkout index instead of the worktree index, leaving staged edits that blocked the inter-leg `git pull --ff-only`). **Never `run_in_background` a test run (#1208).** Backgrounding a suite is the direct trigger of the narrate-and-yield recurrence. When the full suite does not fit inside one Bash-call timeout, run it in the FOREGROUND in chunks: `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh" --chunk 1/4`, then `--chunk 2/4`, `--chunk 3/4`, `--chunk 4/4` — one foreground Bash call each, run sequentially; every chunk must report `RESULT=pass` before `gh pr create`. Chunk it instead of backgrounding it. This ban is scoped to TEST RUNS only — the Step 6 tmux queue-runner launch is a separate, sanctioned use and is unaffected. **No hypothesised concurrent writer (#1262).** If your edits, commits, or staged changes turn up somewhere you did not expect — the main checkout, another branch, another worktree, or work that appears to have been reset — you MUST report the OBSERVED facts and STOP: `git -C <dir> status --short`, `git -C <dir> log --oneline -5`, and the exact git commands you ran. You MUST NOT attribute the state to a hypothesised concurrent writer — another campaign, a cron, a parallel agent, a race — that you have not directly observed. The overwhelmingly likely cause is your OWN unanchored `git` command (see the git-anchoring and worktree-index directives above). Inventing a concurrent writer to explain your own misplaced write sends the operator hunting a race that does not exist. **Boot-fence `CLAUDE_PLUGIN_ROOT` (#1341).** The prompt MUST also state: `${CLAUDE_PLUGIN_ROOT}` in any script call is valid only in a Bash call that ran the Boot fence first — under dogfood (`PIPELINE_USE_LOCAL_PLUGIN=true`) the session-inherited value is the MAIN checkout; a worktree agent must never run the main tree's scripts. **Friction capture:** the prompt MUST also direct the subagent to end its final report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines, one per doc/skill/hook claim that disagreed with reality. **One test file per `bash` invocation.** `bash a.sh b.sh` runs only `a.sh`. **Headless:** under `PIPELINE_HEADLESS=true` never end your turn on a question — apply the documented default, log `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>`, continue.

   **Per-dispatch clean-main attribution (#1262, mandatory).** The Step 6a clean-main guard below runs at the WAVE/LEG BOUNDARY, which is structurally too late to ATTRIBUTE a leak: by the time `CLEAN=dirty` surfaces, the agent whose mis-anchored `git add` caused it has already returned and its context is gone, so the orchestrator learns only that SOMETHING in the wave leaked. Run the same check PER DISPATCH so the verdict names the responsible agent while its context is still live.
   - **BEFORE each execute `Agent` dispatch** — the single execute dispatch, the collapsed-D dispatch, and each PATH C leaf — capture a baseline:
     ```bash
     # role = collapsed-D | single
     CM_BASE="${TMPDIR:-/tmp}/pipeline-clean-main/<N>-<role>.baseline"
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main-baseline "$MAIN_REPO" "$CM_BASE"
     ```
     Use a temp path. Never the gated logs tree — plugin writes there are `PIPELINE_LOGS_ENABLED`-gated and default to no-write, so a baseline written there would silently vanish on a default consumer host and turn every check into `CLEAN=error REASON=missing-baseline`. The helper never picks the path; the caller names the file.
   - **IMMEDIATELY AFTER that `Agent` returns** — before any further dispatch for the same issue, before Step 6a, and before any other orchestrator action on the issue — run the delta check:
     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --clean-main "$MAIN_REPO" --since "$CM_BASE" --issue <N>
     ```
   - Parse the `CLEAN=` token and act:
     - `CLEAN=ok` / `CLEAN=untracked-only` / `CLEAN=pre-existing` → nothing attributable to THIS dispatch; continue. `untracked-only` keeps the #1207 rule (do NOT stash operator-owned untracked paths); `pre-existing` means the dirty PATH SET is unchanged since the baseline, so nothing new is attributable — note the delta is path-scoped, not content-scoped, so a further write onto an already-dirty path also reports `pre-existing` (deliberate: the mode never accuses an agent of dirt it may not have caused; the Step 6a boundary check still sees it).
     - `CLEAN=leak ISSUE=<N> PATHS=<...>` → the agent that JUST returned leaked into the main checkout index. Report at WARN level in the run log NAMED to that agent: the `ISSUE=<N>`, the role (`collapsed-D` / `single`), and the `PATHS=` list. This is the attribution surface the wave-boundary guard structurally cannot provide. Recovery is **orchestrator-owned** (mirrors the #1208 no-re-ask rule): `git -C "$MAIN_REPO" restore --staged -- <paths>` then `git -C "$MAIN_REPO" stash push -- <paths>` — a PLAIN, path-scoped stash over exactly the reported delta paths, NEVER the untracked-sweeping flag (#1207 data-loss hazard) and never a whole-tree stash. The orchestrator MUST NOT resume, re-prompt, or `SendMessage` the leaking agent to clean up after itself. Then RE-CAPTURE the baseline before the next dispatch, so a cleared leak is never re-attributed to the following agent.
     - `CLEAN=error REASON=missing-baseline` → advisory only; re-capture the baseline and continue.
   - This is ADDED, not swapped: the Step 6a clean-main guard (`--clean-main "$MAIN_REPO"` with no `--since`) REMAINS the boundary backstop. Per-dispatch is the attribution surface; the boundary check catches anything the per-dispatch pass cannot see — notably the `--spawn` run-queue transport, which has no inline return point where a per-dispatch check could fire. Neither check ever halts the wave.

   ### Triage on agent-stalled wakes

   **Wake-loop semantics.** Each line matching the filter wakes the orchestrator. Dispatch by event:
   - `EVENT: queue-complete` — terminal; exit the Monitor wait and proceed to Step 6b / Step 7's next phase.
   - `EVENT: agent-stalled issue=<N>` — runner reports worker at idle CPU **and** no forward progress (frozen tmux pane) across `PIPELINE_STALL_POLL_THRESHOLD` polls (#641); a healthy API-bound agent emitting pane output is no longer flagged. Runner took no action. Run the four-option triage below; then re-enter `Monitor` with the SAME `timeout_ms` budget (the elapsed wait is preserved by the harness).
   - `EVENT: agent-finished outcome=failed issue=<N>` — per-agent failure. Optional triage (capture pane, inspect PR/branch state); re-enter `Monitor` so the rest of the queue continues to be watched.
   - `EVENT: agent-finished outcome=success issue=<N>` — no-op wake; re-enter `Monitor`.
   - `EVENT: agent-finished outcome=manual-merge-required reason=<block-reason> issue=<N>` — no-op wake (issue #489); the runner freed a wedged evaluator slot whose PR is awaiting manual merge per the evaluator's Step 11.4 block-* skip. The `reason=` field carries the gate's actual block token (`block-verdict`, `block-ci`, `block-mergeable`, `block-mergestate`, `block-label`, `block-flag`, `block-cage-tests-diff`, `block-capability-refused`, `block-base-mismatch`, or `unknown` if unrecoverable) so the token is NEVER read as an "approved" verdict — a `block-verdict` reason means the evaluator FLAGGED the PR (issue #654); a `block-capability-refused` reason (#1233) means a leaf emitted the `CAPABILITY-REFUSED:` sentinel. Re-enter `Monitor`. The operator merges the PR by hand (`gh pr merge <PR> --merge --delete-branch`) or fullsend's `## Merge orchestration (reference)` greenlight path handles it.

   **Triage on `agent-stalled`.** The event already implies the pane was frozen (no forward progress) across the whole window (#641), so the first triage action is to re-`capture-pane` and confirm it is *still* frozen before acting. Inspect the worker first (tmux pane via `tmux capture-pane -t "$PIPELINE_TMUX_SESSION:issue-<N>" -p`; process tree via `pstree -p <pid>`). Then surface the four-option prompt to the user:
   1. **Kill the wedged subscript only** — `kill <child-pid>` from the pstree output; executor may recover.
   2. **Kill the whole executor** — `tmux send-keys -t "$PIPELINE_TMUX_SESSION:issue-<N>" C-c` and let the runner record `agent-finished outcome=failed`.
   3. **Wait out the timeout** — re-enter `Monitor` with the same `timeout_ms` budget remaining.
   4. **Skip the issue** — `tmux kill-window -t "$PIPELINE_TMUX_SESSION:issue-<N>"`; runner picks the next from the bucket.

   Runner NEVER kills autonomously. The orchestrator's prompt to the user is the kill gate.

6a. **Post-dispatch completion verification (mandatory).** Read [references/post-dispatch-verification.md](references/post-dispatch-verification.md) immediately after the inline foreground Agent batch returns and before Step 6b.

6b. CI-fix loop (wave N) — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]` (colon-LESS fallback per #858: unset ⇒ ON to match the documented `.example` default; explicit `=""` ⇒ OFF to preserve the no-CI consumer contract; `="true"/"false"` honored). For each of wave N's `pr-open` issues, fullsend invokes `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and parses the emitted `ACTION=` line. The helper resolves issue→PR **deterministically per-issue** — closing-PR ref → the issue's `git worktree list` branch ref (`--head <ref>`) → body reference, from the orchestrator CWD where the worktrees are siblings — so a concurrent wave with ≥2 open PRs never misroutes to another issue's PR (#909). The invocation takes a single `<N>` arg (no branch/PR wiring). Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` is the authoritative source for issue→PR resolution (deterministic per-issue: closing-PR ref → worktree branch ref → body reference; never "latest open PR" — #909), retry-counter encoding (`pipeline.ci-retries: <n>` issue comment), tail-truncated failure-log path (`.claude/logs/ci-fix-<N>-attempt-<n>.log`), and `human` label application on budget-exhaust.

7. **Evaluate PRs (wave N)** — once wave N's agents finish (queue complete), run `/pipeline:evaluate-issue-pr N` for every wave-N `pr-open` issue (via `run-queue.sh --skip-permissions --skill evaluate-issue-pr`), and apply the per-PR greenlight auto-merge gate from the `## Greenlight matrix` above to each.

   **Fire the gate per PR (#1444, mandatory).** The evaluator posts a verdict and STOPS — it no longer merges.
   For EACH wave-N `pr-open` PR, as soon as that PR's evaluator returns, the orchestrator runs the gate itself
   (`$ISSUE` / `$PR_NUM` are that PR's issue and PR numbers). This applies to inline PATH A/B/C/D evaluations
   and to `--spawn` queued ones alike:

   ```bash
   ISSUE=<N>     # the wave-N pr-open issue whose evaluator just returned
   PR_NUM=<PR>   # its PR, already resolved deterministically by Step 6b's check-ci-fix-loop.sh
   source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
   CR_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-capability-refusal.sh" --resolve-sources)
   CR_STATE=${CR_LINE%% *}; CR_STATE=${CR_STATE#SOURCES=}
   CR_DIR=${CR_LINE##*DIR=}
   case "$CR_STATE" in
     resolved)          export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$CR_DIR" ;;
     no-log-dir)        echo "NOTE: no subagent log dir on the main checkout (PIPELINE_LOGS_ENABLED=false?) — capability arm skipped: $CR_LINE" >&2 ;;
     unresolvable-root) echo "WARN: capability-refusal sources UNRESOLVABLE from $(pwd) — gate arm DORMANT (#1246): $CR_LINE" >&2 ;;
   esac
   REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
   echo "GATE: issue=#$ISSUE pr=#$PR_NUM reason=$REASON"
   ```

   On any token, follow [references/auto-merge-gate.md](references/auto-merge-gate.md).

   **Stage-model pin (#1186, mandatory).** Every `evaluate-issue-pr` dispatch — inline or queued — resolves its model from the single source and **ALWAYS passes `model=$MODEL`**:
   ```bash
   PR_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> pr-eval)
   ```
   `PIPELINE_STAGE_MODEL_PR_EVAL` (unset ⇒ `opus`) makes W3 a REAL pin rather than an inheritance side-effect; no carve-out can lower it, and an explicit knob below the resolved execute tier is honored but emits a stderr WARN — relay that WARN in the wave log. pr-eval is never routed through `resolve-execute-dispatch.sh` (its stage-word guard exits 2).

   **`--spawn` override (#750).** When `--spawn` is present, route **every path's PR-eval through `run-queue.sh --skill evaluate-issue-pr`** — including the paths whose PR-eval is inline by default (PATH B). PATH C PR-eval is already queued, so for C this is a documented no-op. When `--spawn` is absent, the default below applies (PATH B PR-eval inline, others via the run-queue). Launch this queue via `Bash` with `run_in_background: true` as described in step 6, then wait on it with the same event-driven waiter (identical to Step 6's waiter): a single `Monitor` invocation against the bash task's captured stdout stream (queried via the `BashOutput` tool — do NOT tail `queue-*.log`), with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000`. Apply the same wake-loop dispatch and "Triage on agent-stalled wakes" sub-section above — `agent-finished outcome=failed` is the per-agent failure signal (no separate `agent-failed`), `queue-complete` is terminal.

   **Inline PR-eval dispatch prompt contract (mandatory).** Whenever an `evaluate-issue-pr` evaluation is dispatched as an inline `Agent` (PATH A/B/D re-dispatch, or any pr-open issue evaluated inline rather than via the run-queue), the Agent prompt MUST end with a directive stating the dispatched evaluator's *only* valid terminal states are: **(a)** a `## Evaluation` comment posted with an explicit `**Verdict:**` line; or **(b)** the eval failed, reporting a FAILED line. The evaluator does NOT fire the greenlight gate (#1444) — the ORCHESTRATOR fires it at Step 7 after the evaluator returns, per [references/auto-merge-gate.md](references/auto-merge-gate.md) — so the prompt MUST say so explicitly and must not demand a `block-*` gate token the evaluator cannot produce. Narrating an intention to "wait" / "await CI" (e.g. *"All plan items verified. Awaiting the suite/CI output."*) — or returning verification prose instead of posting the verdict — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the PR un-evaluated at `pr-open` and forces a fresh re-dispatch (the #765 drop-out). The evaluator must instead run to completion (post `## Evaluation` with its `**Verdict:**` line) or actually block on pending CI via `Monitor`/`BashOutput` before yielding. A `general-purpose` subagent may never load `skills/evaluate-issue-pr/SKILL.md`, so this dispatch-site directive — not the skill body — is the binding contract. **Pre-greenlight cross-cutting guards (#1132): the prompt MUST direct the dispatched evaluator to run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh"` in Phase 2 even when the #957 green-CI short-circuit skips the full `$PIPELINE_TEST_CMD` re-run — the short-circuit runs no local cross-cutting re-check, and the aggregator is the seconds-fast diff-independent floor.** (Fullsend is now the sole owner of this PR-eval dispatch contract; `/pipeline:status` is read-only and no longer dispatches, mirroring the #764/#771 execute precedent.) **Friction capture:** the prompt MUST also direct the subagent to end its final report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines, one per doc/skill/hook claim that disagreed with reality. **Headless:** under `PIPELINE_HEADLESS=true` never end your turn on a question — apply the documented default, log `HEADLESS-DEFAULT: <site> decision=<what> reason=<why>`, continue.
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

### Inter-wave base refresh (fetch-only, before wave N+1)

After wave N's feature PRs **merge to the remote**, and **before** setting up wave N+1's worktrees (Step 5), the orchestrator refreshes its remote-tracking ref for the base. **Wait for wave N's PRs to merge before setting up wave N+1**, then run:

```bash
git -C "$MAIN_REPO" fetch --quiet origin "$PIPELINE_BASE_BRANCH"
```

The inter-wave step is a single `git fetch --quiet origin` of the base branch, run against the main repo (`git -C "$MAIN_REPO" ...`).

**Why this is mandatory (the #626 fix, refreshed by #1214).** PR merges land on the **remote**, so wave N+1's branch point must be `origin/<base>`'s tip — which Step 5's always-explicit `--base` actuation reads directly (`setup-worktree.sh` fetches `origin/<base>` itself and cuts the worktree from that remote tip). This inter-wave step's fetch refreshes that remote-tracking ref so Step 5 sees wave N's merged work. The advance is a **single command**: atomic, moves no local ref, no HEAD, and writes nothing to the working tree — nothing for a mid-sequence failure to strand. `--quiet` keeps the fetch's ref-update list out of orchestrator context. The orchestrator's LOCAL base branch is deliberately left behind — it is the operator's own checkout, and the autonomous lane never mutates it (the pre-#1214 `checkout` + `pull --ff-only` pair stranded operator work and was not atomic across the two commands). `$MAIN_REPO` is assigned in the `## Boot` block above (`${PIPELINE_PROJECT_ROOT:-$(pwd)}`) — the orchestrator's own checkout root; `run-queue.sh` / `setup-worktree.sh` operate inside worktrees, so the orchestrator is free to fetch on the main repo between waves without disturbing any in-flight worktree.

### Scoped halt-and-report (closure sourced from `--emit-edges`)

Read [references/scoped-halt.md](references/scoped-halt.md) when an `--emit-edges` closure drops an issue from the slate.

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
   The `Auto-merged?` column reflects the per-PR gate outcome: `yes (step7)` — the orchestrator's Step 7 gate merged it when that PR's evaluator returned; `yes (step8)` — Step 8's fallback pass merged it; `no (<block-reason>)` — manual merge required.
   ```
9. **Stop** — do NOT merge unless the greenlight matrix held in Step 8. Auto-merged PRs are already listed in the report's `Auto-merged?` column. Wait for explicit user confirmation before any non-greenlight merge.

## Dispatch routing by path tier (reference)

Read [references/dispatch-routing.md](references/dispatch-routing.md) when resolving a path tier's dispatch shape.

## Merge orchestration (reference)

Read [references/merge-orchestration.md](references/merge-orchestration.md) at the post-evaluation merge step.

