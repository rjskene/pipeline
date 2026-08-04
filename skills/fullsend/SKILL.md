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

## Usage gate (#969)

> **RED FLAGS — read before acting on any `pause-5h`:**
> 1. **Auto-resume is the DEFAULT on `pause-5h`.** NEVER stop-and-ask the operator "should I resume?" — arm the cron and yield; the cron resumes the campaign on its own.
> 2. **NEVER `ScheduleWakeup`** (or any delay-based one-shot) at `resume_at` — a one-shot is turn-coupled, can fire while still throttled, and is silently superseded by intervening conversation (R2/R3).
> 3. **The ONLY resume mechanism is a recurring `CronCreate` on `13,38 * * * *`** — turn-independent, fires on wall-clock regardless of conversation activity.

**Single source of truth for the usage-aware pause/resume control loop.** `scripts/usage-gate.sh` reads real account usage from the OAuth endpoint behind Claude Code's `/usage` panel and emits ONE deterministic decision line; the script decides, this prose obeys (the `auto-merge-gate.sh` pattern). Call sites below reference this section — no duplicated machinery anywhere. Knobs: `PIPELINE_USAGE_GATE_ENABLED` (default `true`; `false` disables) and `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default `85`, applies to both windows). Spec: `docs/superpowers/specs/2026-06-10-usage-gate-design.md`.

**Invocation (never gate-fatal):**

```bash
GATE_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true)
```

Always relay `$GATE_LINE` in the run log, then branch on its `decision=` token:

- **`decision=proceed` / `decision=skip`** → continue. `skip` ≡ proceed plus an auditable `reason=` (`disabled`, `no-credentials`, `http-<code>`, `fetch-error`, `parse-error`) — the gate is fail-open and NEVER blocks a run on its own failure.
- **`decision=pause-5h`** → the five-hour window is at/over threshold; the outcome is **arm the recurring re-check cron and yield** (the campaign auto-resumes — this is NOT a stop-and-ask). The line's `resume_at=` is `five_hour.resets_at + 5 min` — treated as a **reporting ceiling + blind backstop only**, NOT a resume time (the endpoint over-states recovery; see spec #1016 R1):
  1. Report the remaining slate in ONE line — the issue numbers not yet at `pr-open`/merged.
  2. **Emit the arming spec deterministically, then transcribe it into ONE `CronCreate` call.** Run:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/arm-usage-resume-cron.sh" \
       --resume-command "<the exact /pipeline:fullsend command you are running>" \
       --resume-at <resume_at from this gate line>
     ```

     then make ONE `CronCreate` call with EXACTLY its emitted args. **Do NOT hand-reconstruct the schedule/marker/prompt** — the script now SOURCES those tokens (fixed `13,38 * * * *` cadence, marker `usage-resume re-check`, the fully-assembled **re-check firing contract** prompt, the `resume_at` value, the `/pipeline:fullsend <remaining issue numbers> <original flags>` resume command form, and the "resumed after usage pause; delete the usage-resume cron if present" idempotency note). The cron id does not exist until `CronCreate` returns, so "delete self" means `CronList` → match the marker → `CronDelete`. Report: remaining slate + "worst-case resume by `<resume_at>`" + the cron id.
  3. STOP the turn. Labels untouched; in-flight agents have already drained (the gate runs only BETWEEN waves — pause = do not dispatch the next wave).

  **`ScheduleWakeup` is NEVER the resume mechanism.** Do not arm a `ScheduleWakeup` (or any delay-based one-shot) at `resume_at` — a one-shot can fire while still throttled and is turn-coupled, so intervening conversation silently supersedes it (R2/R3). The recurring `CronCreate` above is the single, turn-independent mechanism.

  **Re-check firing contract** (each cron firing is a deliberately tiny turn): run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"`, relay the line, then branch on its `decision=`:
  - **`proceed`** → `CronList` → match marker `usage-resume re-check` → `CronDelete` self, then fire the resume command.
  - **`pause-5h`** → STOP the turn (one line). The cron PERSISTS; the next firing re-checks. A firing killed by the account cap self-heals — the cron recurs (this resilience is the core win over the one-shot).
  - **`halt-7d`** → `CronList` → `CronDelete` self, then a LOUD report (seven-day %, reset date, exact manual resume command). NEVER auto-resume a seven-day trip.
  - **`skip`** → NEVER resume on `skip` (a paused headless host has an ~hourly-expiring OAuth token; fail-open on `http-401` would resume at ~99%, R4) UNLESS `now ≥ resume_at + 10 min` → treat as `proceed` (R5 blind backstop — never worse than the old one-shot, even when the endpoint is unreadable). Otherwise STOP; the cron persists and the next firing's session refreshes creds.
- **`decision=halt-7d`** → same stop, NO schedule (a seven-day reset can be days away — never auto-resume). Loud report: the seven-day utilization %, the reset date, and the exact manual resume command (`/pipeline:fullsend <remaining issue numbers> <original flags>`).

**On resume** the pre-flight gate re-checks naturally: still over threshold → re-pause/halt again (re-arming the recurring re-check cron). A headless re-check firing with an expired access token degrades fail-open (`skip reason=http-401`); the re-check contract's `skip` branch governs it — the cron persists and the next firing re-checks once the session has refreshed creds, so a stale-token firing never resumes at ~99% (R4).

