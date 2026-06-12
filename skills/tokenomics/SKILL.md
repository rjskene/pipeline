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
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
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

Use `--limit N` to widen or narrow the window of most-recent merged PRs (default 50), e.g. `--limit 100`. The `--tokenomics` flag renders the bucket, per-stage-cost, structure, stage×structure crosstab, per-PATH size, breakeven, coverage-health, trend, latency, and concurrency tables. User-facing duration columns (per-PATH/per-stage `median dur`, top-slowest-stages, headless durations, task-latency) render in MINUTES; the per-stage / per-structure / per-PATH tables also carry per-N token-bucket columns (input / output / cache_creation / cache_read) sourced from the **reconciled substrate** (so unpriced inline rows still show real token counts, but explicit `usage_complete=false` lower-bounds are excluded). Internal `--emit-rows-json` and the metrics-snapshot consumer stay in raw ms. The report degrades gracefully (token/duration cells render `--`) when the capture log is absent or empty — it never errors.

The cost/token magnitude tables aggregate the **reconciled substrate** — complete records only, i.e. `usage_complete != false` (keeps `true` AND records with no `usage_complete` field for fixture/legacy compat; drops only explicit lower-bounds). This is NOT a `source=="retroactive"` filter. Coverage-health stays on the full deduped stream (see Step 3). `--since DATE` further restricts the cost/token tables to records whose `ts_start` date (`YYYY-MM-DD`) is on/after DATE — the reconcilable era (≥ `2026-05-31`); records with an empty/absent `ts_start` are excluded under `--since`. `--until DATE` is the inclusive upper-bound mirror of `--since` (records whose `ts_start` date is on/before DATE; empty/absent `ts_start` excluded) — it composes with `--since` to form a closed window, e.g. `--since=D --until=D` isolates a single calendar day. `--per-day` walks the `[--since, --until]` window day-by-day (default: the last 5 days ending today, UTC), emitting one full report per day under a `=== DAY YYYY-MM-DD ===` block by re-invoking the script with `--since=D --until=D` (so each day reuses the same pricing + PR-join, no drift); it honors `--tokenomics` / `--limit` / `--fixture` / `--capture-log`.

## Step 3 — Present

The bash stdout is NOT surfaced to the user automatically. Relay **every** table from the report into the assistant reply, with a one-line read for each:

- **Bucket** — token-share vs cost-share per bucket (where the spend concentrates), plus normalized **tok/N**, **$/N** (÷ reconciled-substrate record count), **tok/LOC**, **$/LOC** (÷ total merged-PR LOC across the window) columns. N and LOC divisors render `--` when zero (no divide-by-zero).
- **Per-stage cost** — classify / plan / plan-eval / execute / pr-eval cost breakdown.
- **Structure** — spawn (headless) vs in-session (inline) split. The per-N token-bucket columns (input / output / cache_creation / cache_read) are sourced from the reconciled substrate (`usage_complete != false`), so an unpriced in-session (inline) row shows REAL token counts while explicit lower-bounds are excluded; the `$` column stays priced-only (a rate is required for `$`) and renders `--` with an `(unpriced)` mark when all of a structure's records are unpriced, so a zero-cost row is never misread as zero-token.
- **Stage × structure crosstab** — which stages run headless vs inline.
- **Per-PATH / issue size** — size distribution across PATH A/B/C/D.
- **B→D breakeven** — the crossover where PATH B ceremony stops paying off vs PATH D quick-fix.
- **Coverage-health** — how complete the cost data is. Computed over the FULL deduped stream (not the reconciled substrate), so its counts are the true totals. Model-attribution coverage % is one completeness signal (flag if it is low). Inline costs are transcript-summed cumulative (`usage_complete=true`) after the Step-1 backfill resolves each subagent transcript; the **lower-bound (unreconciled) records** count names how many records are still forward/sidecar lower bounds (transcript missing or pruned at backfill time) — those totals read as a LOWER BOUND, not the real cost, so re-run the backfill to reconcile them once the transcript exists. A separate **excluded from cost tables** line names how many `usage_complete=false` lower-bounds were dropped from the cost/token magnitude tables by the reconciled-substrate scoping, so the exclusion is disclosed (no silent drops).
- **Trend** — per-day and per-PR cost trend, with any outlier days called out.
- **Task-latency** — wall-clock per task, split into two labelled rows: `spawn` (the headless `duration_ms`, which is session-lifetime, NOT task-latency) and `inline` (the true in-session task-latency). Durations render in MINUTES. The inline row's median is sourced from ALL records (not the priced-only substrate), so a live unpriced inline (`model=""`) shows its real task-latency rather than being gated out to `--`.
- **Concurrency assessment** — observed overlap and the concurrency ceiling. The headless interval peak is a LOWER BOUND that EXCLUDES inline overlap: inline agents are point-in-time (`ts_start==ts_end`) under the current capture shape and are not interval-measurable, so they are COUNTED (the inline-records count is surfaced) and annotated rather than swept into the peak.

