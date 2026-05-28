# metrics-snapshot fixture

Used by `tests/test-metrics-snapshot.sh` (issue #576). Each subdir is a
self-contained fixture for one sibling script:

- `over-eval/` — passed as `--fixture` to `over-eval-report.sh`.
- `late-error/` — passed as `--fixture` to `late-error-report.sh`.
- `compliance/` — passed as `--fixture` to `compliance-backfill.sh`.
- `review-audits/` — contains `output.txt` (one synthetic deviation per
  line). Consumed directly by `metrics-snapshot.sh` in `--fixture` mode
  because `review-audits.sh` itself does not have a `--fixture` flag.

Each fixture is intentionally minimal: just enough rows to exercise every
aggregation branch (PASS+SKIP for compliance, all four stages for
late-error, one outlier for over-eval) without duplicating the larger
upstream sibling fixtures.
