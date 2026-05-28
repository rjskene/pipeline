# late-error-report fixtures

Static fixtures consumed by `tests/test-late-error-report.sh`. They cover
the four pipeline PATHs (A/B/C/D) plus release-PR exclusion.

Each per-PR `pr-<N>.json` carries an `## Evaluation` comment whose findings
are tagged with one of the four stage markers (`[stage: issue]`,
`[stage: plan]`, `[stage: plan-eval]`, `[stage: pr-eval]`). The script's v0
categorizer is a literal substring match against those markers — see
`scripts/late-error-report.sh` for the full vocabulary.

## Contents

| File | Shape | Used by |
|---|---|---|
| `prs.json` | `gh pr list --json number,title,additions,deletions,body,mergedAt,labels` (6 PRs) | scenarios 2-5 |
| `pr-<N>.json` | `gh pr view <N> --json number,additions,deletions,comments` (one per feature PR) | scenarios 2-4 |
| `issue-<N>.json` | `gh issue view <N> --json number,labels,comments` (one per linked issue) | scenarios 2-4 |

## PATH mapping + stage distribution

| PR | Issue | Labels | PATH | Findings (stage) |
|---|---|---|---|---|
| 101 | 201 | `docs-only` | A | issue, plan, pr-eval (3) |
| 102 | 202 | — | B | issue, plan, plan-eval, pr-eval (4) |
| 103 | 203 | `multi-task` | C | plan, plan, plan-eval, pr-eval, pr-eval (5) |
| 104 | 204 | `quick-fix` | D | issue, pr-eval, pr-eval (3) |

## Release-PR fixtures (excluded by `is_release_pr` filter)

| PR | Detection rule |
|---|---|
| 901 | `autorelease: tagged` label |
| 902 | title matches `^release: v` (back-sync) |

These MUST NOT appear in `--emit-rows-json` output or the rendered table.
