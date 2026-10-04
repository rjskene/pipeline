# PR-eval preflight (#1445)

Read this when a Step 7 preflight returns anything other than `PREFLIGHT=ok REASON=none`, or when `--spawn` is in the fullsend argv.

`scripts/pr-eval-preflight.sh <N> --pr <P> --worktree <abs>` runs, before any evaluator token is spent, the four mechanical checks the Opus evaluator used to repeat inside its own turn budget. Both are DERIVED inside the Step 7 wave loop, never recalled from orchestrator context: `<abs>` from the Step 5 worktree naming rule `.claude/worktrees/${PIPELINE_WORKTREE_PREFIX}-<N>-<slug>` (glob on `-<N>-`), `<P>` from that worktree's branch via `gh pr list --head`. A worktree-glob miss leaves `<abs>` empty, and the `[ -n "$WT" ]` test in the loop's `PR_NUM=` substitution is what fails closed — `git -C ""` is a no-op that exits 0 and prints the ORCHESTRATOR's own branch, so `git`'s exit status is NOT a guard. `<abs>` is the issue's worktree because the guards are cwd-relative — from the orchestrator checkout the branch-cruft arm would see zero paths and be vacuous. Stdout is exactly one line and the exit status is always 0: the ORCHESTRATOR decides what a block means.

```
PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>
```

## Arm order IS the precedence order

| # | Arm | Fatal | Advisory | Fix |
|---|-----|-------|----------|-----|
| 0 | argv / config (pre-arm) | `usage`, `config`, `no-pr` | — | — |
| 1 | body-contract (`## Pre-existing failures`, #1329) | `body-contract` | — | `body-contract` |
| 2 | ci rollup (the `auto-merge-gate.sh` jq predicate) | `ci-red` | `ci-pending`, `no-ci`, `ci-disabled` | — |
| 3 | base / mergeable (next-branch aware, #1131) | `base` | `mergeable` | — |
| 4 | guards (cross-cutting aggregator + branch cruft) | `guards` | — | — |

The first fatal arm wins. With no fatal, the first advisory is reported. Neither ⇒ `REASON=none`. Arm 0 exists so a config/argv problem is still a LINE: `PIPELINE_REPO` unset (the #801 subshell seam) reports `block REASON=config` rather than exiting silently, and a value-less `--pr`/`--worktree` reports `block REASON=usage` rather than spinning in the argv loop.

### What arm 1 will and will not write

The auto-fix APPENDS; it never replaces. So an unreadable or empty body (`gh` rc != 0 — rate limit, 5xx) is fatal `body-contract` with NO write at all: appending to an unread body is a full-description overwrite, and GitHub keeps no body history. The fatal-claim arm also demands a STANDING-failure qualifier (`pre-existing`, `known failure`) rather than a bare `fail` keyword — the `tdd-implementer` discipline describes itself as "RED: the test fails before the fix" and #1218 demands negative controls ("the guard FAILS on the unfixed script"). This verdict sits BEFORE any dispatch, so a false positive does not degrade: it wedges the wave.

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
2. `scripts/auto-merge-gate.sh` re-reads the rollup at merge time and emits `block-ci`, plus `block-mergestate` on any non-`CLEAN` `mergeStateStatus` — which covers `UNSTABLE` (a failing or pending non-required check). One window survives: in the seconds between a push and GitHub CREATING the check run, the new head's rollup is EMPTY and `mergeStateStatus` is `CLEAN`, so the gate greenlights. That is why control 3 is not optional.
3. The `ci-pending` branch and every post-push re-check still emit the full rollup → `--watch` → rollup triple, so the hook keeps its teeth exactly where CI is genuinely unsettled. The evaluator's Step 5 states this: the preflight line is stale the moment it pushes.

No hook file is edited, so `tests/test-cage-invariant-enforce-ci-wait.sh` is unaffected — what changed is the hook's reach, pinned by `tests/test-pr-eval-preflight-wiring-prose.sh`.
