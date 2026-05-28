# compliance-backfill fixtures

Static fixtures consumed by `tests/test-compliance-backfill.sh`. Mirrors the
`tests/fixtures/over-eval-report/` shape, with two extra per-PR payload
files needed by the underlying `scripts/audit-compliance.sh` injection
flags (`--commits-json`, `--files-json`).

## Contents

| File | Shape | Used by |
|---|---|---|
| `prs.json` | `gh pr list --json number,title,additions,deletions,body,mergedAt,labels` payload (9 PRs) | all scenarios |
| `pr-<N>.json` | `gh pr view <N> --json ...` (one per eligible feature PR) | symmetry with over-eval-report; not required by the wrapper |
| `issue-<N>.json` | `gh issue view <N> --json number,labels,comments` (one per linked issue) | PATH derivation via labels |
| `commits-<N>.json` | `[{oid, files:[paths]}, ...]` payload (one per eligible feature PR) | injected into `audit-compliance.sh --commits-json` |
| `files-<N>.json` | `[paths]` payload (one per eligible feature PR) | injected into `audit-compliance.sh --files-json` |

## PATH coverage matrix

| PR | Issue | Labels | PATH | Commits shape | Expected TDD verdict |
|---|---|---|---|---|---|
| 101 | 201 | `docs-only` | A | docs-only commit | row omitted (counted as `omitted`) |
| 102 | 202 | — | B | test commit, then source commit | PASS |
| 103 | 203 | — | B | source-only commit | SKIP |
| 104 | 204 | — | B | docs-only commit (no source change) | N/A |
| 105 | 205 | `multi-task` | C | test commit, then source commit | PASS |
| 106 | 206 | `quick-fix` | D | test commit, then source commit | PASS |
| 107 | 207 | `quick-fix` | D | source-only commit | SKIP |
| 108 | — | — | — | n/a — body lacks `Closes/Fixes/Resolves #N` | skipped-no-link |
| 901 | — | `autorelease: tagged` | — | n/a | excluded (release PR) |

The PATH D pair (106 PASS / 107 SKIP) demonstrates that
`audit-compliance.sh:127-128` only special-cases PATH A — PATH D commits
are evaluated identically to PATH B.

## Aggregation expectations

| PATH | N | PASS | SKIP | N/A | SKIP-rate |
|---|---|---|---|---|---|
| A | 1 | 0 | 0 | 0 | -- (PR 101 row omitted by `audit-compliance.sh`, classified as `omitted`) |
| B | 3 | 1 | 1 | 1 | 50.0% (1 / (1+1)) |
| C | 1 | 1 | 0 | 0 | 0.0% (0 / (1+0)) |
| D | 2 | 1 | 1 | 0 | 50.0% (1 / (1+1)) |

Overall SKIP-rate = SKIP / (PASS + SKIP) across B/C/D = 2 / (3 + 2) = 40.0%.
