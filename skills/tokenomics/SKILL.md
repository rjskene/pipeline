---
name: tokenomics
description: Dogfood-only usage analysis — backfill agent token costs then render the per-bucket/stage/structure cost+latency report with B→D breakeven, coverage-health, trend, and concurrency assessment over the gated agent-costs log. Usage: /pipeline:tokenomics
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables (notably `PIPELINE_LOGS_ENABLED` and `PIPELINE_REPO`) are available, then self-resolve `CLAUDE_PLUGIN_ROOT` in case the env var is unset in this Bash subshell:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor the resolver via the plugin cache glob (a stable, var-independent path —
# the same anchor the resolver body / doctor.sh / migrate-from-subtree.sh use) so the
# snippet is NOT chicken-and-egg: it does not need CLAUDE_PLUGIN_ROOT pre-set to FIND
# the resolver. _cpr_dir is the DIRECTORY prefix only; the `source` line keeps the
# literal `_resolve-plugin-root.sh` (no space after `source`) so the source-resolver
# contract regex still matches. When CLAUDE_PLUGIN_ROOT is already set, prefer it.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

If `CLAUDE_PLUGIN_ROOT` fails to resolve, **STOP** — the backfill and report scripts live under it.

# Tokenomics

```
backfill (capture-agent-costs.sh) → report (cost-latency-report.sh --tokenomics) → present every table + concurrency assessment
```

This is a two-script pipeline: a retroactive backfill that refreshes the gated cost log, then the tokenomics report that joins it against merged PRs. The scripts print to stdout/stderr but their output is **not** user-visible on its own — you MUST relay every table into the assistant reply (Step 3).

## Step 1 — Backfill

Run the retroactive HEADLESS + INLINE backfill. It is idempotent by `record_key` (append-only, last-write-wins) and is a no-op unless `PIPELINE_LOGS_ENABLED=true`:

```bash
ERRLOG="$(mktemp)"
CAPTURE_OUT="$(PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" CLAUDE_PROJECT_DIR="$(pwd)" bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture-agent-costs.sh" 2>"$ERRLOG")"
printf '%s\n' "$CAPTURE_OUT"
# The HEADLESS pass skips runs whose Claude Code transcript is missing and
# counts them on stderr as headless_skipped_missing_transcript=N (captured to
# "$ERRLOG" for debugging only; no longer threaded into the report).
```

**Detect a gated skip.** If `$CAPTURE_OUT` contains `SKIP_LOGGING_DISABLED`, the backfill did NOT run. Because the invocation explicitly passes `PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED"`, the marker's echoed value tells you which case applies:

- marker shows `PIPELINE_LOGS_ENABLED='false'` (or `<unset>`) → **intentional opt-out**: the report will show empty/`--` cells; say so plainly in Step 3.
- marker shows `PIPELINE_LOGS_ENABLED='true'` → **contradiction / propagation bug**: the gate fired despite the skill passing `true`. STOP and report the propagation failure rather than rendering a misleadingly stale report.
- if `$PIPELINE_LOGS_ENABLED` was itself empty in the skill shell, `pipeline.config` did not source correctly — re-check the Boot block before proceeding.

## Step 2 — Report

Render the full tokenomics report over the (now-refreshed) `agent-costs.jsonl`:

```bash
PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" CLAUDE_PROJECT_DIR="$(pwd)" bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-latency-report.sh" --tokenomics
```

Use `--limit N` to widen or narrow the window of most-recent merged PRs (default 50), e.g. `--limit 100`. The `--tokenomics` flag renders the bucket, per-stage-cost, structure, stage×structure crosstab, per-PATH size, breakeven, coverage-health, trend, latency, and concurrency tables. User-facing duration columns (per-PATH/per-stage `median dur`, top-slowest-stages, headless durations, task-latency) render in MINUTES; the per-stage / per-structure / per-PATH tables also carry per-N token-bucket columns (input / output / cache_creation / cache_read) sourced from all records so unpriced inline rows still show real token counts. Internal `--emit-rows-json` and the metrics-snapshot consumer stay in raw ms. The report degrades gracefully (token/duration cells render `--`) when the capture log is absent or empty — it never errors.

## Step 3 — Present

The bash stdout is NOT surfaced to the user automatically. Relay **every** table from the report into the assistant reply, with a one-line read for each:

- **Bucket** — token-share vs cost-share per bucket (where the spend concentrates).
- **Per-stage cost** — classify / plan / plan-eval / execute / pr-eval cost breakdown.
- **Structure** — spawn (headless) vs in-session (inline) split. The per-N token-bucket columns (input / output / cache_creation / cache_read) are sourced from ALL records, so an unpriced in-session (inline) row shows REAL token counts; the `$` column stays priced-only (a rate is required for `$`) and renders `--` with an `(unpriced)` mark when all of a structure's records are unpriced, so a zero-cost row is never misread as zero-token.
- **Stage × structure crosstab** — which stages run headless vs inline.
- **Per-PATH / issue size** — size distribution across PATH A/B/C/D.
- **B→D breakeven** — the crossover where PATH B ceremony stops paying off vs PATH D quick-fix.
- **Coverage-health** — how complete the cost data is. Model-attribution coverage % is one completeness signal (flag if it is low). Inline costs are transcript-summed cumulative (`usage_complete=true`) after the Step-1 backfill resolves each subagent transcript; the **lower-bound (unreconciled) records** count names how many records are still forward/sidecar lower bounds (transcript missing or pruned at backfill time) — those totals read as a LOWER BOUND, not the real cost, so re-run the backfill to reconcile them once the transcript exists.
- **Trend** — per-day and per-PR cost trend, with any outlier days called out.
- **Task-latency** — wall-clock per task, split into two labelled rows: `spawn` (the headless `duration_ms`, which is session-lifetime, NOT task-latency) and `inline` (the true in-session task-latency). Durations render in MINUTES. The inline row's median is sourced from ALL records (not the priced-only substrate), so a live unpriced inline (`model=""`) shows its real task-latency rather than being gated out to `--`.
- **Concurrency assessment** — observed overlap and the concurrency ceiling. The headless interval peak is a LOWER BOUND that EXCLUDES inline overlap: inline agents are point-in-time (`ts_start==ts_end`) under the current capture shape and are not interval-measurable, so they are COUNTED (the inline-records count is surfaced) and annotated rather than swept into the peak.

**Surface the concurrency assessment prominently** as an analysis deliverable in its own right — not just as one more table. State the observed peak overlap and the ceiling, and whether the workload is approaching it.

If coverage-health shows low model-attribution coverage OR a non-zero lower-bound (unreconciled) record count, lead the summary with that caveat: the cost figures are a lower bound — until those records carry a model (model-attribution) and until each inline record's subagent transcript is resolved and transcript-summed (the unreconciled count). Re-running the Step-1 backfill reconciles the unreconciled lower bounds upward once their transcripts exist.

## Dogfood-only

This skill is **dogfood-only by convention**. It reads ONLY the `PIPELINE_LOGS_ENABLED`-gated `.claude/logs/agent-costs.jsonl`, invokes repo-local scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/`, and writes **NOTHING** to the consumer's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` (see CLAUDE.md "Namespace discipline"). The `.claude/logs/` capture log is the only consumer-owned path touched, and only for reads — it is already on the runtime allow-list.

The name `tokenomics` was chosen over `analyze-usage` to avoid colliding with `/pipeline:run --analyze`.
