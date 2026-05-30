# cost-latency-report fixtures

Static fixtures consumed by `tests/test-cost-latency-report.sh` (issue #643).
They join merged-PR data (`gh`) with #642's capture log to exercise every
report branch: per-issue rows, ceremony detection, over-served flagging,
missing-token `--` rendering, per-PATH / per-stage aggregates, TOP-N, and
`--dry-run`. No live `gh` calls — the script's `--fixture DIR` mode reads
these files instead.

## Contents

| File | Shape | Purpose |
|---|---|---|
| `prs.json` | `gh pr list --json number,title,additions,deletions,body,mergedAt,labels` payload | 4 eligible feature PRs + 1 release PR (excluded) |
| `pr-<N>.json` | `gh pr view <N> --json number,additions,deletions,comments` (one per PR) | carries the `## Evaluation` comment used for ceremony |
| `issue-<N>.json` | `gh issue view <N> --json number,labels,comments` (one per linked issue) | labels (PATH) + `## Implementation Plan` / `## Plan Evaluation` comments |
| `capture.jsonl` | #642 capture log — one JSON object per line | token + wall-clock records joined per issue/stage |

## PR / issue / PATH mapping

| PR | Issue | Labels | PATH | loc | ceremony | over-served | Notes |
|---|---|---|---|---|---|---|---|
| 102 | 202 | — | B | 160 | yes | no | standard; full ceremony, large diff |
| 302 | 402 | — | B | 8 | yes | **yes** | the operator's case: full ceremony, tiny diff |
| 103 | 203 | `multi-task` | C | 800 | yes | no | wide diff |
| 104 | 204 | `quick-fix` | D | 3 | no | no | quick-fix: no plan/eval comments → ceremony 0; no capture → tokens `--` |
| 901 | — | `autorelease: tagged` | — | — | — | — | release PR, excluded by the `is_release_pr` filter |

`over_served = ceremony AND loc <= --over-served-loc` (default 20). Issue 402
(loc 8 ≤ 20, full ceremony) is the over-served outlier; `--over-served-loc 4`
reclassifies it out (loc 8 > 4) — proves the threshold is tunable.

## Capture log schema (`capture.jsonl`, owned by #642)

One JSON object per line, append-only:

```json
{"issue": 202, "stage": "plan", "agent_type": "general-purpose",
 "tokens": {"input": 1200, "output": 800, "cache": 5000}, "duration_ms": 41000}
```

- `issue` — integer issue number. Records whose issue is not in the merged-PR
  window are ignored (the fixture includes issue `999` to prove this).
- `stage` — one of the 5 canonical stages `classify | plan | plan-eval |
  execute | pr-eval`.
- `tokens` — `{input, output, cache}`; `tokens_total = input + output + cache`.
- `duration_ms` — wall-clock milliseconds.
- Multiple records may share an `(issue, stage)`; the report **sums** them.

Coverage in this fixture: issue 202 has `plan` + `execute` + `pr-eval`
records; issue 402 has `plan` + `execute` (deliberately **no** `pr-eval`);
issue 203 has `execute`; issue 204 has **none** (→ tokens render `--`, JSON
`null`). No record carries `classify` or `plan-eval`, so those per-stage rows
render `--`. Record for issue 999 is out-of-window and must be dropped.
