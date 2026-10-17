# Campaign mode — the leg-loop machinery

**Single source of truth for the campaign machinery.** `/pipeline:campaign` is an **equivalent standalone entry point** into the SAME loop and defers here (see `skills/campaign/SKILL.md`); `--campaign` on `/pipeline:fullsend` is **NOT deprecated**. Both run identical machinery.

`--campaign` is an **OUTER loop above the existing wave-by-wave steps** — it **does not replace** them. Each **LEG** is one full pass of Steps 1→8 over that leg's issues; `### Execute the slate WAVE BY WAVE` (with the inter-wave base refresh and scoped halt) runs unchanged inside each leg.

**Global-budget rule (ALL stages).** Every dispatch — **plan (classify inline) and plan-eval INCLUDED** — is **batched under the caps**. **NO flat parallel blast of the whole set, even for read-only stages**: the rate-limit budget is GLOBAL.

**Campaign flow:**

(a) **Plan the ENTIRE set, BATCHED under a FLAT cap** — classify runs inside each plan agent, so per-path caps are unknown until the batch returns.

(b) **Eval-plan the ENTIRE set, BATCHED, and APPROVE ALL up front.** No per-leg re-plan: staleness is absorbed by the execute rebase and the `evaluate-issue-pr` gate.

(c) **Partition into legs:**

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh <approved-set>
```

It honors `PIPELINE_CAMPAIGN_MAX_BC` (B/C-pool per-leg cap) and `PIPELINE_CAMPAIGN_MAX_AD` (A/D-pool per-leg cap); a user instruction overrides them via `--max-bc=N` / `--max-ad=N`. Parse `Leg <K>: #a, #b, ... (BC=<n> AD=<m>)` lines; legs run **in order**.

(d) **For each leg IN ORDER:**

1. Run the **execute → 6b → eval-pr → greenlight-merge** machinery (Steps 5–7 wave-by-wave) on this leg's issues. Snapshot `BASE0=$(git -C "$MAIN_REPO" rev-parse "$PIPELINE_BASE_BRANCH")` first.
2. **Base advance** — fetch-only: `git -C "$MAIN_REPO" fetch --quiet origin "$PIPELINE_BASE_BRANCH"`, so the next leg's worktrees (Step 5's explicit `--base`) inherit this leg's merged work. The primary checkout is NEVER checked out or pulled.
2a. **Leg-boundary base-ref drift guard:**
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-ref-drift.sh" "$PIPELINE_BASE_BRANCH" "$BASE0" <leg-feature-branches...>
   ```
   `BASE=ok`/`BASE=recovered` → continue; `BASE=drift-unsafe ORPHANS=<shas>` → **halt the campaign** and report the shas; `BASE=error REASON=<...>` → advisory, do NOT halt. The guard is HEAD-aware, so no checkout precondition.
3. **Usage read-out** (dogfood-only, READ-ONLY advisory; **NO automated hold / queue / pacing**):
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-surface.sh" || true
   ```
   Then run the **usage gate** per `## Usage gate` — unlike the read-out it DOES pause (`pause-5h`) or halt (`halt-7d`) between legs.
4. **Collect this leg's bug signals** (NO `gh issue create` per leg): eval-pr `block-*` flags, Step-6b CI-fix repairs, execute `FAILED`/off-plan reports, skipped/halted-closure issues — one `SIGNAL issue=#<N> kind=<...> title="<conventional-commit title>" detail="<short>"` record each. **Per-leg race guard:** dedup against currently-open issues and the running campaign-filed set. Filing is deferred to **End-of-campaign bug filing**.
5. Proceed to the next leg.

**End-of-campaign fold wave.** AFTER the last leg, BEFORE **End-of-campaign bug filing**, run ONE bounded fold wave over this campaign's signals:

