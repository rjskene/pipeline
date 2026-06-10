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
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
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

## Campaign mode

**This section is the single source of truth for the campaign machinery.** `/pipeline:campaign` is an **equivalent standalone entry point** into the SAME loop documented here — it owns no leg-loop prose of its own and defers to this section verbatim (see `skills/campaign/SKILL.md`). `--campaign` on `/pipeline:fullsend` remains supported on an ongoing basis and is **NOT deprecated**; the two entries are interchangeable and execute identical machinery, so they can never drift.

`--campaign` is an **OUTER loop above the existing wave-by-wave steps** — it **does not replace** them. Each **LEG** is one full pass of Steps 1→8 over that leg's issues; the wave-by-wave `### Execute the slate WAVE BY WAVE` machinery (Steps 5–7, the `### Inter-wave pull`, the `### Scoped halt-and-report`) runs unchanged *inside* each leg. Campaign mode WRAPS that pass and sequences multiple legs so the global rate-limit budget is spent in bounded batches rather than a single flat blast of the entire set.

**Global-budget rule (applies to ALL stages).** Every agent dispatch — **classify and plan INCLUDED, not just execute** — is **batched under the caps**. There is **NO flat parallel blast of the whole set even for the read-only stages** (classify/plan): the rate-limit budget is GLOBAL, so a flat read-only blast still burns the same shared budget that execute needs. Batch classify/plan dispatch under the same concurrency cap as everything else.

**Campaign flow:**

(a) **Classify the ENTIRE set, BATCHED under a FLAT concurrency cap.** Paths are unknown *before* classify runs, so the set cannot be per-path-capped at this stage (the chicken-and-egg: per-path caps need path labels, but path labels are exactly what classify produces). Use a single FLAT cap across the whole set for classify; do not flat-blast it.

(b) **Plan the ENTIRE set, BATCHED and path-aware.** By plan time the classify labels exist, so the plan batch may honor per-path caps.

(c) **Eval-plan the ENTIRE set, BATCHED, and APPROVE ALL up front.** There is **no per-leg re-plan**: every approved issue is flipped to `plan-approved` before any leg executes. Staleness between approval and a late leg's execute is absorbed downstream — the execute-agent rebases on the fresh base tip, and the `evaluate-issue-pr` gate re-validates against the merged base — so re-planning per leg buys nothing.

(d) **Partition the approved set into legs** via:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh <approved-set>
```

The partitioner honors `PIPELINE_CAMPAIGN_MAX_BC` (B/C-pool per-leg cap) and `PIPELINE_CAMPAIGN_MAX_AD` (A/D-pool per-leg cap) from the environment. A user instruction at invocation overrides those via the script's `--max-bc=N` / `--max-ad=N` flags. Parse the emitted `Leg <K>: #a, #b, ... (BC=<n> AD=<m>)` lines into ordered per-leg issue lists; legs run **in order**.

(e) **For each leg IN ORDER**, run the existing wave-by-wave pass over ONLY that leg's issues, then advance the base, then collect (NOT file) that leg's bug signals, then move to the next leg:

1. Run the existing **execute → 6b → eval-pr → greenlight-merge** machinery (Steps 5–7 wave-by-wave) scoped to this leg's issue numbers.
2. **Base advance** — perform the inter-wave-style local base-tip advance: `git -C "$MAIN_REPO" checkout "$PIPELINE_BASE_BRANCH"` then `git -C "$MAIN_REPO" pull --ff-only --quiet origin "$PIPELINE_BASE_BRANCH"` so the next leg's worktrees inherit this leg's merged work (same #626 reason as the `### Inter-wave pull`).
3. **Usage read-out at the leg boundary** (dogfood-only, #725) — after the base advance, render the rolling-window usage read-out and surface its headroom / throttle-ETA so the operator can size the next leg with the headroom number in hand. READ-ONLY advisory; never gate-fatal. **NO automated hold / queue / pacing is performed** — the read-out is purely informational (the control loop is explicitly out of scope per #725):
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-surface.sh" || true
   ```
4. **Collect this leg's bug signals** (NO `gh issue create` per leg). Append every signal from this leg — eval-pr `block-*` flags, Step-6b CI-fix repairs, execute `FAILED`/off-plan reports, and any skipped/halted-closure issues — to the running campaign signal log as one `SIGNAL issue=#<N> kind=<...> title="<conventional-commit title>" detail="<short>"` record per signal. **Preserve the per-leg race guard:** before recording, dedup against (1) currently-open issues and (2) the running campaign-filed set, so a leg never re-records a signal a prior leg already filed (the cross-leg race guard). Actual filing is deferred to **End-of-campaign bug filing** below, after the last leg.
5. Proceed to the next leg.

**End-of-campaign fold wave (#838).** AFTER the last regular leg's `(e)` step completes but BEFORE **End-of-campaign bug filing** below, run ONE bounded fold wave over bugs filed *this campaign*. This is the ONLY place mid-campaign-filed signals re-enter the wave machinery; during the legs, bug handling is unchanged (collect-only, deferred filing). Steps:

1. **Select up to `PIPELINE_CAMPAIGN_MAX_FOLD` (default 3) signals, FIFO.** Pipe the running campaign signal log through the mechanical selector, which walks records in filing (FIFO) order, applies the ceiling, and skips high-uncertainty TITLE-keyword hits without consuming budget:
   ```bash
   printf '%s\n' "${CAMPAIGN_SIGNALS[@]}" \
     | PIPELINE_REPO="$PIPELINE_REPO" \
       PIPELINE_CAMPAIGN_MAX_FOLD="${PIPELINE_CAMPAIGN_MAX_FOLD:-3}" \
       bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh fold-select
   ```
   It emits `FOLD issue=#<N> title="..."` (selected), `SKIP issue=#<N> reason=high-uncertainty title="..."` (left posted), and `OVERFLOW issue=#<N> title="..."` (beyond ceiling, left posted) lines.
2. **Apply the classify-clean skip (model judgment, NOT mechanized).** For each `FOLD` line, additionally **skip (leave posted)** any signal that would classify `human` / `brainstorm` / `excluded` — these always wait for human review. The `fold-select` script only does the mechanical FIFO + ceiling + high-uncertainty keyword skip (`concurrency` / `race` / `lock` / `deadlock` / `security` / `auth` / `crypto` / `migration` / `data-loss`); the **non-autonomous** classify-clean decision is yours here. A `FOLD` line that you classify non-autonomous is demoted to the leave-posted set exactly like `SKIP`/`OVERFLOW`.
3. **File the surviving FOLD signals as issues FIRST** (the wave machinery needs issue NUMBERS). For each surviving `FOLD` signal, `gh issue create` it via the same standard body template + path-hint marker used by **End-of-campaign bug filing**, re-checking the open-issue + campaign-filed sets immediately before create (the dedup contract), then add the new number to the campaign-filed set AND remove its signal from `CAMPAIGN_SIGNALS` so the filing step below does not re-file it.
4. **Run ONE wave** over exactly those newly-filed fold issue numbers through the normal wave machinery — classify → plan → eval-plan → execute → eval-PR → auto-merge — the same `### Execute the slate WAVE BY WAVE` pass used by every leg, respecting `--manual-merge`. **Conflicts are handled at merge, not pre-filtered:** a folded PR that collides with just-merged leg work surfaces as a normal merge conflict and rides the standard eval/merge path (no file-conflict eligibility predicate).
5. **Bound — one wave, NO recursion.** Any NEW signal collected DURING this fold wave is appended to `CAMPAIGN_SIGNALS` and **just posts** in the **End-of-campaign bug filing** step below — it is **never folded again**. The fold wave is single-shot; `fold-select` reads the already-serialized, dedup-guarded filed set ONCE.

**Overflow + SKIP signals stay posted.** Every `OVERFLOW`/`SKIP` signal and every classify-clean-demoted signal remains in `CAMPAIGN_SIGNALS` and flows into **End-of-campaign bug filing** below — they are filed for the NEXT campaign (no loss; nothing is dropped). Only the surviving FOLD signals filed in step 3 are removed from the file-only set.

**End-of-campaign bug filing.** AFTER the last leg's `(e)` step completes (campaign completion), a **SINGLE serialized orchestrator action** routes the aggregated signal log through the **deterministic, NON-INTERACTIVE subset** of the create-issues flow — the combine-bias scope-check heuristic + the grouping-detection script + the standard issue-body template + the advisory path-hint marker. It **NEVER invokes the interactive `superpowers:brainstorming` dialogue** (no one-question-at-a-time loop) and does **NOT** call the full `/pipeline:create-issues` skill — it calls the three deterministic helpers directly, because campaign completion is autonomous (the #863 autonomy constraint). Steps:

1. **Aggregate + dedup the signals** across all legs via `plan-campaign.sh aggregate-signals`, passing the open-issue set and the running campaign-filed set so completion-time filing cannot double-file what a leg already filed (the dedup contract is two-layer: per-leg collection AND here):
   ```bash
   printf '%s\n' "${CAMPAIGN_SIGNALS[@]}" \
     | PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh \
         aggregate-signals --open="<open-issue-csv>" --filed="<campaign-filed-csv>"
   ```
   Each emitted `CANDIDATE scope=<scope> issues=#a,#b title="<derived title>" kinds=<csv>` line is one proposed issue.
2. **Apply the combine-bias scope-check heuristic** (from `skills/create-issues/SKILL.md` step 3) to the candidate set: default toward FEWER issues; split only on genuinely independent surfaces (disjoint files, distinct subsystems). This is model judgment over the candidate lines — no interactive prompt.
3. **Run grouping detection** over the surviving candidate titles and honor its recommendations (tracker auto-append / GROUP→tracker create; opt-out via `PIPELINE_GROUPING_DETECTION_ENABLED=false`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-grouping-candidates.sh" \
     --title "<candidate-title-1>" --title "<candidate-title-2>"
   ```
4. **File each surviving issue** with the standard create-issues body template (Context / Scope / Affected areas / Notes) and the advisory `<!-- pipeline:path-hint=A|B|C -->` marker when a clear A/B/C signal exists:
   ```bash
   gh issue create --repo $PIPELINE_REPO --title "<title>" --body "$(cat <<'EOF'
   ## Context
   <1-3 sentences: which leg/stage surfaced this and the failure shape>

   ## Scope
   - <what this issue covers>

   ## Affected areas
   - <file paths or system areas likely involved>

   ## Notes
   - <constraints / dependencies surfaced during the campaign>
   <!-- pipeline:path-hint=B -->
   EOF
   )"
   ```
   Before each `gh issue create`, re-check the open-issue set + campaign-filed set one final time (the second dedup layer), then add the new number to the campaign-filed set. This consolidated end-of-campaign pass replaces the old per-leg file-only path: grouping/dedup now operate across the WHOLE campaign rather than one leg at a time.

**Scoped halt (campaign-level mirror of `### Scoped halt-and-report`).** When a leg's issue hard-fails or hard-blocks, compute its **dependency CLOSURE** and drop that closure from the REMAINING legs:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh closure <blocked-N> <remaining-set>
```

The closure walks the `--emit-edges` edge map (blocked-by + file-conflict edges) to a fixpoint. **Independent later legs that are NOT in the closure still proceed.** Failed issues plus their skipped-closure dependents are reported at campaign end. Transient blocks (`block-ci` / `pending`) do **NOT** trigger an immediate halt — they defer to the Step-6b CI-fix loop and only become a hard block once the retry budget exhausts (mirroring the transient-vs-hard-block discrimination in `### Scoped halt-and-report`).

**Self-mutation callout.** This `--campaign` mode edits the fullsend machinery the pipeline itself runs; the work happens in an isolated worktree and the running orchestrator keeps its already-loaded skill body until restart, so there is no live-mutation risk (same as `### Self-mutation callout`).

## Greenlight matrix

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, fullsend auto-merges (merge-commit) if and only if all four conditions hold; otherwise the PR is left for manual merge with a `block-*` reason token.

```
| # | Condition                                                | Source                              |
|---|----------------------------------------------------------|-------------------------------------|
| 1 | Latest `## Evaluation` has `**Verdict:** Approved`       | gh pr view --json comments          |
| 2 | Every statusCheckRollup entry `conclusion == SUCCESS`    | gh pr view --json statusCheckRollup |
| 3 | `mergeable == MERGEABLE`                                 | gh pr view --json mergeable         |
| 4 | `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE) | gh pr view --json mergeStateStatus |
```

**block-base-mismatch** is enforced as defense-in-depth — PR `baseRefName` must equal `PIPELINE_BASE_BRANCH` (see #295). Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → verdict → `block-base-mismatch` → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, `block-flag`, `block-label`, `block-verdict`, `block-base-mismatch`, `block-ci`, `block-mergeable`, `block-mergestate`.

**Three opt-outs:** (1) `FULL SEND --manual-merge` — flag may appear anywhere in argv (cannot collide with issue numbers, which are bare integers); (2) `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations; (3) a `manual-merge` label on the issue for per-issue control without re-typing the flag. (`--spawn` is the orthogonal transport flag — see Step 6/7 — not a merge opt-out.)

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

   The helper is idempotent — repeat invocations cost zero `gh api` calls. The `head -1` cap keeps wave-log output to one line per issue. This is the autonomous-mode ingestion site; `/pipeline:status` step 0 does NOT fetch attachments. Interactive single-issue planning fetches at `/pipeline:plan-issue` step 3b instead.

   **1b. Dispatch classify and plan.** Process wave by wave per the `## Wave plan (pre-think)` section above — before dispatching plan-issue, run `/pipeline:classify-issue N` for every ready issue that lacks a fresh `## Classification` comment (the comment's `createdAt >= issue.updatedAt`) (dispatch in parallel, one Agent per issue). Each classify run writes the Classification comment AND applies the path label (`docs-only` or `multi-task`). Cached issues skip dispatch. Then run `/pipeline:plan-issue N` for every issue with no pipeline label (in parallel, one Agent per issue). Wait for all to complete. **PATH D exclusion.** PATH D (`quick-fix`) issues are EXCLUDED from this per-stage classify/plan dispatch — their classify+plan stages run INSIDE the single collapsed foreground inline `Agent` dispatched at execute (Step 6), emitting `## Classification`+`quick-fix` and `## Implementation Plan`+`plan-pending` as inline side-effect checkpoints. Only A/B/C issues go through this Step 1b per-stage classify/plan dispatch. (The `## Wave plan (pre-think)` ordering still includes D — only the per-stage classify/plan *dispatch* is what D skips.)
   - **Dispatch prompt contract (mandatory):** each `/pipeline:plan-issue N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 and it reports the success line, or (b) `post-plan.sh` exited non-zero and it reports the FAILED line. Returning the plan body in chat is a failure — the plan does not exist until `post-plan.sh` has posted the `## Implementation Plan` comment and applied the `plan-pending` label. A `general-purpose` subagent may never load `skills/plan-issue/SKILL.md` (it can treat `/pipeline:plan-issue N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract.
   - **`--debug-first` propagation (#997):** when fullsend was invoked with `--debug-first`, each dispatched plan-issue Agent's prompt MUST carry the flag (e.g. `/pipeline:plan-issue N --debug-first`) so the subagent runs plan-issue's Step 4a diagnosis gate. The flag is a one-off invocation toggle and does NOT live on the issue, so it has to be threaded through the dispatch explicitly. The durable `needs-debug` LABEL, by contrast, flows through for free — the dispatched plan-issue resolves it from the issue's OWN labels, so an issue already tagged `needs-debug` hits the gate with or without the flag. Propagation is therefore needed only for the one-off `--debug-first` flag, never for the label.
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

   Both positional args are required. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short) — same convention as `skills/status/SKILL.md` ("Branch and worktree naming convention"). `<issue-number>` is the bare integer.

   Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81
   ```

   The script defaults to `PIPELINE_BASE_BRANCH` from `pipeline.config`; pass `--base` only if you need to override (e.g., orchestrator running on a non-default branch).

   **Do NOT invoke with only the issue number** — the script will reject it as of #350. A bare integer like `setup-worktree.sh 81` fails the branch-prefix guard because `81` is not a `feature/<slug>` shape; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.

   **Base-tip note (the #626 fix).** `setup-worktree.sh` adds the worktree via `git worktree add -b`, which **branches off the main repo's LOCAL HEAD, not `origin/<base>`**; the `--base` / `$BASE_BRANCH` value there is only metadata, not a remote fetch. So a wave's worktrees inherit exactly whatever the orchestrator's local base tip points at *at the moment Step 5 runs*. That is why the inter-wave pull (below) is mandatory between waves.
6. **Execute (wave N)** — launch wave N's worktrees via the tmux queue runner with skip-permissions enabled (equivalent to user answering "tmux / y" at the launch prompt). Scope `run-queue.sh` to ONLY wave N's issue numbers — never mix issues from a later wave into the same queue (no cross-wave concurrency). **Within-wave parallelism is preserved:** same-wave issues that have no dependency or file-conflict edge between them still run concurrently up to run-queue's `MAX_AGENTS` cap — do not over-serialize within a wave. Launch the queue runner via `Bash` with `run_in_background: true` — do NOT use a foreground `while ... sleep ... grep` poll loop. Wait for terminal events with a single `Monitor` invocation against the queue runner's captured stdout stream — the `Bash` tool's `run_in_background: true` task captures the runner's stdout, queryable via the `BashOutput` tool. That captured stdout is the always-on wake channel because `log()` (`scripts/run-queue.sh:136-142`) emits every `EVENT:` line to stdout unconditionally, even when `PIPELINE_LOGS_ENABLED=false` (the `queue-*.log` file is gated and may not exist on consumer hosts — do NOT tail it). Invocation shape: `Monitor` on the bash task's stdout stream with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000` (preserves the existing 2h worst-case wait budget). Per Monitor's coverage rule, the filter MUST cover every terminal state (failure + completion) so a crash is never silent — `agent-finished outcome=failed` IS the per-agent failure signal (the runner does not emit a separate `agent-failed`). Status updates are emitted automatically by the queue runner every 3 minutes (configurable via `STATUS_INTERVAL`).

   **`--spawn` override (#750).** When `--spawn` is present in the fullsend argv, SKIP the inline foreground `Agent` batch entirely and route **every path's execute through the tmux `run-queue.sh`** — no inline at all. Scope the queue to wave N's issue numbers exactly as below. **PATH C execute is now inline-by-default (#749), so `--spawn` routes it back to the legacy `spawn-claude.sh` → `tdd-implementer` fan-out** (its reversible escape hatch — a LIVE effect on C, no longer a no-op); A/B/D execute also route onto the run-queue as before. When `--spawn` is absent, the split-dispatch default below applies unchanged (A/B/C/D inline foreground, all bounded at the same **max-3 foreground** concurrency — per-leaf worktrees mean C is no longer git-index-capped, #896).

   **Split dispatch for PATH D (#700) + PATH B (#748) + PATH C (#749).** Within wave N, partition the wave's issues by path. By DEFAULT (no `--spawn`) the wave's **conflict-free PATH A/B/C/D issues fan out as the inline foreground batch** at the same wall-clock — the C-only tmux **run-queue is now used ONLY when `--spawn` is set** (#750). The conflict-free PATH A/B/D issues fan out CONCURRENTLY as an inline `Agent` batch in the FOREGROUND, dispatched together in a single foreground batch, bounded at **max 3 concurrent inline** agents. **PATH C fans out inline too** — the orchestrator reads the plan and dispatches one `Agent(subagent_type='tdd-implementer', ...)` per `target=<dir>`, each in its OWN per-leaf worktree (`scripts/path-c-split-worktree.sh` setup/reassemble/teardown, #896) so concurrent leaves never share a git index (the #894 c+d collision). With isolated indexes the fan-out is **bounded only by orchestrator context, not a git-index cap** — the #894/#896 live branch test confirmed leaf returns are ~one line each with negligible context cost, so non-overlapping targets fan out concurrently up to the same **max-3 foreground bound** as A/B/D (keep leaf returns terse). The earlier conservative 1–2 cap is retired by the per-leaf-worktree fix. PATH B uses `Agent(subagent_type='general-purpose', ...)` (its red→green discipline comes from the plan's Task 0 `superpowers:test-driven-development` bookend inside execute-issue-plan, NOT a fresh transport) and PATH D uses `Agent(subagent_type='tdd-implementer', ...)`. The PATH D inline `Agent` is additionally the SINGLE collapsed context that carries classify+plan+execute forward in ONE dispatch — it is NOT a fresh execute dispatch that re-reads a plan posted by an upstream Step 1b plan Agent (D was EXCLUDED from Step 1b's per-stage classify/plan dispatch precisely so that its classify+plan run inline here); PATH B is classified+planned per-stage upstream as normal and its inline `Agent` only runs execute. The collapsed D agent's pr-eval — and PATH B's pr-eval — is NOT folded into the execute context: each stays the separate Step 7 `evaluate-issue-pr` dispatch (evaluator independence). The inline foreground batch **consumes zero queue slots** — it costs no run-queue slot and is free concurrency *atop* the C-only run-queue capacity, not carved out of it. Bound the foreground batch at **max 3 concurrent inline** agents. Policy: fire the inline foreground batch FIRST / alongside the C-only run-queue launch — the inline agents (especially D) typically finish fast while the C run-queue grinds for far longer, so launching the foreground batch first costs essentially no added wall-clock.

   **D is NOT exempt from wave discipline.** The wave plan from `plan-waves.sh --stage=execute` already orders ALL paths (A/B/C/D) together over a **unified file-conflict graph** (there is no path-label gate — see `scripts/plan-waves.sh` and `tests/test-plan-waves-unified-graph.sh`). So a PATH D (or PATH B) issue that shares a file with another in-flight issue (any path) is ALREADY serialized into a later wave by the planner — the inline foreground dispatch does NOT exempt it from wave serialization. Only the wave's **conflict-free** foreground issues fan out in the batch; issues that collide with this wave's other in-flight work were already deferred to a later wave and are dispatched there.

   **Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D `/pipeline:execute-issue-plan N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: **(a)** the PR is opened and the issue is flipped to `pr-open`, reporting the success line (PR number + final test status); or **(b)** the work failed, reporting a FAILED line. Narrating an intention to "wait" (e.g. *"I'll wait for the suite notification."*) — or returning prose/edits instead of committing, pushing, and opening the PR — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the subagent with uncommitted work in progress (the #752/#764 drop-out). The subagent must instead run to completion (commit → push → `gh pr create` → label flip) or actually block on the suite via `Monitor`/`BashOutput` before yielding. A `general-purpose`/`tdd-implementer` subagent may never load `skills/execute-issue-plan/SKILL.md` (it can treat `/pipeline:execute-issue-plan N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. (Mirrors the Step 1b plan-issue dispatch prompt contract.)

   ### Triage on agent-stalled wakes

   **Wake-loop semantics.** Each line matching the filter wakes the orchestrator. Dispatch by event:
   - `EVENT: queue-complete` — terminal; exit the Monitor wait and proceed to Step 6b / Step 7's next phase.
   - `EVENT: agent-stalled issue=<N>` — runner reports worker at idle CPU **and** no forward progress (frozen tmux pane) across `PIPELINE_STALL_POLL_THRESHOLD` polls (#641); a healthy API-bound agent emitting pane output is no longer flagged. Runner took no action. Run the four-option triage below; then re-enter `Monitor` with the SAME `timeout_ms` budget (the elapsed wait is preserved by the harness).
   - `EVENT: agent-finished outcome=failed issue=<N>` — per-agent failure. Optional triage (capture pane, inspect PR/branch state); re-enter `Monitor` so the rest of the queue continues to be watched.
   - `EVENT: agent-finished outcome=success issue=<N>` — no-op wake; re-enter `Monitor`.
   - `EVENT: agent-finished outcome=manual-merge-required reason=<block-reason> issue=<N>` — no-op wake (issue #489); the runner freed a wedged evaluator slot whose PR is awaiting manual merge per the evaluator's Step 11.4 block-* skip. The `reason=` field carries the gate's actual block token (`block-verdict`, `block-ci`, `block-mergeable`, `block-mergestate`, `block-label`, `block-flag`, `block-base-mismatch`, or `unknown` if unrecoverable) so the token is NEVER read as an "approved" verdict — a `block-verdict` reason means the evaluator FLAGGED the PR (issue #654). Re-enter `Monitor`. The operator merges the PR by hand (`gh pr merge <PR> --merge --delete-branch`) or fullsend's `## Merge orchestration (reference)` greenlight path handles it.

   **Triage on `agent-stalled`.** The event already implies the pane was frozen (no forward progress) across the whole window (#641), so the first triage action is to re-`capture-pane` and confirm it is *still* frozen before acting. Inspect the worker first (tmux pane via `tmux capture-pane -t "$PIPELINE_TMUX_SESSION:issue-<N>" -p`; process tree via `pstree -p <pid>`). Then surface the four-option prompt to the user:
   1. **Kill the wedged subscript only** — `kill <child-pid>` from the pstree output; executor may recover.
   2. **Kill the whole executor** — `tmux send-keys -t "$PIPELINE_TMUX_SESSION:issue-<N>" C-c` and let the runner record `agent-finished outcome=failed`.
   3. **Wait out the timeout** — re-enter `Monitor` with the same `timeout_ms` budget remaining.
   4. **Skip the issue** — `tmux kill-window -t "$PIPELINE_TMUX_SESSION:issue-<N>"`; runner picks the next from the bucket.

   Runner NEVER kills autonomously. The orchestrator's prompt to the user is the kill gate.

6a. **Post-dispatch completion verification (mandatory).** Immediately AFTER the inline foreground `Agent` batch returns (every dispatched PATH A/B/D issue in this wave) and BEFORE the Step 6b CI-fix loop, the orchestrator MUST verify each dispatched issue actually reached its terminal state — branch pushed **AND** PR open **AND** issue at `pr-open` — and **MUST NOT trust the agent's narrated self-report**. The #764/#814 dispatch-prompt + SKILL-body directives are necessary but **not** sufficient: they landed and were present, yet the narrate-and-yield drop-out RECURRED (#838/#904 — committed work, then *"...Waiting for the sweep Monitor..."*, no push, no PR, issue stuck at `in-progress`). This sub-step is the missing orchestrator-side backstop. For EVERY PATH A/B/D issue dispatched in the inline foreground batch, run:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" <N>
   ```

   and parse the single emitted `ACTION=` line (the token, not the exit code, carries the verdict — the helper exits 0 in every case, mirroring `check-ci-fix-loop.sh`; fail-closed: any unconfirmed terminal state emits a recover token, never `complete`). The helper resolves the feature branch **deterministically** — primary: the issue's worktree from `git worktree list --porcelain` (the `wt-<N>-<slug>` dir → its `branch refs/heads/<...>` ref, read verbatim — there is NO `feature/issue-<N>` convention); secondary: the issue's linked PR head — and pins the git remote to `origin` (`PIPELINE_REPO` is the gh owner/repo slug, not a git remote). Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `complete` | issue verified pushed + PR-open + labelled; proceed to 6b. |
   | `recover-push` | branch committed-but-unpushed: orchestrator finishes `git push -u origin <branch>` for the feature branch (branch as resolved by the helper), then re-run the helper. |
   | `recover-pr` | branch pushed, no PR: orchestrator runs `gh pr create --base "$PIPELINE_BASE_BRANCH"`, then re-run the helper. |
   | `recover-label` | PR open, issue still `in-progress`: orchestrator applies `pr-open` / removes `in-progress`, then re-run the helper. |
   | `recover-redispatch` | stranded with no committed work / no resolvable branch: re-dispatch the execute `Agent` for `<N>` (counts against the same wave). |

   This complements (does NOT replace) the `--spawn`/run-queue path's existing `executor_finished_terminal()` reap (`scripts/run-queue.sh:595`, #636/#666): that backstop covers the spawned-worker transport only. The gap closed here is specifically the INLINE foreground batch (#838/#904), which has no runner backstop.

6b. CI-fix loop (wave N) — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]` (colon-LESS fallback per #858: unset ⇒ ON to match the documented `.example` default; explicit `=""` ⇒ OFF to preserve the no-CI consumer contract; `="true"/"false"` honored). For each of wave N's `pr-open` issues, fullsend invokes `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and parses the emitted `ACTION=` line. The helper resolves issue→PR **deterministically per-issue** — closing-PR ref → the issue's `git worktree list` branch ref (`--head <ref>`) → body reference, from the orchestrator CWD where the worktrees are siblings — so a concurrent wave with ≥2 open PRs never misroutes to another issue's PR (#909). The invocation takes a single `<N>` arg (no branch/PR wiring). Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` is the authoritative source for issue→PR resolution (deterministic per-issue: closing-PR ref → worktree branch ref → body reference; never "latest open PR" — #909), retry-counter encoding (`pipeline.ci-retries: <n>` issue comment), tail-truncated failure-log path (`.claude/logs/ci-fix-<N>-attempt-<n>.log`), and `human` label application on budget-exhaust.

7. **Evaluate PRs (wave N)** — once wave N's agents finish (queue complete), run `/pipeline:evaluate-issue-pr N` for every wave-N `pr-open` issue (via `run-queue.sh --skip-permissions --skill evaluate-issue-pr`), and apply the per-PR greenlight auto-merge gate from the `## Greenlight matrix` above to each.

   **`--spawn` override (#750).** When `--spawn` is present, route **every path's PR-eval through `run-queue.sh --skill evaluate-issue-pr`** — including the paths whose PR-eval is inline by default (PATH B). PATH C PR-eval is already queued, so for C this is a documented no-op. When `--spawn` is absent, the default below applies (PATH B PR-eval inline, others via the run-queue). Launch this queue via `Bash` with `run_in_background: true` as described in step 6, then wait on it with the same event-driven waiter (identical to Step 6's waiter): a single `Monitor` invocation against the bash task's captured stdout stream (queried via the `BashOutput` tool — do NOT tail `queue-*.log`), with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000`. Apply the same wake-loop dispatch and "Triage on agent-stalled wakes" sub-section above — `agent-finished outcome=failed` is the per-agent failure signal (no separate `agent-failed`), `queue-complete` is terminal.

   **Inline PR-eval dispatch prompt contract (mandatory).** Whenever an `evaluate-issue-pr` evaluation is dispatched as an inline `Agent` (PATH A/B/D re-dispatch, or any pr-open issue evaluated inline rather than via the run-queue), the Agent prompt MUST end with a directive stating the dispatched evaluator's *only* valid terminal states are: **(a)** a `## Evaluation` comment posted with an explicit `**Verdict:**` line AND the greenlight gate fired (merged on `green`, or left with a `block-*` reason token); or **(b)** the eval failed, reporting a FAILED line. Narrating an intention to "wait" / "await CI" (e.g. *"All plan items verified. Awaiting the suite/CI output."*) — or returning verification prose instead of posting the verdict and firing the gate — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the PR un-evaluated at `pr-open` and forces a fresh re-dispatch (the #765 drop-out). The evaluator must instead run to completion (post `## Evaluation` → fire greenlight gate) or actually block on pending CI via `Monitor`/`BashOutput` before yielding. A `general-purpose` subagent may never load `skills/evaluate-issue-pr/SKILL.md`, so this dispatch-site directive — not the skill body — is the binding contract. (Fullsend is now the sole owner of this PR-eval dispatch contract; `/pipeline:status` is read-only and no longer dispatches, mirroring the #764/#771 execute precedent.)
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

## Dispatch routing by path tier (reference)

This section consolidates the per-path dispatch contract for the autonomous flow — the canonical home for the routing detail that previously lived in `/pipeline:run`. `/pipeline:status` is read-only and no longer dispatches; fullsend owns all dispatch.

**For PR evaluation (pr-open → evaluated).** Use the same launch flow as execution — the worktree already exists from execute-issue-plan, no setup needed. Read each PR-open issue's labels and route by tier:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux. Reuse the existing `<worktree-path>`:
     ```
     Agent(subagent_type='general-purpose',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
   - **PATH B** (standard): dispatch inline — No spawn-claude.sh, no `claude -p`, no tmux. The worktree already exists; reuse it:
     ```
     Agent(subagent_type='general-purpose',
           description='evaluate-issue-pr #<N> (PATH B inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
     No spawn-claude.sh, no run-queue.sh, no tmux. The inline B execute Agent and the inline B PR-eval Agent are SEPARATE inline contexts — an agent must not evaluate its own work.
   - **PATH C** (`multi-task`): proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh`.
   - **PATH D**: PR evaluation stays `general-purpose` (NOT `tdd-implementer`) — inline dispatch shape identical to PATH A.

**For execution (plan-approved → worktree setup).** After the worktree is set up, read each approved issue's labels and route by tier:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux:
     ```
     Agent(subagent_type='general-purpose',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
   - **PATH B** (standard): dispatch inline — `subagent_type='general-purpose'` (NOT `tdd-implementer`); B's red→green discipline comes from the plan's Task 0 `superpowers:test-driven-development` bookend inside execute-issue-plan:
     ```
     Agent(subagent_type='general-purpose',
           description='execute-issue-plan #<N> (PATH B inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
     No spawn-claude.sh, no run-queue.sh, no tmux. The PATH B execute `model=` param is eligibility-gated — it is passed ONLY when `scripts/path-b-execute-eligible.sh <N>` returns `low-blast` (see **Per-path execute MODEL routing** below); high-blast B inherits Opus.
   - **PATH C** (`multi-task`): dispatch inline by DEFAULT — the orchestrator reads the `## Implementation Plan` and fans out one `Agent(subagent_type='tdd-implementer', description='execute-issue-plan #<N> target=<dir>/ ...', prompt: 'cd <leaf-worktree>; target=<dir>/ ...')` per `target=<dir>`, **each in its OWN per-leaf worktree** via `scripts/path-c-split-worktree.sh setup` (#896) so concurrent leaves never share a git index (the #894 c+d collision: transient `index.lock` + one leaf's files folded into another's commit). Concurrency is therefore **bounded only by orchestrator context** — fan out non-overlapping targets up to the **max-3 foreground bound** (keep leaf returns terse); the earlier conservative 1–2 git-index cap is retired by this fix. When every leaf reports committed, the orchestrator runs `path-c-split-worktree.sh reassemble <feature-worktree> <target>...` (cherry-picks each leaf's commits onto the feature branch — disjoint targets ⇒ conflict-free; a conflict aborts and signals non-disjoint targets), then `teardown`, then handles push + `gh pr create` + labels itself. The orchestrator MUST NOT `Edit`/`Write` impl files directly — the `enforce-path-c-delegation` hook blocks it and authorizes only files under a dispatched `target=<dir>` sentinel; cherry-pick is a git op and is unaffected. `tdd-implementer` is dispatched from the top level as a hard leaf executor (no grandchild dispatch). **Under `--spawn`, revert to the legacy `spawn-claude.sh` / `run-queue.sh` → `tdd-implementer` fan-out** (the reversible #750 escape hatch — already per-worker isolated, so no split-worktree step). **Live branch-test merge gate (satisfied by #894/#896):** inline-C's first rollout was operator-gated — one real PATH C issue (the #892/#894 probes) was run through inline fan-out FROM THE FEATURE BRANCH with `--manual-merge`; that test surfaced the shared-index race now fixed by per-leaf worktrees, clearing the gate.
   - **PATH D** (`quick-fix`): dispatch inline via `Agent(subagent_type='tdd-implementer', description='execute-issue-plan #<N> (PATH D collapsed inline tdd)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')`. No spawn-claude.sh, no tmux, no run-queue.sh. The subagent_type uses the BARE `tdd-implementer` form (NOT a namespaced form).

     **Collapsed-D ceremony.** That single dispatch is **one collapsed inline `Agent`** doing **classify+plan+execute** in a single carried-forward context — NOT three separate Agent dispatches. The classify and plan stages run inside that same single context (carried-forward, not re-spawned). pr-eval stays a SEPARATE inline agent — evaluator independence is the reason it is never folded in. Bound the foreground batch at **max 3 concurrent inline** D agents.

   - **Per-path execute MODEL routing (#868 default-off gate).** Before dispatching a PATH B or PATH D **execute** `Agent`, source `pipeline.config` and read `PIPELINE_PATH_B_MODEL_EXECUTE` (PATH B) / `PIPELINE_PATH_D_MODEL_EXECUTE` (PATH D). Pass `model=<value>` to that `Agent(...)` dispatch **only when the var is set and non-empty** (value is the `model` enum: `sonnet`|`opus`|`haiku`). When unset/empty, pass **NO** `model=` param — the inline subagent inherits the orchestrator's Opus, which is the current behavior **byte-for-byte**.

     **PATH B eligibility gate (#955 — restrict the Sonnet downshift to the #950 §4 low-blast lane).** For **PATH B ONLY**, the `PIPELINE_PATH_B_MODEL_EXECUTE` var being set is **necessary but not sufficient**: additionally run `PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-b-execute-eligible.sh" <N>` and parse the single emitted `ELIGIBLE=<low-blast|high-blast>` token. Pass `model=$PIPELINE_PATH_B_MODEL_EXECUTE` to the PATH B execute `Agent` **only when BOTH** the var is set/non-empty **AND** `ELIGIBLE=low-blast` — the #950 §4 low-blast lane: ≤1 source module (excl tests/docs), ≤150 added-LOC, ≤6 files, no security/migration/auth/concurrency signal. When `ELIGIBLE=high-blast` (including the fail-closed `indeterminate` verdict), pass **NO** `model=` param — high-blast PATH B **inherits** the orchestrator's Opus, unchanged from pre-gate behavior. The predicate is a pre-execute classify/plan-time **estimate** (added-LOC is not known from a diff at dispatch time — it is proxied from the module/file bounds plus an optional `~N LOC` body override), mirroring `docs/analysis/model-downsampling.md` §4; it fails closed to Opus (high-blast) on any indeterminate signal so the cheaper tier is never selected on uncertain blast-radius.

     **PATH D stays unconditional EXCEPT needs-browser** — `PIPELINE_PATH_D_MODEL_EXECUTE` applies to **all** PATH D issues with no eligibility predicate (all D is in-lane by construction), with ONE carve-out: when a PATH D issue carries the `needs-browser` label, pass **NO** `model=` param — it inherits the orchestrator's Opus (issue #960: the #950 Sonnet-on-execute pilot validated shell-helper fixtures only; browser/UI execute was never measured, so a needs-browser D must not downshift). Example (PATH D): `Agent(subagent_type='tdd-implementer', model='sonnet', description='execute-issue-plan #<N> ...', prompt='cd <wt>; ...')` when `PIPELINE_PATH_D_MODEL_EXECUTE=sonnet`, else the un-`model=` form above. **This gate applies to the execute dispatch ONLY: the pr-eval dispatch is NEVER gated** — the independent evaluator stays on the inherited Opus backstop (dropping the evaluator's tier would remove the regression catcher that makes a cheaper-execute pilot safe). The flag is host-only (gitignored `pipeline.config`); the shipped default is unset, so consumers see no behavior change.

## Merge orchestration (reference)

After all evaluations complete, fullsend merges via the greenlight gate (the per-PR auto-merge loop, `## Greenlight matrix` above). Default is **autonomous merge for the green subset**.

**Pre-merge pairwise overlap scan.** Before the sequential merge loop, source `${CLAUDE_PLUGIN_ROOT}/scripts/detect-merge-overlap.sh` and run `detect_merge_overlap` over the approved-PR set to surface pairwise file overlaps; `recommend_merge_order` returns a fewest-overlap-first ordering to use for the loop. Advisory — does not block.

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

Use `${ORDERED[@]}` as the iteration order for the sequential merge loop. Before each merge: detect the PR's base branch; if it diverges from `.claude/base-branch` (or `PIPELINE_BASE_BRANCH`), call `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE`. Check `mergeable`; on conflict, rebase in the worktree and force-push with `--force-with-lease`, retrying merge. Merge PRs sequentially to avoid cascading conflicts. Validate the PR title against the Conventional Commits format (`scripts/check-conventional-title.sh`).

**Constraints during full send:**

Slate-pre-hygiene (housekeeping, worktree cleanup, discovery) is owned by `/pipeline:status`; fullsend assumes a clean slate and does not re-implement that flow.

- Issues labeled `PIPELINE_LABELS_EXCLUDED` are always skipped.
- Issues labeled `PIPELINE_LABELS_LATER` are shown in the final report (stage = `PIPELINE_LABELS_LATER`) but not processed.
- Issues labeled `PIPELINE_LABELS_HUMAN` are shown in the final report (stage = `PIPELINE_LABELS_HUMAN`) but never processed by autonomous full send. These need a human in the loop — usually for architecture decisions, cross-platform validation, production deploy risk, or items where the planner can't make the right call without you. They must be picked up manually with `/pipeline:plan-issue` / `/pipeline:execute-issue-plan`, never via full send.
- Issues labeled `PIPELINE_LABELS_BRAINSTORM` are shown in the final report (stage = `PIPELINE_LABELS_BRAINSTORM`) but never processed by autonomous full send — same handling as `PIPELINE_LABELS_HUMAN`. The body is open-ended discussion/architectural critique, not a commit-to-act spec. Manual pickup via `/pipeline:plan-issue` is allowed once the idea crystallizes.
- Blocked issues (blocked-by dependency not yet merged) are skipped; noted in final report as "Blocked".
- The re-plan loop cap of 3 prevents infinite loops on stubborn issues.
- If any stage fails unexpectedly (script error, API failure), stop full send and report the failure with enough detail for the user to diagnose.
