# over-eval-report fixtures

Static fixtures consumed by `tests/test-over-eval-report.sh`. They cover
the four pipeline PATHs (A/B/C/D) plus an outlier PR used to verify the
TOP-5 OVER-EVAL OUTLIERS ranking and 5-row cap.

## Contents

| File | Shape | Used by |
|---|---|---|
| `prs.json` | `gh pr list --json number,title,additions,deletions,body,mergedAt` payload (5 PRs) | scenarios 2-5 |
| `pr-<N>.json` | `gh pr view <N> --json number,additions,deletions,comments` (one per PR) | scenarios 2-5 |
| `issue-<N>.json` | `gh issue view <N> --json number,labels,comments` (one per linked issue) | scenarios 2-5 |

## PATH mapping (matches CLAUDE.md / classify-issue precedence)

| PR | Issue | Labels | PATH | Notes |
|---|---|---|---|---|
| 101 | 201 | `docs-only` | A | no plan-eval (lifecycle skips it for A) |
| 102 | 202 | — | B | standard path; has plan-eval |
| 103 | 203 | `multi-task` | C | wide diff, has plan-eval |
| 104 | 204 | `quick-fix` | D | no plan-eval (lifecycle skips it for D) |
| 302 | 402 | — | B | outlier: tiny diff, 240-line pr-eval |

Block line counts are deliberately small and predictable so the test can
assert exact values (see the per-fixture comments in the test file).
