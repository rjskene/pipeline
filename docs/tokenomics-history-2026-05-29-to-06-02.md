# Tokenomics history — per-day token/cost slices (2026-05-29 → 2026-06-02)

> **Seed snapshot.** Hand-computed from `.claude/logs/agent-costs.jsonl` on 2026-06-02 as the seed
> artifact for the persisted-history tooling. Superseded once the report grows a `--per-day` mode and
> a periodic snapshot job (see the staged issues at the bottom). Retained because the rolling capture
> log is pruned (the #830 leak), so these per-day aggregates would otherwise be lost.

## Substrate

All tables below are computed over the **reconciled substrate**:

1. Dedup the log by `record_key`, last-write-wins.
2. Keep `usage_complete != false` (drop unreconciled lower-bounds — matches report scoping per #816).
3. For **cost** tables additionally keep `model != ""` (priced records only; the 77 empty-model records
   are unpriced and excluded, same as the report). All priced records on this window are Opus-rate
   (`claude-opus-4-7`, `claude-opus-4-8`, and `<synthetic>` → Opus fallback).

Opus rates (USD / 1M tokens): input 15 · output 75 · cache_creation 18.75 · cache_read 1.50.

**LOC** = merged-PR `additions + deletions` for the issue, joined via the `Closes/Fixes/Resolves #N`
marker. `activeLOC` for a day = sum of LOC over the distinct issues that have records that day.

## Caveats (read before using these numbers)

- **Whole-log, not PR-windowed.** These count *all* reconciled spend per day; the standard report
  TREND counts only records joined to the last-N merged PRs. So daily totals here are ≥ the report's
  (they match exactly on 2026-05-30, where all records were in-window).
- **per-LOC is directional, not additive.** LOC is static per issue; tokens are spend-day. An issue
  with records on ≥2 days contributes its full LOC to each day → cross-day double-count. Don't sum the
  per-LOC rows.
- **2026-06-02 has no LOC join** — its records are orchestrator/inline with no merged-PR LOC.
- Lower-bound records excluded, so the 2026-06-01/02 campaign issues (#800–816, #766) are largely
  absent (still unreconciled — see #830).

## Bucket totals / day (tokens, reconciled)

| day | N | input | output | cache_creation | cache_read | total |
|---|--:|--:|--:|--:|--:|--:|
| 2026-05-29 | 225 | 2,907,642 | 20,037,102 | 109,268,553 | 612,429,730 | 466,796,826 |
| 2026-05-30 | 32 | 2,877,492 | 38,492,998 | 68,692,180 | 267,772,722 | 377,835,392 |
| 2026-05-31 | 96 | 624,298 | 4,623,550 | 10,231,775 | 154,417,278 | 169,896,901 |
| 2026-06-01 | 232 | 1,638,239 | 2,622,787 | 17,186,962 | 429,399,035 | 205,790,381 |
| 2026-06-02 | 29 | 529,007 | 196,102 | 5,241,624 | 45,821,613 | 51,788,346 |

## Bucket per N (tokens ÷ record) / day

| day | N | input/N | output/N | cache_cr/N | cache_rd/N | total/N |
|---|--:|--:|--:|--:|--:|--:|
| 2026-05-29 | 225 | 12,922 | 89,053 | 485,638 | 2,721,909 | 2,074,652 |
| 2026-05-30 | 32 | 89,921 | 1,202,906 | 2,146,630 | 8,367,897 | **11,807,356** |
| 2026-05-31 | 96 | 6,503 | 48,161 | 106,580 | 1,608,513 | 1,769,759 |
| 2026-06-01 | 233 | 7,034 | 11,375 | 73,861 | 1,850,288 | 883,441 |
| 2026-06-02 | 29 | 18,241 | 6,762 | 180,745 | 1,580,055 | 1,785,805 |

## Bucket per LOC (tokens ÷ active-issue LOC) / day

| day | active LOC | input/loc | output/loc | cache_cr/loc | cache_rd/loc | total/loc |
|---|--:|--:|--:|--:|--:|--:|
| 2026-05-29 | 6,140 | 474 | 3,263 | 17,796 | 99,744 | 76,026 |
| 2026-05-30 | 6,131 | 469 | 6,278 | 11,204 | 43,675 | 61,627 |
| 2026-05-31 | 4,320 | 145 | 1,070 | 2,368 | 35,745 | 39,328 |
| 2026-06-01 | 3,407 | 481 | 778 | 5,051 | 126,539 | 60,417 |
| 2026-06-02 | — | — | — | — | — | — |

## Cost by bucket / day (USD, Opus rates) + cost/N + cost/LOC

| day | priced N | $input | $output | $cache_cr | $cache_rd | **$total** | **$/N** | active LOC | **$/LOC** |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| 2026-05-29 | 225 | 43.61 | 1502.78 | 2048.79 | 918.64 | 4513.83 | 20.06 | 6,140 | 0.735 |
| 2026-05-30 | 31 | 43.16 | 2886.91 | 1286.99 | 401.66 | **4618.72** | **148.99** | 6,131 | 0.753 |
| 2026-05-31 | 84 | 9.36 | 346.24 | 191.76 | 230.81 | 778.17 | 9.26 | 4,320 | 0.180 |
| 2026-06-01 | 229 | 24.59 | 199.80 | 322.88 | 648.04 | 1195.31 | 5.22 | 3,407 | 0.351 |
| 2026-06-02 | 29 | 7.94 | 14.71 | 98.28 | 68.73 | 189.66 | 6.54 | — | — |

## 2026-05-30 anomaly — run-queue meltdown day

05-30 is the cost outlier (**$149/record**, **$0.75/loc**, 62% output-cost). Root cause was
self-referential: the day's slate was the run-queue stall/timeout/reap subsystem itself
(#641 CPU-only stall false-positives, #656 hardcoded 90-min PATH-C timeout, #666 orphan reap,
#677 self-colliding suite re-runs, #684 evaluator CI-wait drop-out, #685 single-issue queue exit),
plus the dogfood cost-capture build (#642/#643/#662/#667/#668/#669/#678/#690/#691).

Three sessions pinned at the ~90-min (5399s) executor cap; two of them (#643, #669) emitted near-zero
output — wedged tmux workers billing idle cache_read churn. Cost concentrated in 3 issues
(#642 $1474 / #636 $1013 / #641 $943 = 74% of the $4619 day). The fixes that day were landing to kill
exactly that failure class.

## Reproduction

```bash
LOG=.claude/logs/agent-costs.jsonl
DEDUP=$(jq -s 'reduce .[] as $r ({}; .[$r.record_key]=$r) | [.[]]
  | map(select(.usage_complete != false))' "$LOG")           # add: | map(select((.model//"")!="")) for cost
# group_by((.ts_start//"")[0:10]); sum tokens.{input,output,cache_creation,cache_read,total}; ÷N for per-N.
# issue→LOC map: gh pr list --state merged --json number,additions,deletions,body, parse Closes/Fixes/Resolves #N.
```

## Staged follow-on issues

- **#831** — per-day windowing: `--until DATE` + `--per-day` mode in `cost-latency-report.sh`.
- **#832** — persisted historical snapshot so per-day history survives log pruning (#830).
- **#833** — per-N / per-LOC columns in the `--tokenomics` bucket table.

All three under epic #791 (tokenomics measurement + reporting hardening).
