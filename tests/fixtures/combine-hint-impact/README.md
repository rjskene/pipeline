# combine-hint-impact fixtures

Synthetic data for `tests/test-combine-hint-impact.sh`. Mirrors the
`tests/fixtures/cost-latency-report/` shape: `issues.json`, per-issue
`issue-<N>.json`, and a synthetic `agent-costs.jsonl` (`capture.jsonl`).

The cohort split timestamp under test is the #752 merge:
`MERGE_TS = 2026-06-01T10:32:15Z`. An issue is `pre` when its `createdAt`
is `< MERGE_TS` (lexicographic compare on fixed-width RFC-3339 `Z`), else
`post`.

## Default fixture (root)

Real-data-shaped: large PRE cohort, ~empty POST cohort, so every post
bucket falls below `MIN_N` (default 5) and the tool renders
`INSUFFICIENT DATA`.

| Issue | createdAt | cohort | PATH | files_changed | bucket | hint | accuracy notes |
|-------|-----------|--------|------|---------------|--------|------|----------------|
| 101 | 2026-05-21 | pre  | B | 2 | 2-3 | —    | single plan, first-pass approve |
| 102 | 2026-05-22 | pre  | B | 3 | 2-3 | —    | single plan, first-pass approve |
| 103 | 2026-05-23 | pre  | B | 2 | 2-3 | —    | single plan, first-pass approve |
| 104 | 2026-05-24 | pre  | B | 3 | 2-3 | —    | single plan, first-pass approve |
| 105 | 2026-05-25 | pre  | B | 2 | 2-3 | —    | single plan, first-pass approve |
| 106 | 2026-05-25 | pre  | B | 3 | 2-3 | —    | single plan, first-pass approve |
| 301 | 2026-06-01T11 | post | B | 2 | 2-3 | B | first-pass approve; hint=B agrees with classification B |
| 302 | 2026-06-01T12 | post | B | 3 | 2-3 | — | 2 plan comments (1 re-plan) + escalation marker |

- `pre_n = 6` in PATH B × bucket `2-3` (≥ MIN_N).
- `post_n = 2` in PATH B × bucket `2-3` (< MIN_N) → INSUFFICIENT DATA.
- Hint quality (post-only): emit rate = 1/2 (only 301 carries a hint);
  agreement = 1/1 (301's hint `B` matches its classification `B`).

`capture.jsonl` carries PRE records at `cache_creation=1000` and POST at
`cache_creation=700`. It also includes:
- a duplicate `record_key` (`rk-101-execute`) to exercise the first
  dedup pass (last-write-wins);
- a keyless `(session_id, issue, stage)` collision for issue 102 to
  exercise the second dedup pass (`max_by(tokens.total)`).

## Sufficiency variants (`keep/`, `revert/`)

Force `post_n = 5` in PATH B × bucket `2-3` so the verdict gate clears
`MIN_N` and the recommendation logic is exercised.

- `keep/`   — POST `cache_creation=700` (< PRE 1000) → cost `down`,
  accuracy not worse → `VERDICT: Keep`.
- `revert/` — POST `cache_creation=1400` (> PRE 1000) → cost `up`
  → `VERDICT: Revert-candidate`.

Both: issues `501-505` (pre) and `601-605` (post), all PATH B, bucket
`2-3`, first-pass approve, post issues carry `<!-- pipeline:path-hint=B -->`.