**Call sites** (each points here; one-line references only):
1. **Pre-flight** — before wave 1 of ANY stage (classify, plan, and execute waves all burn budget).
2. **Top of EVERY wave iteration** — the Step 1b classify/plan waves AND the `### Execute the slate WAVE BY WAVE` loop (before Step 5).
3. **Campaign leg boundary** — `## Campaign mode` (e)3, BESIDE the `usage-surface.sh` advisory (which stays read-only per #725; different substrate, untouched).

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
2a. **Leg-boundary base-ref drift guard (#1106 — Layer 2).** After the base advance and beside the usage gate below, snapshot `BASE0` before this leg's dispatch (at the START of step 1 above, `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")`), then call the guard with the leg's feature branches:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-ref-drift.sh" \
     "$PIPELINE_BASE_BRANCH" "$BASE0" <leg-feature-branches...>
   ```
   Act on the token identically to the Step 6a post-batch guard: `BASE=ok`/`BASE=recovered` → continue to next leg; `BASE=drift-unsafe ORPHANS=<shas>` → **halt the campaign** and report the orphan shas for manual recovery; `BASE=error REASON=<...>` → relay advisory, do NOT halt (fail-open). Note: `git -C "$MAIN_REPO" symbolic-ref --short HEAD` MUST equal `$PIPELINE_BASE_BRANCH` before this guard runs — verify the checkout is on the base branch before calling.
3. **Usage read-out at the leg boundary** (dogfood-only, #725) — after the base advance, render the rolling-window usage read-out and surface its headroom / throttle-ETA so the operator can size the next leg with the headroom number in hand. READ-ONLY advisory; never gate-fatal. **NO automated hold / queue / pacing is performed** — the read-out is purely informational (the control loop is explicitly out of scope per #725):
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-surface.sh" || true
   ```
   Then run the **usage gate** at this leg boundary and obey its decision line per `## Usage gate (#969)` — unlike the read-out above (advisory, #725), the gate DOES pause (`pause-5h`) or halt (`halt-7d`) the campaign between legs.
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
2. **Apply the classify-clean skip (model judgment, NOT mechanized).** For each `FOLD` line, additionally **skip (leave posted)** any signal that would classify `human` / `brainstorm` / `excluded` — these always wait for human review. The `fold-select` script only does the mechanical FIFO + ceiling + high-uncertainty keyword skip over the **word-bound** shared regex (`concurrency` / `race` / `lock` / `deadlock` / `security` / `auth` / `crypto` / `migration` / `data-loss`, sourced from `scripts/_high-uncertainty-match.sh` so `authoring`/`block`/`trace` do NOT false-trigger — #1039); the **non-autonomous** classify-clean decision is yours here and is a **semantic** judgment, not a substring match. A `FOLD` line that you classify non-autonomous is demoted to the leave-posted set exactly like `SKIP`/`OVERFLOW`.
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

**block-base-mismatch** is enforced as defense-in-depth — PR `baseRefName` must equal `PIPELINE_BASE_BRANCH` (see #295). **Next-branch aware (#1148):** `baseRefName == ${PIPELINE_NEXT_BRANCH:-next}` is ALSO accepted, but ONLY when the PR's issue is next-routed — carries `${PIPELINE_NEXT_LABEL:-next}` or the legacy alias `next-major-release` (resolved via `gh issue view --json labels`). A PR targeting the next branch for a non-next issue still `block-base-mismatch`; an empty base still fails closed. Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → verdict → `block-base-mismatch` → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, `block-flag`, `block-label`, `block-verdict`, `block-base-mismatch`, `block-ci`, `block-mergeable`, `block-mergestate`.

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
   - **Stage-model pin (#1186, mandatory):** before EACH `/pipeline:plan-issue N` Agent dispatch, resolve the plan model from the single-source stage resolver and pass it verbatim — a plan dispatch with no `model=` does not "inherit Opus", it inherits whatever the session model is:
     ```bash
     PLAN_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan)
     ```
     It emits `ISSUE=`/`STAGE=`/`PATH=`/`MODEL=`/`REASON=` (always exits 0; `MODEL=` is ALWAYS a named model). **ALWAYS pass `model=$MODEL`** on the plan `Agent(...)`, and relay `REASON=` in the wave log. Defaults: PATH A/B ⇒ `opus`, PATH C ⇒ `PIPELINE_PATH_C_MODEL_PLAN` (unset ⇒ `fable` — cross-unit leaf-boundary meshing is Fable's edge), with the W2 high-uncertainty carve-out forcing `opus` over both the default and an explicit knob. The **classify** dispatch is deliberately NOT pinned (it still inherits — the cheap-stage open item); PATH D is excluded from this step entirely and its collapsed inline dispatch carries the resolved EXECUTE model instead.
   - **Usage gate at every wave top (#969):** before dispatching wave 1 (the pre-flight) and again at the top of EVERY classify/plan wave iteration, run the gate and obey its decision line per `## Usage gate (#969)`.
   - **Dispatch prompt contract (mandatory):** each `/pipeline:plan-issue N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 and it reports the success line, or (b) `post-plan.sh` exited non-zero and it reports the FAILED line. Returning the plan body in chat is a failure — the plan does not exist until `post-plan.sh` has posted the `## Implementation Plan` comment and applied the `plan-pending` label. A `general-purpose` subagent may never load `skills/plan-issue/SKILL.md` (it can treat `/pipeline:plan-issue N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract.
   - **`--debug-first` propagation (#997):** when fullsend was invoked with `--debug-first`, each dispatched plan-issue Agent's prompt MUST carry the flag (e.g. `/pipeline:plan-issue N --debug-first`) so the subagent runs plan-issue's Step 4a diagnosis gate. The flag is a one-off invocation toggle and does NOT live on the issue, so it has to be threaded through the dispatch explicitly. The durable `needs-debug` LABEL, by contrast, flows through for free — the dispatched plan-issue resolves it from the issue's OWN labels, so an issue already tagged `needs-debug` hits the gate with or without the flag. Propagation is therefore needed only for the one-off `--debug-first` flag, never for the label.
   - **Verify plan comments:** After all plan-issue agents complete, for each issue that was targeted (had no pipeline label at the start of this step), confirm a plan comment was posted:
     ```bash
     PLAN_COUNT=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     ```
     If any targeted issue has `PLAN_COUNT == 0` (regardless of whether `plan-pending` was added), the plan-issue agent failed. Re-run `/pipeline:plan-issue N` for that issue (max 1 retry). If still missing after retry, skip the issue and flag it in the final report as "Skipped (plan not posted)".
2. **Evaluate plans** — run `/pipeline:evaluate-issue-plan N` for every `plan-pending` issue (in parallel, one Agent per issue). Wait for all to complete.

   **Stage-model pin (#1186, mandatory).** Before each `evaluate-issue-plan` Agent dispatch, resolve `PIPELINE_STAGE_MODEL_PLAN_EVAL` through the same single source and **ALWAYS pass `model=$MODEL`**:
   ```bash
   PLAN_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> plan-eval)
   ```
   The resolver emits `tier-max(this issue's plan model, PIPELINE_STAGE_MODEL_PLAN_EVAL)` (unset ⇒ `opus`), so the **gate never lands below its producer** — a PATH C plan produced on `fable` is gated on `fable` (`REASON=follows-producer`), and a knob set below the producer cannot drop it. Plan approval is an auto-gate with no human behind it in fullsend, which is why equal-tier is acceptable but below-tier is not.
3. **Re-plan loop** — for any issue whose evaluation verdict is "Revise": re-run `/pipeline:plan-issue N`, then `/pipeline:evaluate-issue-plan N` — **each re-dispatch re-resolves its stage pin** exactly as in Step 1b / Step 2 (`resolve-stage-model.sh <N> plan` / `<N> plan-eval`) and always passes `model=$MODEL`. Repeat until all pass (max 3 iterations per issue). If an issue still fails after 3 iterations, skip it and flag it in the final report.
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

For each wave N, in wave order, serially run Steps 5 → 6 → 6b → 7 against ONLY that wave's issue numbers, then perform the **inter-wave pull** before starting wave N+1. **At the top of each execute wave (before Step 5), run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"` and obey its decision line per `## Usage gate (#969)`** — pause/halt happens between waves, never mid-wave.

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

   **Next-branch routing (#1128).** Before invoking `setup-worktree.sh`, resolve the issue's labels. If the issue carries `${PIPELINE_NEXT_LABEL:-next}` OR the legacy `next-major-release` alias, prepend `--base "${PIPELINE_NEXT_BRANCH:-next}"` so the worktree is cut from — and the PR targets — the next-integration branch (`setup-worktree.sh` fetches/creates it; see the actuation in `scripts/setup-worktree.sh`). For unlabelled issues, omit `--base` (the default base-tip behavior below is unchanged). Example for a next-labelled issue: `setup-worktree.sh --base next feature/<slug> <issue-number>`.

   **Do NOT invoke with only the issue number** — the script will reject it as of #350. A bare integer like `setup-worktree.sh 81` fails the branch-prefix guard because `81` is not a `feature/<slug>` shape; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.

   **Base-tip note (the #626 fix).** `setup-worktree.sh` adds the worktree via `git worktree add -b`, which **branches off the main repo's LOCAL HEAD, not `origin/<base>`**; the `--base` / `$BASE_BRANCH` value there is only metadata, not a remote fetch. So a wave's worktrees inherit exactly whatever the orchestrator's local base tip points at *at the moment Step 5 runs*. That is why the inter-wave pull (below) is mandatory between waves.
6. **Execute (wave N)** — launch wave N's worktrees via the tmux queue runner with skip-permissions enabled (equivalent to user answering "tmux / y" at the launch prompt). Scope `run-queue.sh` to ONLY wave N's issue numbers — never mix issues from a later wave into the same queue (no cross-wave concurrency). **Within-wave parallelism is preserved:** same-wave issues that have no dependency or file-conflict edge between them still run concurrently up to run-queue's `MAX_AGENTS` cap — do not over-serialize within a wave. Launch the queue runner via `Bash` with `run_in_background: true` — do NOT use a foreground `while ... sleep ... grep` poll loop. Wait for terminal events with a single `Monitor` invocation against the queue runner's captured stdout stream — the `Bash` tool's `run_in_background: true` task captures the runner's stdout, queryable via the `BashOutput` tool. That captured stdout is the always-on wake channel because `log()` (`scripts/run-queue.sh:136-142`) emits every `EVENT:` line to stdout unconditionally, even when `PIPELINE_LOGS_ENABLED=false` (the `queue-*.log` file is gated and may not exist on consumer hosts — do NOT tail it). Invocation shape: `Monitor` on the bash task's stdout stream with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000` (preserves the existing 2h worst-case wait budget). Per Monitor's coverage rule, the filter MUST cover every terminal state (failure + completion) so a crash is never silent — `agent-finished outcome=failed` IS the per-agent failure signal (the runner does not emit a separate `agent-failed`). Status updates are emitted automatically by the queue runner every 3 minutes (configurable via `STATUS_INTERVAL`).

   **`--spawn` override (#750).** When `--spawn` is present in the fullsend argv, SKIP the inline foreground `Agent` batch entirely and route **every path's execute through the tmux `run-queue.sh`** — no inline at all. Scope the queue to wave N's issue numbers exactly as below. **PATH C execute is now inline-by-default (#749), so `--spawn` routes it back to the legacy `spawn-claude.sh` → `tdd-implementer` fan-out** (its reversible escape hatch — a LIVE effect on C, no longer a no-op); A/B/D execute also route onto the run-queue as before. When `--spawn` is absent, the split-dispatch default below applies unchanged (A/B/C/D inline foreground, all bounded at the same **max-3 foreground** concurrency — per-leaf worktrees mean C is no longer git-index-capped, #896).

   **Split dispatch for PATH D (#700) + PATH B (#748) + PATH C (#749).** Within wave N, partition the wave's issues by path. By DEFAULT (no `--spawn`) the wave's **conflict-free PATH A/B/C/D issues fan out as the inline foreground batch** at the same wall-clock — the C-only tmux **run-queue is now used ONLY when `--spawn` is set** (#750). The conflict-free PATH A/B/D issues fan out CONCURRENTLY as an inline `Agent` batch in the FOREGROUND, dispatched together in a single foreground batch, bounded at **max 3 concurrent inline** agents. **PATH C fans out inline too** — the orchestrator reads the plan and dispatches one `Agent(subagent_type='tdd-implementer', ...)` per `target=<dir>`, each in its OWN per-leaf worktree (`scripts/path-c-split-worktree.sh` setup/reassemble/teardown, #896) so concurrent leaves never share a git index (the #894 c+d collision). With isolated indexes the fan-out is **bounded only by orchestrator context, not a git-index cap** — the #894/#896 live branch test confirmed leaf returns are ~one line each with negligible context cost, so non-overlapping targets fan out concurrently up to the same **max-3 foreground bound** as A/B/D (keep leaf returns terse). The earlier conservative 1–2 cap is retired by the per-leaf-worktree fix. **PATH B dispatch shape is resolver-driven.** Resolve the dispatch spec via `scripts/resolve-execute-dispatch.sh` before dispatching. When `SPLIT_ROLE=true` (PATH B default, per `PIPELINE_PATH_B_SPLIT_ROLE` default `true`), dispatch **two sequential agents in the existing worktree** per `ROLES=red:opus,green:<model>`: (i) an Opus `red:opus` test-author commits the full failing suite in ONE commit whose subject contains the literal `[split-role-red]` substring, then (ii) a `green:<model>` implementer greens it additive-only AND completes ALL non-test plan deliverables. One `Agent(...)` carries exactly ONE `model=`, so `red:opus,green:<model>` REQUIRES two sequential dispatches — a single combined agent can never emit a `[split-role-red]` commit, which is why the default-on `split-role-gate.sh` blocks `no-red-sha` on single-agent PATH B PRs. When `SPLIT_ROLE=false` / `ROLES=single`, dispatch the single `Agent(subagent_type='general-purpose', ...)` as before (the pre-#1057 shape). PATH D uses `Agent(subagent_type='tdd-implementer', ...)`. The PATH D inline `Agent` is additionally the SINGLE collapsed context that carries classify+plan+execute forward in ONE dispatch — it is NOT a fresh execute dispatch that re-reads a plan posted by an upstream Step 1b plan Agent (D was EXCLUDED from Step 1b's per-stage classify/plan dispatch precisely so that its classify+plan run inline here); PATH B is classified+planned per-stage upstream as normal and its inline `Agent` only runs execute. The collapsed D agent's pr-eval — and PATH B's pr-eval — is NOT folded into the execute context: each stays the separate Step 7 `evaluate-issue-pr` dispatch (evaluator independence). The inline foreground batch **consumes zero queue slots** — it costs no run-queue slot and is free concurrency *atop* the C-only run-queue capacity, not carved out of it. Bound the foreground batch at **max 3 concurrent inline** agents. Policy: fire the inline foreground batch FIRST / alongside the C-only run-queue launch — the inline agents (especially D) typically finish fast while the C run-queue grinds for far longer, so launching the foreground batch first costs essentially no added wall-clock.

   **D is NOT exempt from wave discipline.** The wave plan from `plan-waves.sh --stage=execute` already orders ALL paths (A/B/C/D) together over a **unified file-conflict graph** (there is no path-label gate — see `scripts/plan-waves.sh` and `tests/test-plan-waves-unified-graph.sh`). So a PATH D (or PATH B) issue that shares a file with another in-flight issue (any path) is ALREADY serialized into a later wave by the planner — the inline foreground dispatch does NOT exempt it from wave serialization. Only the wave's **conflict-free** foreground issues fan out in the batch; issues that collide with this wave's other in-flight work were already deferred to a later wave and are dispatched there.

   **Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D `/pipeline:execute-issue-plan N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: **(a)** the PR is opened and the issue is flipped to `pr-open`, reporting the success line (PR number + final test status); or **(b)** the work failed, reporting a FAILED line. Narrating an intention to "wait" (e.g. *"I'll wait for the suite notification."*) — or returning prose/edits instead of committing, pushing, and opening the PR — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the subagent with uncommitted work in progress (the #752/#764 drop-out). The subagent must instead run to completion (commit → push → `gh pr create` → label flip) or actually block on the suite via `Monitor`/`BashOutput` before yielding. A `general-purpose`/`tdd-implementer` subagent may never load `skills/execute-issue-plan/SKILL.md` (it can treat `/pipeline:execute-issue-plan N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. (Mirrors the Step 1b plan-issue dispatch prompt contract.) The prompt MUST also carry the staging directive verbatim: **Stage ONLY explicit plan paths via `git add <paths>`; never `git add -A|.|-u` (the #1028 cruft-sweep contract). The `scripts/check-branch-cruft.sh` pre-PR guard backstops this by failing the open if cruft reached any commit on the branch.** **Cross-cutting guards dispatch directive (#1132).** The dispatched subagent MUST run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh"` pre-PR and abort on failure — a `general-purpose`/`tdd-implementer` subagent that never loads the skill body still sees this dispatch-site binding (defense-in-depth so the fast diff-independent invariant floor is always run, even by agents that skip the SKILL.md body). **When `SPLIT_ROLE=true` (PATH B default), the two-phase discipline rides the dispatch-site prompts** — each role's prompt carries its phase directive because a dispatched `general-purpose` subagent never loads `skills/execute-issue-plan/SKILL.md` and therefore cannot inherit the split-role contract from that skill body. The red-author prompt MUST direct the Opus agent to author the full failing suite and commit with the literal `[split-role-red]` substring in the subject; the green-implementer prompt MUST direct the agent to green the suite additive-only AND complete ALL non-test plan deliverables (greening the locked suite alone is not plan-complete), and the green-implementer prompt MUST direct the agent to run the FULL local suite green before `gh pr create` (not just the locked `[split-role-red]` files), so a green-introduced break in any non-locked test is caught locally rather than in CI (#1108). The green implementer may modify a test file ONLY if the approved plan explicitly lists it under `**Shared tests (split-role):**` — otherwise the green role touches NOTHING under `tests/` (the `evaluate-issue-pr` W7 gate enforces this via `PIPELINE_SPLIT_ROLE_SHARED_TESTS`; default-deny applies). The escalation valve (locked test is WRONG → STOP and report) is unchanged. **Git-anchoring + branch-assert (#1106 root-cause fix — dispatch-site, mandatory for RED/GREEN/collapsed-D).** Every git command in a dispatched prompt MUST be anchored with `git -C <worktree-abs-path>` — do NOT rely on cwd persisting across Bash calls (the Bash tool resets to the project root on each fresh invocation; the #1106 RED commit landed on `staging` because its initial `cd <worktree>` did not hold for the later `git commit`). AND: before ANY commit, the agent MUST assert `git -C <worktree-abs-path> symbolic-ref --short HEAD` equals the dispatched feature branch — if it does not, **STOP and report** (do not commit). **Worktree-index staging precondition (#1122).** Before ANY `git add`, the dispatched agent MUST stage into its OWN worktree index — every `git add` MUST be anchored `git -C <worktree-abs-path> add <paths>`, NEVER a bare `git add` (cwd may resolve to the main checkout) and NEVER `git -C <main-repo> add`. Linked worktrees have separate index files, so a correctly-anchored add cannot leak into the main checkout index (the #1122 leak: a split-role subagent's `git add` hit the MAIN index — the worktree index — leaving staged edits that blocked the inter-leg `git pull --ff-only`). This is a dispatch-site directive because a dispatched `general-purpose`/`tdd-implementer` subagent never loads `skills/execute-issue-plan/SKILL.md`; the binding contract must live here.

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

   **Post-dispatch model/shape verify (#1056, WARN-level).** For each dispatched **PATH A / PATH B / PATH C / PATH D** issue (#1186 widened this from B/D — A and C now carry real resolved pins, so their dispatches are verifiable too), alongside the `ACTION=` completion check above, also run the additive `--verify-dispatch` mode so a silent model/shape regression becomes VISIBLE in the run log (the #1056 invisible-cost gap — the inline path dispatched every PATH B/D execute WITHOUT a `model=`, inheriting Opus when config said Sonnet, with no signal). Thread the resolver's spec (the `MODEL=`/`SPLIT_ROLE=` the orchestrator just consumed in Step 6) and the model actually dispatched:

   ```bash
   VED_EXPECT_MODEL="$MODEL" VED_EXPECT_SPLIT_ROLE="$SPLIT_ROLE" VED_OBSERVED_MODEL="<model-dispatched>" \
     PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --verify-dispatch <N> <A|B|C|D>
   ```

   **The same WARN-level check extends to the pinned STAGE dispatches (#1186).** For each `plan` / `plan-eval` / `pr-eval` Agent dispatched in Steps 1b / 2 / 7, thread the stage resolver's `MODEL=` as `VED_EXPECT_MODEL` and the model actually passed as `VED_OBSERVED_MODEL`, using the issue's path letter:
   ```bash
   VED_EXPECT_MODEL="$MODEL" VED_EXPECT_SPLIT_ROLE=false VED_OBSERVED_MODEL="<model-dispatched>" \
     PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-execute-completion.sh" --verify-dispatch <N> <A|B|C|D>
   ```
   `VED_EXPECT_SPLIT_ROLE=false` keeps the shape scan inert (split-role is a PATH B *execute* property), so this is a pure model check: it makes a silently-unpinned stage dispatch VISIBLE instead of invisible, which is the whole failure class #1186 closes.

   It emits a single `DISPATCH=` token (`match` / `mismatch REASON=model:<got>!=<want>` or `REASON=shape:single!=split-role` / `warn REASON=model-unrecoverable`). Surface a `DISPATCH=mismatch` in the run log; it is WARN-level and does **not** by itself halt the wave — it is the missing feedback surface, not a new hard gate (it FAILs only on a definite mismatch and WARNs when the observed model is unrecoverable, e.g. the inline path with no `runs` row).

   **Base-ref drift guard (#1106 — Layer 2, post-batch, mandatory).** Alongside the completion + model/shape checks above, run the cause-agnostic drift guard. BEFORE dispatching the inline foreground batch, snapshot: `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")`. AFTER the batch returns, call the guard with the wave's feature branches:

   ```bash
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
   - `CLEAN=untracked-only` → the checkout carries ONLY untracked paths — typically operator-owned files that predate the run (`mock-web/`, `scratchpad/`, local notes). This is **not** the #1122 leak (that leak is an INDEX/tracked-file condition), and untracked paths do not abort `git pull --ff-only` unless an incoming path collides. Surface them in the run log as a WARN-level advisory (`git -C "$MAIN_REPO" status --short`) and continue. **Do NOT stash here** — never add the untracked flag (`-u`) to a stash at this boundary; it sweeps the operator's own untracked working files (#1207).
   - `CLEAN=dirty` → staged index entries and/or modified tracked files: a dispatched subagent's `git add` leaked into the main checkout index (the #1122 leak: a split-role subagent staged files in the MAIN index instead of its worktree index). Surface the dirty paths in the run log as a WARN-level advisory (`git -C "$MAIN_REPO" status --short`), then auto-recover with `git -C "$MAIN_REPO" stash push` — plain, with no untracked flag: the dirty verdict is index/tracked-only by construction (#1207), so a plain stash fully clears it and can never touch untracked operator files — BEFORE the inter-wave / inter-leg `git pull --ff-only` base advance; then continue. This is advisory, not a hard halt: it unblocks the base advance the leaked index would otherwise abort (the #1122 recovery). Note that base-ref-drift (committed) and clean-main (uncommitted index/worktree) are complementary guards — the drift guard compares committed base SHAs and cannot catch a leaked-but-uncommitted `git add` (which produces no stray commit); the clean-main guard closes that specific gap.

6b. CI-fix loop (wave N) — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]` (colon-LESS fallback per #858: unset ⇒ ON to match the documented `.example` default; explicit `=""` ⇒ OFF to preserve the no-CI consumer contract; `="true"/"false"` honored). For each of wave N's `pr-open` issues, fullsend invokes `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and parses the emitted `ACTION=` line. The helper resolves issue→PR **deterministically per-issue** — closing-PR ref → the issue's `git worktree list` branch ref (`--head <ref>`) → body reference, from the orchestrator CWD where the worktrees are siblings — so a concurrent wave with ≥2 open PRs never misroutes to another issue's PR (#909). The invocation takes a single `<N>` arg (no branch/PR wiring). Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` is the authoritative source for issue→PR resolution (deterministic per-issue: closing-PR ref → worktree branch ref → body reference; never "latest open PR" — #909), retry-counter encoding (`pipeline.ci-retries: <n>` issue comment), tail-truncated failure-log path (`.claude/logs/ci-fix-<N>-attempt-<n>.log`), and `human` label application on budget-exhaust.

7. **Evaluate PRs (wave N)** — once wave N's agents finish (queue complete), run `/pipeline:evaluate-issue-pr N` for every wave-N `pr-open` issue (via `run-queue.sh --skip-permissions --skill evaluate-issue-pr`), and apply the per-PR greenlight auto-merge gate from the `## Greenlight matrix` above to each.

   **Stage-model pin (#1186, mandatory).** Every `evaluate-issue-pr` dispatch — inline or queued — resolves its model from the single source and **ALWAYS passes `model=$MODEL`**:
   ```bash
   PR_EVAL_SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> pr-eval)
   ```
   `PIPELINE_STAGE_MODEL_PR_EVAL` (unset ⇒ `opus`) makes W3 a REAL pin rather than an inheritance side-effect; no carve-out can lower it, and an explicit knob below the resolved execute tier is honored but emits a stderr WARN — relay that WARN in the wave log. pr-eval is never routed through `resolve-execute-dispatch.sh` (its stage-word guard exits 2).

   **`--spawn` override (#750).** When `--spawn` is present, route **every path's PR-eval through `run-queue.sh --skill evaluate-issue-pr`** — including the paths whose PR-eval is inline by default (PATH B). PATH C PR-eval is already queued, so for C this is a documented no-op. When `--spawn` is absent, the default below applies (PATH B PR-eval inline, others via the run-queue). Launch this queue via `Bash` with `run_in_background: true` as described in step 6, then wait on it with the same event-driven waiter (identical to Step 6's waiter): a single `Monitor` invocation against the bash task's captured stdout stream (queried via the `BashOutput` tool — do NOT tail `queue-*.log`), with filter regex `EVENT: (agent-stalled|agent-finished|queue-complete)` and `timeout_ms=7200000`. Apply the same wake-loop dispatch and "Triage on agent-stalled wakes" sub-section above — `agent-finished outcome=failed` is the per-agent failure signal (no separate `agent-failed`), `queue-complete` is terminal.

   **Inline PR-eval dispatch prompt contract (mandatory).** Whenever an `evaluate-issue-pr` evaluation is dispatched as an inline `Agent` (PATH A/B/D re-dispatch, or any pr-open issue evaluated inline rather than via the run-queue), the Agent prompt MUST end with a directive stating the dispatched evaluator's *only* valid terminal states are: **(a)** a `## Evaluation` comment posted with an explicit `**Verdict:**` line AND the greenlight gate fired (merged on `green`, or left with a `block-*` reason token); or **(b)** the eval failed, reporting a FAILED line. Narrating an intention to "wait" / "await CI" (e.g. *"All plan items verified. Awaiting the suite/CI output."*) — or returning verification prose instead of posting the verdict and firing the gate — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the PR un-evaluated at `pr-open` and forces a fresh re-dispatch (the #765 drop-out). The evaluator must instead run to completion (post `## Evaluation` → fire greenlight gate) or actually block on pending CI via `Monitor`/`BashOutput` before yielding. A `general-purpose` subagent may never load `skills/evaluate-issue-pr/SKILL.md`, so this dispatch-site directive — not the skill body — is the binding contract. **Pre-greenlight cross-cutting guards (#1132): the prompt MUST direct the dispatched evaluator to run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/check-cross-cutting-guards.sh"` in Phase 2 even when the #957 green-CI short-circuit skips the full `$PIPELINE_TEST_CMD` re-run — the short-circuit runs no local cross-cutting re-check, and the aggregator is the seconds-fast diff-independent floor.** (Fullsend is now the sole owner of this PR-eval dispatch contract; `/pipeline:status` is read-only and no longer dispatches, mirroring the #764/#771 execute precedent.)
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

**For PR evaluation (pr-open → evaluated).** Use the same launch flow as execution — the worktree already exists from execute-issue-plan, no setup needed. Read each PR-open issue's labels and route by tier. **Every** shape below carries `model=$MODEL` from `bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stage-model.sh" <N> pr-eval` (`PIPELINE_STAGE_MODEL_PR_EVAL`, unset ⇒ `opus`) — the W3 pin, #1186:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux. Reuse the existing `<worktree-path>`:
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-pr-eval-model>',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
   - **PATH B** (standard): dispatch inline — No spawn-claude.sh, no `claude -p`, no tmux. The worktree already exists; reuse it:
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-pr-eval-model>',
           description='evaluate-issue-pr #<N> (PATH B inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
     No spawn-claude.sh, no run-queue.sh, no tmux. The inline B execute Agent and the inline B PR-eval Agent are SEPARATE inline contexts — an agent must not evaluate its own work.
   - **PATH C** (`multi-task`): proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh`.
   - **PATH D**: PR evaluation stays `general-purpose` (NOT `tdd-implementer`) — inline dispatch shape identical to PATH A.

**For execution (plan-approved → worktree setup).** After the worktree is set up, read each approved issue's labels and route by tier:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux. Resolve the spec first (`scripts/resolve-execute-dispatch.sh <N> A`, #1186 — A was previously dispatched with NO `model=` at all) and carry `model=$MODEL` (`PIPELINE_PATH_A_MODEL_EXECUTE`, unset ⇒ `opus`):
     ```
     Agent(subagent_type='general-purpose',
           model='<resolved-model>',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
   - **PATH B** (standard): dispatch inline — resolver-driven via `scripts/resolve-execute-dispatch.sh`. No spawn-claude.sh, no run-queue.sh, no tmux. The execute model and split-role shape are ALWAYS resolved from the single-source resolver (see **Per-path execute MODEL routing** below). **When `SPLIT_ROLE=true`** (PATH B default, `PIPELINE_PATH_B_SPLIT_ROLE` defaults `true`), dispatch **two sequential agents in the same worktree** per `ROLES=red:opus,green:<model>`:
     ```
     # Phase i — red:opus Opus test-author
     Agent(subagent_type='general-purpose',
           model='opus',
           description='execute-issue-plan #<N> split-role RED (PATH B inline)',
           prompt: '...<red-author directive: author full failing suite, commit [split-role-red]>...')
     # Phase ii — green:<model> implementer
     Agent(subagent_type='general-purpose',
           model='<resolved-model>',
           description='execute-issue-plan #<N> split-role GREEN (PATH B inline)',
           prompt: '...<green directive: green the locked suite additive-only + complete ALL approved-plan tasks incl. non-test deliverables>...')
     ```
     One `Agent(...)` carries exactly ONE `model=`, so `red:opus,green:<model>` REQUIRES two sequential dispatches. **When `SPLIT_ROLE=false` / `ROLES=single`**, dispatch the single `Agent(subagent_type='general-purpose', ...)` as before. The PATH B execute `model=` param defaults to `sonnet` under the #1042 opt-out default (`PIPELINE_PATH_B_ELIGIBLE_SCOPE` defaults to `all`, so non-W2 PATH B routes Sonnet even on a `high-blast` verdict); under the `scope=low-blast` opt-out a `high-blast` verdict pins opus instead (see **Per-path execute MODEL routing** below). A W2 carve-out always pins opus (`model=opus`) — never an inherit (#1186).
   - **PATH C** (`multi-task`): dispatch inline by DEFAULT — resolve the spec ONCE via `scripts/resolve-execute-dispatch.sh <N> C` (#1186 — C leaves previously carried NO `model=`) and give EVERY leaf the same `model=$MODEL` (`PIPELINE_PATH_C_MODEL_EXECUTE`, unset ⇒ `opus`). The orchestrator reads the `## Implementation Plan` and fans out one `Agent(subagent_type='tdd-implementer', model='<resolved-model>', description='execute-issue-plan #<N> target=<dir>/ ...', prompt: 'cd <leaf-worktree>; target=<dir>/ ...')` per `target=<dir>`, **each in its OWN per-leaf worktree** via `scripts/path-c-split-worktree.sh setup` (#896) so concurrent leaves never share a git index (the #894 c+d collision: transient `index.lock` + one leaf's files folded into another's commit). Concurrency is therefore **bounded only by orchestrator context** — fan out non-overlapping targets up to the **max-3 foreground bound** (keep leaf returns terse); the earlier conservative 1–2 git-index cap is retired by this fix. When every leaf reports committed, the orchestrator runs `path-c-split-worktree.sh reassemble <feature-worktree> <target>...` (cherry-picks each leaf's commits onto the feature branch — disjoint targets ⇒ conflict-free; a conflict aborts and signals non-disjoint targets), then `teardown`, then handles push + `gh pr create` + labels itself. The orchestrator MUST NOT `Edit`/`Write` impl files directly — the `enforce-path-c-delegation` hook blocks it and authorizes only files under a dispatched `target=<dir>` sentinel; cherry-pick is a git op and is unaffected. `tdd-implementer` is dispatched from the top level as a hard leaf executor (no grandchild dispatch). **Under `--spawn`, revert to the legacy `spawn-claude.sh` / `run-queue.sh` → `tdd-implementer` fan-out** (the reversible #750 escape hatch — already per-worker isolated, so no split-worktree step). **Live branch-test merge gate (satisfied by #894/#896):** inline-C's first rollout was operator-gated — one real PATH C issue (the #892/#894 probes) was run through inline fan-out FROM THE FEATURE BRANCH with `--manual-merge`; that test surfaced the shared-index race now fixed by per-leaf worktrees, clearing the gate.
   - **PATH D** (`quick-fix`): dispatch inline via `Agent(subagent_type='tdd-implementer', description='execute-issue-plan #<N> (PATH D collapsed inline tdd)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')`. No spawn-claude.sh, no tmux, no run-queue.sh. The subagent_type uses the BARE `tdd-implementer` form (NOT a namespaced form).

     **Collapsed-D ceremony.** That single dispatch is **one collapsed inline `Agent`** doing **classify+plan+execute** in a single carried-forward context — NOT three separate Agent dispatches. The classify and plan stages run inside that same single context (carried-forward, not re-spawned). pr-eval stays a SEPARATE inline agent — evaluator independence is the reason it is never folded in. Bound the foreground batch at **max 3 concurrent inline** D agents.

   - **Per-path execute MODEL routing — SINGLE-SOURCE resolver (#1056).** Before dispatching a PATH A, PATH B, PATH C or PATH D **execute** `Agent` (for PATH C, before dispatching the leaves — every `target=<dir>` leaf carries the SAME resolved model), do **NOT** hand-apply the model/scope/split-role decision — that hand-applied prose drifting from the config knobs WAS the #1056 root cause (every PATH B/D execute silently inherited Opus, defeating the entire #1042 cheaper-execute default). Instead, resolve the FULL dispatch spec from the single-source resolver and consume its emitted tokens **verbatim**:

     ```bash
     SPEC=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-execute-dispatch.sh" <N> <A|B|C|D>)
     ```

     The resolver emits one token per line — `MODEL=`, `SPLIT_ROLE=`, `ROLES=`, plus the advisory `ELIGIBLE=`/`SCOPE=`/`REASON=` audit (it ALWAYS exits 0; the verdict rides the tokens, mirroring `path-b-execute-eligible.sh`). Apply them:
     - **ALWAYS pass `model=$MODEL`** on the execute `Agent(...)` dispatch. There is no longer a no-`model=` special case: since #1186 the resolver emits a NAMED model in every configuration (`inherit` is retired), because an unpinned dispatch does not inherit Opus — it inherits whatever the session model happens to be, which under a Fable-ceiling session is Fable.
     - **When `SPLIT_ROLE=true`** (PATH B only), dispatch the **two sequential agents in the existing worktree** per `ROLES=red:opus,green:<model>`: (i) the Opus test-author (`red:opus`) authors the full failing suite and makes a single commit with the literal `[split-role-red]` substring in the subject, then (ii) the implementer (`green:<model>`) greens it test-by-test, additive-only, AND completes ALL approved-plan tasks incl. non-test deliverables — locked-suite-green is necessary but not sufficient for plan completeness (greening the locked suite ≠ plan-complete), and runs the FULL local suite green before `gh pr create` — not just the locked `[split-role-red]` files (#1108). When `SPLIT_ROLE=false` / `ROLES=single`, dispatch the single execute Agent as usual.
     - **Relay `ELIGIBLE=`/`SCOPE=`/`REASON=` in the run log** as the advisory audit of *why* the model resolved as it did.

     The resolver is the **single place** the #1042/#881 knobs + carve-outs are applied — it folds the #1042 model knob (`PIPELINE_PATH_B_MODEL_EXECUTE` for PATH B, `PIPELINE_PATH_D_MODEL_EXECUTE` for PATH D) into one emitted spec, so config and prose can no longer drift. When the model knob is **unset or empty** the resolver defaults the effective value to `sonnet` (#1042 — Sonnet-on-execute is the shipped default; an operator opts OUT by setting `=opus`, honored verbatim). The resolver likewise resolves `PIPELINE_PATH_B_ELIGIBLE_SCOPE` — which, when **unset or empty, defaults to `all`** (opt-OUT `=low-blast`) — and `PIPELINE_PATH_B_SPLIT_ROLE`, which when **unset or empty defaults to `true`** (`PIPELINE_PATH_B_SPLIT_ROLE` default `true`; opt-OUT via `=false`, #1057) so a fresh install runs the split-role TDD lane unless the operator explicitly disables it. Since #1186 the resolver also resolves **PATH A** (`PIPELINE_PATH_A_MODEL_EXECUTE`) and **PATH C** (`PIPELINE_PATH_C_MODEL_EXECUTE`), each defaulting to `opus` when unset (`REASON=default-opus`) — those dispatches previously carried no `model=` at all — and the read-site rule is now unconditional: ALWAYS pass `model=$MODEL` (the resolver never emits `inherit`). It REUSES `scripts/path-b-execute-eligible.sh` + `scripts/_high-uncertainty-match.sh` for the carve-out machinery — never redefining the high-uncertainty regex (#1039).

     **Load-bearing carve-out summary (the resolver encodes these — do NOT re-derive them by hand).** Three carve-outs ALWAYS force Opus regardless of the knobs, and the resolver applies them so the read-site does not:
     - **W2 high-uncertainty → Opus.** A PATH B issue whose `path-b-execute-eligible.sh` REASON is `high-uncertainty`, or a PATH D issue matching `_high-uncertainty-match.sh`'s word-bound vocab (`concurrency`/`auth`/`lock`/`race`/`deadlock`/`security`/`crypto`/`migration`/`data-loss`), resolves `MODEL=opus`. Under the default `all` scope this carve-out is the **sole safety boundary** keeping genuinely risky PATH B work on Opus.
     - **PATH B eligibility gate (#955) — `low-blast` lane.** For **PATH B**, `path-b-execute-eligible.sh <N>`'s `ELIGIBLE=<low-blast|high-blast>` is a pre-execute classify/plan-time **estimate** (added-LOC is not known from a diff at dispatch — proxied from module/file bounds plus an optional `~N LOC` override). Under `SCOPE=low-blast`, a **high-blast** PATH B resolves `MODEL=opus` and the dispatch pins opus (`model=opus`) — #1186 named what the branch always meant instead of passing no `model=`; only a `low-blast` verdict routes the resolved model. Under the default `SCOPE=all`, every non-W2 PATH B routes the resolved model even on a `high-blast` verdict (the eligibility verdict is then advisory only, relayed in the run log).
     - **needs-browser PATH D → Opus (#960).** PATH D stays **unconditional** (all D is in-lane, no eligibility predicate) EXCEPT a `needs-browser` PATH D, which resolves `MODEL=opus` and pins opus (`model=opus`, #1186 — it no longer passes NO `model=`, which under a Fable-ceiling session would have upshifted browser/UI execute to Fable, the opposite of the #960 intent); the #950 Sonnet pilot validated shell-helper fixtures only, so browser/UI execute must not downshift. (For PATH B, needs-browser surfaces as `path-b-execute-eligible.sh` REASON `needs-browser` and is treated as a W2-equivalent Opus carve-out.)

     **W3 — pr-eval is NEVER defaulted to Sonnet.** This routing applies to the **execute** dispatch ONLY: the **pr-eval dispatch is NEVER gated** and is never defaulted to Sonnet — pr-eval is **pinned `opus`** in every configuration via `PIPELINE_STAGE_MODEL_PR_EVAL`, resolved by `scripts/resolve-stage-model.sh <N> pr-eval` (#1186). That pin replaces the old inheritance backstop, which only held while the session model happened to be Opus. The execute resolver has **no pr-eval mode** and rejects every argument that is not a path letter — stage words included (exit 2) — so it physically cannot emit a model for pr-eval (dropping the evaluator's tier would remove the regression catcher that makes a cheaper-execute default safe). The knobs are host-overridable (gitignored `pipeline.config`); the shipped default is Sonnet-on-execute (#1042) — an operator restores the conservative Opus tier by setting `=opus` / `=low-blast` (or commenting the knobs), which the resolver then honors.

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