**Surface the concurrency assessment prominently** as an analysis deliverable in its own right — not just as one more table. State the observed peak overlap and the ceiling, and whether the workload is approaching it.

If coverage-health shows low model-attribution coverage OR a non-zero lower-bound (unreconciled) record count, lead the summary with that caveat: the cost figures are a lower bound — until those records carry a model (model-attribution) and until each inline record's subagent transcript is resolved and transcript-summed (the unreconciled count). Re-running the Step-1 backfill reconciles the unreconciled lower bounds upward once their transcripts exist.

### Preferred presentation (operator base case)

Operator-validated reply shape (2026-06-11 session, confirmed verbatim as the base case). Unless the user asks otherwise, present the report in exactly this order:

1. **Caveat lead** (when triggered by the rule above) — one bold sentence stating the figures are a lower bound, with the unreconciled count/%, model-attribution %, and any permanently-pruned transcript count. State the window (`--since`/`--until`) here too.
2. **Headline block** — 1–2 sentences: total captured spend, the dominant cost bucket, the biggest stage share, and the B→D savings total. The TLDR a skim-reader needs.
3. **Every table verbatim** in its own fenced code block, each preceded by a `**Table name**` + em-dash one-line READ — the takeaway (e.g., "cache dominates: 91% of tokens"), never a prose restatement of the rows. Order: bucket → per-stage cost → structure → stage×structure → per-PATH → per-stage medians → top consumers/slowest (may share one block) → B→D breakeven → coverage-health → trend per-day → trend per-PR → task-latency.
4. **Row trimming is allowed ONLY with disclosure** — zero-savings/all-`--` rows may be dropped from a fenced table when a parenthetical names exactly what was omitted (e.g., "(zero-savings rows omitted: #918, #923)"). Never trim silently; never trim coverage-health or trend tables.
5. **Concurrency assessment as a prose deliverable** — its own labelled paragraph (not a fenced table): observed peak, why it is a lower bound (inline point-in-time records), the ceiling that would bind, and — when the metric is blind (all-inline week) — what the operator actually felt as the binding constraint plus what capture change would make the metric real.
6. **Closing "Reads"** — 2–4 bullets tying the numbers to repo decisions (routing calibration, orchestrator overhead, cache economics), each anchored to an issue/doc where one exists.

### Step 4 — Persist the analysis (dogfood, ongoing updates doc)

After presenting, save the same entry (identical shape, including a **model-mix table** — the jq snippet lives in [docs/tokenomics/README.md](../../docs/tokenomics/README.md)) as an INDIVIDUAL timestamped doc `docs/tokenomics/YYYY-MM-DD-window-<since>-to-<until>.md` (date = analysis date, title `# Tokenomics update — YYYY-MM-DD (window <since> → <until>)`), and commit it to the base branch as `docs(tokenomics): add YYYY-MM-DD update`. One doc per analysis — do NOT append to a rolling file. This is the human-readable analysis layer; the machine layer stays `snapshot-tokenomics-history.sh` (below). Skip when the report was empty/gated-off.

