# Campaign mode — the leg-loop machinery

**This section is the single source of truth for the campaign machinery.** `/pipeline:campaign` is an **equivalent standalone entry point** into the SAME loop documented here — it owns no leg-loop prose of its own and defers to this section verbatim (see `skills/campaign/SKILL.md`). `--campaign` on `/pipeline:fullsend` remains supported on an ongoing basis and is **NOT deprecated**; the two entries are interchangeable and execute identical machinery, so they can never drift.

`--campaign` is an **OUTER loop above the existing wave-by-wave steps** — it **does not replace** them. Each **LEG** is one full pass of Steps 1→8 over that leg's issues; the wave-by-wave `### Execute the slate WAVE BY WAVE` machinery (Steps 5–7, the `### Inter-wave base refresh`, the `### Scoped halt-and-report`) runs unchanged *inside* each leg. Campaign mode WRAPS that pass and sequences multiple legs so the global rate-limit budget is spent in bounded batches rather than a single flat blast of the entire set.

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
2. **Base advance** — perform a fetch-only base refresh: a single `git -C "$MAIN_REPO" fetch --quiet origin "$PIPELINE_BASE_BRANCH"` so the next leg's worktrees (via Step 5's always-explicit `--base "$PIPELINE_BASE_BRANCH"`) are cut from `origin/<base>`'s tip and inherit this leg's merged work (same #626 reason as the `### Inter-wave base refresh`). This is one atomic command: it moves no local ref, no HEAD, and writes nothing to the working tree — the orchestrator's primary checkout is NEVER checked out or pulled (#1214).
2a. **Leg-boundary base-ref drift guard (#1106 — Layer 2).** After the base advance and beside the usage gate below, snapshot `BASE0` before this leg's dispatch (at the START of step 1 above, `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")`), then call the guard with the leg's feature branches:
   ```bash
   # Required env: BASE0 (base-tip sha snapshotted before this leg's dispatch, step 1).
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-ref-drift.sh" \
     "$PIPELINE_BASE_BRANCH" "$BASE0" <leg-feature-branches...>
   ```
   Act on the token identically to the Step 6a post-batch guard: `BASE=ok`/`BASE=recovered` → continue to next leg; `BASE=drift-unsafe ORPHANS=<shas>` → **halt the campaign** and report the orphan shas for manual recovery; `BASE=error REASON=<...>` → relay advisory, do NOT halt (fail-open). No checkout precondition — the guard is HEAD-aware (#1214) and self-selects `branch -f` vs `reset --hard` based on where HEAD is, so it is safe to call regardless of what branch the primary checkout happens to be standing on.
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
   # Required env: CAMPAIGN_SIGNALS (bash array of this campaign's collected signal lines).
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

**End-of-campaign bug filing.** AFTER the last leg's `(e)` step completes (campaign completion), a **SINGLE serialized orchestrator action** routes the aggregated signal log through the **deterministic, NON-INTERACTIVE subset** of the create-issues flow — the combine-bias scope-check heuristic + the grouping-detection script + the standard issue-body template + the advisory path-hint marker. It **NEVER runs the interactive create-issues refinement dialogue** (no one-question-at-a-time loop) and does **NOT** call the full `/pipeline:create-issues` skill — it calls the three deterministic helpers directly, because campaign completion is autonomous (the #863 autonomy constraint). Steps:

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
