# PR-eval preflight (#1445)

Read this when a Step 7 preflight returns anything other than `PREFLIGHT=ok REASON=none`, or when `--spawn` is in the fullsend argv.

`scripts/pr-eval-preflight.sh <N> --pr <P> --worktree <abs>` runs, before any evaluator token is spent, the four mechanical checks the Opus evaluator used to repeat inside its own turn budget. `<P>` is the `PR=` field of that issue's Step 6b `check-ci-fix-loop.sh` line; `<abs>` is the issue's worktree (the guards are cwd-relative — from the orchestrator checkout the branch-cruft arm would see zero paths and be vacuous). Stdout is exactly one line and the exit status is always 0: the ORCHESTRATOR decides what a block means.

```
PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>
```

## Arm order IS the precedence order

| # | Arm | Fatal | Advisory | Fix |
|---|-----|-------|----------|-----|
| 1 | body-contract (`## Pre-existing failures`, #1329) | `body-contract` | — | `body-contract` |
| 2 | ci rollup (the `auto-merge-gate.sh` jq predicate) | `ci-red` | `ci-pending`, `no-ci`, `ci-disabled` | — |
| 3 | base / mergeable (next-branch aware, #1131) | `base` | `mergeable` | — |
| 4 | guards (cross-cutting aggregator + branch cruft) | `guards` | — | — |

The first fatal arm wins. With no fatal, the first advisory is reported. Neither ⇒ `REASON=none`.

## Acting on the line (Step 7)

| Line | Orchestrator action |
|------|---------------------|
| `ok` (any `REASON`) | dispatch the evaluator, appending the line VERBATIM to the prompt |
| `block REASON=ci-red` | no dispatch; fold into the existing Step 6b CI-red row |
| `block REASON=<other>` | no dispatch; report a `block-<REASON>` row in the Step 8 table |
| `FIXED=body-contract` | surface the token in the wave report — a body write the pipeline made on the executor's behalf stays auditable against #1329 |

An `ok` with `REASON=no-ci` / `ci-disabled` / `ci-pending` is NOT a green verdict: the evaluator's `ROLLUP_GREEN` is true only for `none` / `mergeable`, so those three keep its local-test fallback armed. "No CI configured" must never be trusted as "CI green" — the gate's own predicate maps an empty rollup to `true`, which is correct for *nothing failed* and wrong for *nothing ran*.

`mergeable` is advisory, not fatal: the preflight never pushes, so the only remediation for a non-mergeable PR is the evaluator's own Step 8 rebase, and a block would park the PR at `pr-open` with no eval AND no rebase. For the same reason the evaluator reads mergeability itself rather than keying off `REASON=mergeable` — `REASON` carries exactly one advisory, so a concurrent `ci-pending` would hide it. An unsettled rollup is advisory because Step 6b already documents `ACTION=pending` as "treat as green so step 7 still runs".

## The `--spawn` path

`scripts/run-queue.sh` is **NOT modified**. It has no per-issue prompt channel — the queued session's prompt is assembled from `--skill evaluate-issue-pr` plus the issue number, with nowhere to thread a per-PR preflight line through. So under `--spawn` the gate is an ORCHESTRATOR-SIDE FILTER that runs before the queue launch: only `PREFLIGHT=ok` issues enter the `run-queue.sh --skill evaluate-issue-pr` argv. The spawned session therefore carries no preflight line and takes the evaluator's absent-line fallback, running the preflight once itself (`skills/evaluate-issue-pr/SKILL.md` Step 5). That re-run is idempotent: a landed body fix reports `FIXED=none` on the second pass.

## Hook consequence, stated plainly

`hooks/enforce-ci-wait.py` scopes itself to evaluator sessions that issued a `gh pr view <PR> … --json statusCheckRollup` Bash row (`ROLLUP_RE`). A preflight call is a `bash …/pr-eval-preflight.sh` row, which that pattern does not match, so on the trusted green path the hook returns 0 and its "Approved verdict with failing CI" arm goes INERT. That is deliberate and is what makes the collapse safe to run: leaving the evaluator's own rollup read in place while dropping its `--watch` would DENY Stop on every eval and escalate `needs-human` after three blocks.

Compensating controls, in order of when they fire:

1. The preflight blocks `ci-red` **before** any Opus token is spent.
2. `scripts/auto-merge-gate.sh` re-reads the rollup at merge time and emits `block-ci`; it is fail-closed on a pending conclusion, so no bad merge is reachable.
3. The `ci-pending` branch and every post-push re-check still emit the full rollup → `--watch` → rollup triple, so the hook keeps its teeth exactly where CI is genuinely unsettled. The evaluator's Step 5 states this: the preflight line is stale the moment it pushes.

No hook file is edited, so `tests/test-cage-invariant-enforce-ci-wait.sh` is unaffected — what changed is the hook's reach, pinned by `tests/test-pr-eval-preflight-wiring-prose.sh`.