## Persisted history (#832)

The live `agent-costs.jsonl` is subject to transcript/log pruning — once a raw transcript is gone, the backfill can no longer reconcile that day. `scripts/snapshot-tokenomics-history.sh` rolls up a durable **per-day aggregate** that survives raw-log pruning, so the seed-doc shape is reproducible after the underlying records are gone. It is the live successor to the hand-computed seed in `docs/tokenomics-history-2026-05-29-to-06-02.md`.

- **Snapshot step** — gated (`PIPELINE_LOGS_ENABLED=true`); a gated-off run prints `SKIP_LOGGING_DISABLED` and exits 0 (same skip-detection as Step 1):

  ```bash
  PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" CLAUDE_PROJECT_DIR="$(pwd)" bash "${CLAUDE_PLUGIN_ROOT}/scripts/snapshot-tokenomics-history.sh"
  ```

  It invokes `cost-latency-report.sh --emit-day-json` (one aggregation path — same dedup / reconcile / pricing / LOC-join substrate) and **upserts** each day object into `.claude/logs/tokenomics-history.jsonl`, keyed by `date` (last-write-wins). Re-running a day overwrites its row, so as lower-bounds reconcile upward (`usage_complete` flips, totals grow) the stored row grows monotonically; the `usage_complete_floor` field records whether a day is still a floor. Passthrough flags (`--since` / `--until` / `--limit` / `--capture-log` / `--fixture`) forward verbatim to the report. The store resolves to the MAIN worktree (like `capture-agent-costs.sh`), so a run from a linked worktree still lands in the durable store.

- **`--emit-day-json`** (machine mode on the report) — emits one compact JSON object per day over the resolved `[--since,--until]` window, sorted ascending by date. Schema: `{date, n, tokens{input,output,cache_creation,cache_read,total}, per_n{...}, active_loc, per_loc{...|null}, priced_n, cost{...}, cost_per_n, cost_per_loc, usage_complete_floor}`. `n` counts ALL records (priced + unpriced); `priced_n` excludes `model==""`. The **per-LOC figures are directional, not additive** across days (the same issue's LOC can recur under multiple days) — `per_loc` / `cost_per_loc` are `null` for days with no merged-PR LOC join.

- **`--history [PATH]`** (render mode on the report) — renders a table from the persisted store instead of the live log, for use after the live log is pruned. Reads ONLY the store (no PR join, no `gh`); an absent/empty store prints an empty-history notice and exits 0. With no `PATH`, defaults to the resolved `.claude/logs/tokenomics-history.jsonl`. `null` per-LOC cells render `--`.

  ```bash
  PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" CLAUDE_PROJECT_DIR="$(pwd)" bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-latency-report.sh" --history
  ```

- **Cadence (operator-applied)** — recommended to run the snapshot on the operator's host (cron) **more frequently than transcript/log retention**, so a day is captured before its raw records are pruned. Per CLAUDE.md "Configuration conventions" the live `pipeline.config`/crontab is host-specific and hand-patched; this script ships the logic, the operator wires the crontab line locally (same pattern as the `capture-agent-costs.sh` cron). No tracked-file footprint for the cron itself.

## Dogfood-only

This skill is **dogfood-only by convention**. It reads ONLY the `PIPELINE_LOGS_ENABLED`-gated `.claude/logs/agent-costs.jsonl`, invokes repo-local scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/`, and writes **NOTHING** to the consumer's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` (see CLAUDE.md "Namespace discipline"). The `.claude/logs/` capture log is the only consumer-owned path touched, and only for reads — it is already on the runtime allow-list.

The name `tokenomics` was chosen over `analyze-usage` to avoid colliding with `/pipeline:status --analyze`.
