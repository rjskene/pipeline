# tokenomics-report fixtures

A SINGLE consolidated, **model-bearing** golden fixture consumed by
`tests/test-cost-latency-report.sh` Scenario 26 (issue #721) and showcased by
the `/pipeline:tokenomics` skill (Task 6). Unlike the base
`tests/fixtures/cost-latency-report` fixture (whose records carry **no `model`
field**, so its `--tokenomics` $ tables render all-zero), every priced record
here sets `model:"claude-opus-4-8"`, so `--tokenomics` produces a RICH non-zero
demo that exercises **every** new dimension in one run:

```
bash scripts/cost-latency-report.sh --fixture tests/fixtures/tokenomics-report \
    --tokenomics
```

No live `gh` calls — `--fixture DIR` mode reads these files instead.

## Contents

| File | Shape | Purpose |
|---|---|---|
| `prs.json` | `gh pr list --json number,title,additions,deletions,body,mergedAt,labels` | 4 eligible feature PRs (201→B, 202→B, 203→C, 204→D) + 1 release PR (#991, excluded) |
| `pr-<N>.json` | `gh pr view <N> --json number,additions,deletions,comments` (one per PR) | carries the `## Evaluation` comment used for ceremony |
| `issue-<N>.json` | `gh issue view <N> --json number,labels,comments` (one per linked issue) | labels (PATH) + `## Implementation Plan` / `## Plan Evaluation` comments |
| `capture.jsonl` | #642 capture log — one JSON object per line | model-bearing token + wall-clock records joined per issue/stage |

## PR / issue / PATH mapping

| PR | Issue | Labels | PATH | loc | ceremony | Notes |
|---|---|---|---|---|---|---|
| 201 | 301 | — | B | 400 | yes | full headless set (plan, plan-eval, execute, pr-eval) — the breakeven anchor |
| 202 | 302 | — | B | 100 | yes | smaller headless set (plan, execute) — second breakeven row |
| 203 | 303 | `multi-task` | C | 1000 | yes | two execute sessions (multi-session re-run, both preserved) |
| 204 | 304 | `quick-fix` | D | 4 | no | no plan/eval comments → ceremony 0; no capture → tokens `--` |
| 991 | — | `autorelease: tagged` | — | — | — | release PR, excluded by the release-PR filter |

## Capture log schema (`capture.jsonl`, schema_version=1, owned by #642)

One JSON object per line, append-only. Fields used by the report:

```json
{"schema_version":1,"issue":"301","stage":"execute","agent_kind":"headless",
 "agent_type":"pipeline:tdd-implementer","session_id":"s301exec",
 "model":"claude-opus-4-8","record_key":"K301EXEC",
 "tokens":{"input":2000000,"output":1000000,"cache_creation":4000000,
           "cache_read":10000000,"total":17000000},
 "duration_ms":5400000,"ts_start":"2026-05-22T09:00:00Z",
 "ts_end":"2026-05-22T09:30:00Z","usage_complete":true}
```

- `issue` — STRING issue number (orchestrator records carry `""`).
- `stage` — `plan | plan-eval | execute | pr-eval | orchestrator`.
- `agent_kind` — `headless` (spawn) | `inline` | `main` (orchestrator).
- `model` — non-empty → **priced** at the per-(model,bucket) rate (Opus default
  fallback); `""` → **UNPRICED** (#699 INLINE records): excluded from the $
  total, COUNTED for coverage health.
- `session_id` / `record_key` — idempotency / dedup keys (see below).
- `tokens` — `{input, output, cache_read, cache_creation, total}`;
  `total = input+output+cache_read+cache_creation`.
- `duration_ms` — wall-clock ms. **headless** durations are whole-session
  lifetime (the ~5.4M ms cluster), NOT task latency — `--tokenomics` lists them
  separately and EXCLUDES them from the task-latency aggregate. Orchestrator
  `duration_ms` is `null`.
- `ts_start` / `ts_end` — ISO-8601; day-bucketed (YYYY-MM-DD of `ts_start`) for
  the trend table and swept for execute concurrency.

## Dimensions exercised (and the golden values they pin)

**Pricing (Opus defaults, per 1M: in 15, out 75, cc 18.75, cr 1.50).** The nine
surviving PRICED records and their all-four-bucket $:

| record | in | out | cc | cr | $ |
|---|---|---|---|---|---|
| 301 plan | 1.0M | 0.2M | 2.0M | 4.0M | 73.50 |
| 301 plan-eval | 0.5M | 0.1M | 1.0M | 2.0M | 36.75 |
| 301 execute | 2.0M | 1.0M | 4.0M | 10.0M | 195.00 |
| 301 pr-eval | 0.8M | 0.2M | 1.0M | 3.0M | 50.25 |
| 302 plan | 0.4M | 0.1M | 0.8M | 1.0M | 30.00 |
| 302 execute | 1.0M | 0.5M | 2.0M | 5.0M | 97.50 |
| 303 execute (sB) | 4.0M | 4.0M | 8.0M | 20.0M | 540.00 |
| 303 execute (sC) | 3.0M | 3.0M | 6.0M | 15.0M | 405.00 |
| orchestrator (final) | 5.0M | 2.0M | 0 | 0 | 225.00 |
| **PRICED $ TOTAL** | | | | | **1653.00** |

- **Token-share ≠ cost-share** — output: 9.8% of tokens but 50.4% of $;
  cache_read: 52.8% of tokens but 5.4% of $.
- **Model-attribution coverage = 9/10 (90.0%)** — one UNPRICED inline record
  (`issue 301`, `model:""`, `agent_kind:"inline"`) is counted but unpriced.
- **`record_key` dedup (pass 1, last-write-wins)** — two `K301EXEC` execute
  records (8.5M then 17.0M total) collapse to the last/larger one.
- **`(session_id, issue, stage)` max-total dedup (pass 2)** — three
  `orchestrator` snapshots on session `sORCH` (totals 1.4M → 4.2M → 7.0M,
  `duration_ms:null`) collapse to the 7.0M max ($225.00).
- **Multi-session re-run preserved** — issue 303 / execute has two DISTINCT
  session_ids (`s303execB`, `s303execC`); group_by keeps both.
- **Multi-day trend with an OUTLIER** — three distinct days; 2026-05-22
  ($1237.50 = 74.9% of the window) is flagged `*OUTLIER` (≥40%-of-window rule);
  2026-05-20 ($365.25) and 2026-05-21 ($50.25) are not.
- **Execute concurrency = 3** — four execute headless intervals on 2026-05-22:
  301 `09:00–09:30`, 302 `09:10–09:40`, 303B `09:20–09:50`, 303C `10:00–10:30`;
  the first three overlap at `09:20–09:30` → max observed concurrent = 3.
- **headless session-lifetime durations** — every headless record carries
  `duration_ms:5400000` (~5.4M ms); these are listed under HEADLESS DURATIONS
  and EXCLUDED from the task-latency aggregate.
- **B→D breakeven** — PATH B issues 301 (saved plan+plan-eval = 73.50+36.75 =
  110.25) and 302 (saved plan = 30.00) → TOTAL savings 140.25.
