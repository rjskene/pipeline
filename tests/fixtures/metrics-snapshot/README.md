# metrics-snapshot fixture

Used by `tests/test-metrics-snapshot.sh` (issue #576). Each subdir is a
self-contained fixture for one sibling script:

- `over-eval/` — passed as `--fixture` to `over-eval-report.sh`.
- `late-error/` — passed as `--fixture` to `late-error-report.sh`.
- `compliance/` — passed as `--fixture` to `compliance-backfill.sh`.
- `review-audits/` — contains `output.txt` (one synthetic deviation per
  line). Consumed directly by `metrics-snapshot.sh` in `--fixture` mode
  because `review-audits.sh` itself does not have a `--fixture` flag.
- `cost-latency/` — passed as `--fixture` to `cost-latency-report.sh`
  (issue #643). Carries `prs.json`, `pr-<N>.json`, `issue-<N>.json`, and
  `capture.jsonl` for two issues: #210 (loc 6, full ceremony → over-served)
  and #211 (loc 150, full ceremony → not over-served). Exercises the three
  cost/latency columns `cost_tokens_total` / `cost_duration_ms_median` /
  `over_served_count` (`over_served_count == 1`).

Each fixture is intentionally minimal: just enough rows to exercise every
aggregation branch (PASS+WEAK+SKIP for compliance, all four stages for
late-error, one outlier for over-eval, one over-served issue for
cost-latency) without duplicating the larger upstream sibling fixtures.
