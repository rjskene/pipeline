# cost-latency-report fixtures

Static fixtures consumed by `tests/test-cost-latency-report.sh` (issue #643).
They join merged-PR data with #642's capture JSONL to exercise every report
branch: per-issue rows, ceremony detection, over-served flagging, missing-token
`--` rendering, per-PATH / per-stage aggregates, TOP-N, and `--dry-run`.