1. **Select up to `PIPELINE_CAMPAIGN_MAX_FOLD` (default 3) signals, FIFO:**
   ```bash
   printf '%s\n' "${CAMPAIGN_SIGNALS[@]}" | PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_CAMPAIGN_MAX_FOLD="${PIPELINE_CAMPAIGN_MAX_FOLD:-3}" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh fold-select
   ```
   It emits `FOLD issue=#<N> title="..."`, `SKIP issue=#<N> reason=high-uncertainty title="..."` (high-uncertainty title keyword, word-bound regex from `scripts/_high-uncertainty-match.sh`; budget not consumed) and `OVERFLOW issue=#<N> title="..."` (beyond ceiling).
2. **Classify-clean skip (semantic judgment, NOT mechanized):** skip non-autonomous signals — any `FOLD` that would classify `human` / `brainstorm` / `excluded` is demoted to leave-posted like `SKIP`/`OVERFLOW`.
3. **File the surviving FOLD signals FIRST** (the waves need issue numbers) with the template below, re-checking dedup before create; add each to the campaign-filed set and remove it from `CAMPAIGN_SIGNALS`.
4. **Run ONE wave** over those issues — plan → eval-plan → execute → eval-PR → auto-merge, respecting `--manual-merge`. Conflicts are handled at merge, not pre-filtered.
5. **Bound — one wave, NO recursion.** New signals from the fold wave just post below; never folded again.

**Overflow + SKIP signals stay posted.** `OVERFLOW`/`SKIP`/demoted signals stay in `CAMPAIGN_SIGNALS` and are filed for the next campaign; nothing is dropped.

**End-of-campaign bug filing.** At campaign completion, a **SINGLE serialized orchestrator action** runs the **deterministic, NON-INTERACTIVE subset** of create-issues — the combine-bias scope-check, grouping detection, the standard body template and the path-hint marker. It never runs the interactive refinement dialogue nor the full `/pipeline:create-issues` skill (campaign completion is autonomous).

1. **Aggregate + dedup** across legs (two-layer dedup: per-leg AND here):
   ```bash
   printf '%s\n' "${CAMPAIGN_SIGNALS[@]}" | PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh aggregate-signals --open="<open-issue-csv>" --filed="<campaign-filed-csv>"
   ```
   Each `CANDIDATE scope=<scope> issues=#a,#b title="<derived title>" kinds=<csv>` line is one proposed issue.
2. **Combine-bias scope-check** (`skills/create-issues/SKILL.md` step 3): default toward FEWER issues; split only on independent surfaces.
3. **Grouping detection** (opt-out `PIPELINE_GROUPING_DETECTION_ENABLED=false`):
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/find-grouping-candidates.sh" --title "<candidate-title-1>" --title "<candidate-title-2>"
   ```
4. **File each surviving issue.** Write the body to a temp file using the standard template, adding the advisory `<!-- pipeline:path-hint=A|B|C -->` marker when a clear signal exists:
   ```
   ## Context
   <1-3 sentences: which leg/stage surfaced this and the failure shape>

   ## Scope
   - <what this issue covers>

   ## Affected areas
   - <file paths or system areas likely involved>

   ## Notes
   - <constraints / dependencies surfaced during the campaign>
   <!-- pipeline:path-hint=B -->
   ```
   ```bash
   gh issue create --repo "$PIPELINE_REPO" --title "<title>" --body-file "<body-file>"
   ```
   Re-check the open-issue + campaign-filed sets right before each create, then add the number to the campaign-filed set.

**Scoped halt (campaign-level mirror of `### Scoped halt-and-report`).** On a hard fail or hard block, drop its **dependency CLOSURE** from the REMAINING legs:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-campaign.sh closure <blocked-N> <remaining-set>
```

The closure walks the `--emit-edges` map to a fixpoint. **Independent later legs NOT in the closure still proceed.** Failed issues and skipped dependents are reported at campaign end. Transient blocks (`block-ci` / `pending`) defer to the Step-6b CI-fix loop and become hard blocks only once the retry budget exhausts.

**Self-mutation callout.** Same as `### Self-mutation callout`: work happens in an isolated worktree.
