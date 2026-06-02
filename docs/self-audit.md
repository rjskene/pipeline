# Self-improvement loop (dogfood-only)

This repo dogfoods a **repo-only audit system** that observes pipeline behavior to surface improvement candidates. The audit is **not part of the plugin** — nothing in `.claude-plugin/` references it, no consumer sees it.

## Trigger

This repo's `.claude/settings.json` registers a `UserPromptSubmit` hook that runs `dev/hooks/audit-on-pipeline-run.sh`. When the submitted prompt starts with `/pipeline:status` (or its deprecated alias `/pipeline:run`), the hook backgrounds `dev/self-audit/inner-loop.sh` and returns in <200ms. The user's prompt is not blocked.

## Inner loop

`dev/self-audit/inner-loop.sh` reads `dev/audits/index.jsonl` for the last audit timestamp, queries `gh` for merged feature/* PRs since then, reads observability logs (`.claude/logs/subagents/*.json`, `.claude/logs/tool-use*.log`, `.claude/logs/runs.log`) plus the orchestrator transcript at `${AUDIT_CLAUDE_PROJECTS_DIR:-~/.claude/projects}/<project-hash>/<session-uuid>.jsonl`, and emits `dev/audits/inner-<ISO>.md`.

Every digest contains five sections: **Compliance**, **Interaction**, **Pattern → defaults** (per-run noise), **Efficiency**, and **Data quality** (which inputs were present/missing — blind spots are a first-class finding). The Interaction section ships as a `_pending subagent classification — session <uuid>_` placeholder. As of the startup-prompt strip (#317) the placeholder is no longer filled in by `/pipeline:status`; a dogfood-only follow-up will move dispatch into `inner-loop.sh` itself via `claude -p` (filed separately as a `brainstorm` issue). After every third new entry, the inner loop backgrounds `outer-loop.sh`.

## Outer loop

`dev/self-audit/outer-loop.sh` reads the last 3 inner entries from `index.jsonl` and surfaces signals consistent across ALL of them.

**Cross-run pattern detection on `Suggested default` strings:** when ≥2 of 3 runs in the window emit the same `Suggested default` (exact-string match in MVP; Jaccard ≥0.7 is the upgrade path), the outer digest names that string as a **codification candidate**. For each pattern, it names a **codification target** on a plugin surface: skill prose, `pipeline.config.example`, hooks, or scripts. **Never local-machine personal state** — that does not propagate. The outer loop is read-only: it files no issues, modifies no surfaces. A human reads the digest and files the issue when ready.

## Four lenses (MVP — interaction lens is the only one with real heuristics)

1. **Compliance** — TODO stub (TDD pattern, wave-prio, PATH-tier dispatch, hook trip counts). Deferred until interaction lens proves its 10-run success criterion (#135 / #136).
2. **Interaction** — IMPLEMENTED (subagent-classified correction events with the three-field contract above). Other interaction signals (turn count, unnecessary confirmations) remain TODO; they can be added without re-architecting.
3. **Pattern → defaults** — IMPLEMENTED in outer-loop's 2-of-3 cross-run detector on Suggested-default strings.
4. **Efficiency** — TODO stub (tokens, wall clock, re-plan loops, eval-Revise verdicts).

## Redaction discipline (load-bearing)

Every transcript quote passes through `dev/self-audit/redact.sh::redact()`, which hard-denies token-shaped strings (regex `[A-Za-z0-9]{32,}`), the case-insensitive keywords `password|token|secret|api[_-]?key|bearer|Authorization`, and URLs containing `?key=|?token=|?auth=`; caps line length at 200 chars with a `...[truncated; original N chars]` suffix; and strips triple-backtick code-block contents entirely (only surrounding prose survives). Verified by `dev/tests/test-redaction.sh`.

## Output location

All digests and `index.jsonl` live in `dev/audits/`, which is gitignored — digests may contain redacted excerpts and stay on-disk locally only.

## Plugin manifest is untouched

`dev/`, `.claude/settings.json`, and the allow-list entry in `tests/no-consumer-claude-writes.allow` are the only surfaces this system writes to in this repo. `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/`, `scripts/`, `hooks/`, `agents/` are not modified by this system.

## Internal-path dependency

The orchestrator transcript path `~/.claude/projects/<project-hash>/<session-uuid>.jsonl` is a Claude Code internal. If Anthropic changes it, set `AUDIT_CLAUDE_PROJECTS_DIR` in the environment to point at the new location.

## Late-error report

`scripts/late-error-report.sh` walks recent merged feature PRs (release PRs filtered out by the shared `RELEASE_PR_JQ` rule) and categorizes each `## Evaluation` "Changes Requested" finding by the earliest stage at which it was detectable — `issue` (issue body), `plan` (`## Implementation Plan` comment), `plan-eval` (`## Plan Evaluation` comment), or `pr-eval` (only surfaceable from the PR diff). Output is a per-PATH summary table with N findings + per-stage counts + late-detectable rate, plus a TOP-5 outlier list of PRs with the highest per-PR late rate. v0 categorization is a literal substring match against explicit `[stage: ...]` markers; unmarked findings default to `pr-eval`. Run live with `bash scripts/late-error-report.sh` (requires `PIPELINE_REPO`), or against fixtures via `--fixture tests/fixtures/late-error-report/` from the test suite. The script is dogfood-only — not shipped in the plugin manifest, no `.claude/` writes. Companion of `scripts/over-eval-report.sh`; feeds the eventual `metrics-snapshot.sh` consumer referenced by #421 / #450.

## Daily metrics time-series

`scripts/metrics-snapshot.sh` aggregates four dogfood signals into a single JSONL row per run and appends to `.claude/logs/metrics-timeseries.jsonl`. Append-only; the row schema is sticky once written. Dogfood-only — **consumers do not run this**, and no `.github/workflows/` file is added.

Row schema (locked, see issue #576 plan):

| Field | Type | Aggregation |
|-------|------|-------------|
| `date` | `YYYY-MM-DD` (UTC) | `date -u +%Y-%m-%d` |
| `pipeline_version` | string | `PIPELINE_VERSION` from `pipeline.config`, else `"unknown"` |
| `over_eval_count` | int (or `null`) | Count of PRs in the 50-PR window with `pr_eval / max(loc,1) > 0.5`. Source: `over-eval-report.sh --emit-rows-json` |
| `late_error_count_by_stage` | object (or `null`) | Findings per `.stage`; the four canonical keys `issue`/`plan`/`plan-eval`/`pr-eval` always present (zeros included) so #420's diary can parse by name. Source: `late-error-report.sh --emit-rows-json` |
| `compliance_pass_rate` | float in `[0,1]` (or `null`) | STRICT test-first rate: `PASS / (PASS + WEAK + SKIP)` — excludes `N/A` and `omitted` from the denominator. `null` when denom is 0. Source: `compliance-backfill.sh --emit-rows-json` |
| `compliance_weak_count` | int (or `null`) | v2 addition (#640): count of `WEAK` verdicts (test present but committed AFTER source — test-after). Additive schema bump; historical rows lacking the key are read as `null`. Source: `compliance-backfill.sh --emit-rows-json` |
| `review_deviations_count` | int (or `null`) | `wc -l` of `review-audits.sh --deviations --since <yesterday-UTC>` output |

A sibling failure degrades that field to `null` rather than aborting the snapshot — partial-day signal beats no-day signal. The snapshot exit code stays 0 when any sibling degrades.

Host-cron registration (operator runs once during setup):

```
bash scripts/install-metrics-cron.sh
```

prints a ready-to-paste crontab line that runs the snapshot daily at 07:00 local and tees output to `.claude/logs/metrics-snapshot.cron.log`. The script does not mutate the live crontab; the operator pastes the line into `crontab -e`. Per the `feedback_dogfood_instrumentation_no_consumer_crud` rule, this stays host-local — putting it in `.github/workflows/` would compute metrics in every consumer's repo against their PRs, which is the wrong scope.

The longitudinal artifact lets #420's diary distinguish trending vs. stale metrics. Sister scripts: `over-eval-report.sh` (#421), `late-error-report.sh` (#574), `compliance-backfill.sh` (#575). Tracker: #450.

## Cost/latency report — `/pipeline:tokenomics`

`scripts/cost-latency-report.sh` (#643) is the Efficiency-lens cost/latency report: it joins `.claude/logs/agent-costs.jsonl` (produced by `scripts/capture-agent-costs.sh`, #642) with merged feature PRs to surface tokens/$/latency by issue, stage, PATH, and session-structure. The **`/pipeline:tokenomics`** skill (#721, dogfood-only) is the operator entrypoint: Step 1 backfills via `capture-agent-costs.sh`, Step 2 runs `cost-latency-report.sh --tokenomics`, Step 3 presents every table in the assistant reply (per-bucket token-share vs cost-share, per-stage cost, structure + stage×structure cross-tab, B→D breakeven, coverage-health, per-day/per-PR trend with outlier flagging) plus the data-derived concurrency assessment. Per-model pricing is config-driven (`PIPELINE_PRICE_<MODEL>_<BUCKET>`, Opus defaults; regression-guarded by `tests/test-tokenomics-pricing-config.sh`). See [observability.md](observability.md#agent-cost-capture--pipelinetokenomics) for the capture layer. Dogfood-only — not in the plugin manifest, no consumer `.claude/` writes.

## Tests

Tests live at `dev/tests/test-*.sh` and are run by `dev/tests/run-all.sh` (which CI invokes alongside `tests/test*.sh`).
