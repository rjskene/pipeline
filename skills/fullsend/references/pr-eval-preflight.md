# PR-eval preflight

Read this when a Step 7 preflight returns anything other than `PREFLIGHT=ok REASON=none`, or when `--spawn` is in the fullsend argv.

`scripts/pr-eval-preflight.sh <N> --pr <P> --worktree <abs>` runs four mechanical checks before any evaluator token is spent. `scripts/fullsend-preflight.sh` DERIVES `<abs>` (worktree glob on `-<N>-`) and `<P>` (that worktree's branch via `gh pr list --head`), failing closed on the `[ -n ]` guards since `git -C ""` and `gh pr list --head ""` exit 0. The worktree matters: the guards are cwd-relative. Stdout is one line, exit always 0; the ORCHESTRATOR decides what a block means.

```
PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>
```

## Arm order IS the precedence order

| # | Arm | Fatal | Advisory | Fix |
|---|-----|-------|----------|-----|
| 0 | argv / config (pre-arm) | `usage`, `config`, `no-pr` | — | — |
| 1 | body-contract (`## Pre-existing failures`) | `body-contract` | — | `body-contract` |
| 2 | ci rollup (the `auto-merge-gate.sh` jq predicate) | `ci-red` | `ci-pending`, `no-ci`, `ci-disabled` | — |
| 3 | base / mergeable (next-branch aware) | `base` | `mergeable` | — |
| 4 | guards (cross-cutting aggregator + branch cruft) | `guards` | — | — |

The first fatal arm wins; else the first advisory; else `REASON=none`. Arm 0 keeps config/argv problems a LINE (`PIPELINE_REPO` unset ⇒ `block REASON=config`; a value-less flag ⇒ `block REASON=usage`).

Arm 1's auto-fix APPENDS, never replaces: an unreadable or empty body is fatal `body-contract` with NO write. Its fatal claim needs a standing-failure qualifier (`pre-existing`, `known failure`), not a bare `fail`.

## Acting on the line (Step 7)

| Line | Orchestrator action |
|------|---------------------|
| `ok` (any `REASON`) | dispatch the evaluator, appending the line VERBATIM to the prompt |
| `block REASON=ci-red` | no dispatch; fold into the existing Step 6b CI-red row |
| `block REASON=<other>` | no dispatch; report a `block-<REASON>` row in the Step 8 table |
| `FIXED=body-contract` | surface the token in the wave report so the pipeline's body write stays auditable |

`ok` with `REASON=no-ci` / `ci-disabled` / `ci-pending` is NOT green: the evaluator's `ROLLUP_GREEN` holds only for `none` / `mergeable`, keeping its local-test fallback armed — "nothing ran" is never "CI green". `mergeable` is advisory because only the evaluator's own rebase can fix it; the evaluator reads mergeability itself.

## The `--spawn` path

`scripts/run-queue.sh` is **NOT modified** — it has no per-issue prompt channel. Under `--spawn` the preflight is an ORCHESTRATOR-SIDE FILTER: only `PREFLIGHT=ok` issues enter the `run-queue.sh --skill evaluate-issue-pr` argv. The spawned session carries no preflight line and runs it once itself (`skills/evaluate-issue-pr/SKILL.md` Step 5); a landed body fix then reports `FIXED=none`.

## Hook consequence

`hooks/enforce-ci-wait.py` scopes itself to evaluator sessions that ran a `gh pr view … --json statusCheckRollup` row; a preflight call does not match, so on the trusted green path its arm is INERT. Compensating controls:

1. The preflight blocks `ci-red` **before** any evaluator token is spent.
2. `scripts/auto-merge-gate.sh` re-reads the rollup at merge time (`block-ci`, and `block-mergestate` on any non-`CLEAN` state, covering `UNSTABLE`). An empty rollup in the seconds after a push still greenlights — hence control 3.
3. The `ci-pending` branch and every post-push re-check still run the full rollup → `--watch` → rollup triple; the preflight line is stale once the evaluator pushes.

No hook file changes; the reach change is pinned by `tests/test-pr-eval-preflight-wiring-prose.sh`.
