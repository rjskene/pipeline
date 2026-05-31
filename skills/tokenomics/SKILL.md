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
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
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
bash "${CLAUDE_PLUGIN_ROOT}/scripts/capture-agent-costs.sh" 2>"$ERRLOG"
# The HEADLESS pass skips runs whose Claude Code transcript is missing and
# counts them on stderr as headless_skipped_missing_transcript=N. Capture N —
# it feeds Step 2's coverage-health table so partial coverage is visible.
N="$(grep -oE 'headless_skipped_missing_transcript=[0-9]+' "$ERRLOG" | tail -1 | cut -d= -f2)"
N="${N:-0}"
echo "skipped (missing transcript): $N"
```

If `PIPELINE_LOGS_ENABLED` is not `true`, the script is a no-op and `N` will be `0` — note that the report will then show empty/`--` cells and say so in Step 3.

## Step 2 — Report

Render the full tokenomics report over the (now-refreshed) `agent-costs.jsonl`, passing the skipped count from Step 1 so coverage-health is accurate:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/cost-latency-report.sh" --tokenomics --skipped-count "$N"
```

Use `--limit N` to widen or narrow the window of most-recent merged PRs (default 50), e.g. `--limit 100`. The `--tokenomics` flag renders the bucket, per-stage-cost, structure, stage×structure crosstab, per-PATH size, breakeven, coverage-health, trend, latency, and concurrency tables. The report degrades gracefully (token/duration cells render `--`) when the capture log is absent or empty — it never errors.

## Step 3 — Present

The bash stdout is NOT surfaced to the user automatically. Relay **every** table from the report into the assistant reply, with a one-line read for each:

- **Bucket** — token-share vs cost-share per bucket (where the spend concentrates).
- **Per-stage cost** — classify / plan / plan-eval / execute / pr-eval cost breakdown.
- **Structure** — spawn (headless) vs in-session (inline) split.
- **Stage × structure crosstab** — which stages run headless vs inline.
- **Per-PATH / issue size** — size distribution across PATH A/B/C/D.
- **B→D breakeven** — the crossover where PATH B ceremony stops paying off vs PATH D quick-fix.
- **Coverage-health** — how complete the cost data is (fed by the Step 1 skipped count; flag if coverage is low).
- **Trend** — per-day and per-PR cost trend, with any outlier days called out.
- **Task-latency** — wall-clock per task/stage.
- **Concurrency assessment** — observed overlap and the concurrency ceiling.

**Surface the concurrency assessment prominently** as an analysis deliverable in its own right — not just as one more table. State the observed peak overlap and the ceiling, and whether the workload is approaching it.

If coverage-health shows a high skipped count, lead the summary with that caveat: the cost figures are a lower bound until those transcripts are present.

## Dogfood-only

This skill is **dogfood-only by convention**. It reads ONLY the `PIPELINE_LOGS_ENABLED`-gated `.claude/logs/agent-costs.jsonl`, invokes repo-local scripts via `${CLAUDE_PLUGIN_ROOT}/scripts/`, and writes **NOTHING** to the consumer's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` (see CLAUDE.md "Namespace discipline"). The `.claude/logs/` capture log is the only consumer-owned path touched, and only for reads — it is already on the runtime allow-list.

The name `tokenomics` was chosen over `analyze-usage` to avoid colliding with `/pipeline:run --analyze`.
