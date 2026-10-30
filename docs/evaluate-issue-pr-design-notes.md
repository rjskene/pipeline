# evaluate-issue-pr design notes — retired rationale

`skills/evaluate-issue-pr/SKILL.md` carries rules only. This file keeps the history and rationale that #1515 cut from it: one bullet per retired paragraph, with the issue that motivated it. Nothing here is a contract; the skill, the `scripts/evaluate-issue-pr-*.sh` helpers and the tests are.

## Structure (#1515)

- The body went from ≈2960 to ≤1600 words. Every multi-command bash fence became a helper that answers `--help`: `evaluate-issue-pr-fetch-plan.sh` (Step 1), `-diff.sh` (Step 2), `-checks.sh` (Step 4), `-rebase-check.sh` (Step 8). `tests/test-evaluate-issue-pr-mass-budget.sh` pins the budget: body ≤1600 words (floor 1200), zero citations, one command per fence.
- The canonical `## Executable verification` block stays byte-identical with evaluate-issue-plan's copy (Case G of `tests/test-evaluator-executable-verification-prose.sh`); it is what catches a planted bug, so it was not tabled (#1218).
- The CI triple is never wrapped in a helper: `hooks/enforce-ci-wait.py` matches the literal `gh pr view <digits> … statusCheckRollup` / `gh pr checks <digits> … --watch` commands, one logged row per Bash call. The fences carry `<PR>` because the hook only matches literal numbers, so the model substitutes the number anyway.
- `$PR_NUM` was bound only by the old Step 2 fence; with that fence in a helper, `tests/test-skill-unassigned-vars.sh` would flag every remaining `$PR_NUM` (#1215), hence `<PR>`.
- The pr-eval Opus pin is explicit because an unpinned dispatch inherits the session model (#1186).
- `HARNESS-FRICTION:` lines were already required by fullsend's PR-eval dispatch prompt; Step 10 now names them so the skill carries the literal.
- Every presence guard reads the BODY, never the whole file: a YAML `description:` line once satisfied a deleted body clause (#1218).

## Plan fetch and trust

- Trust is delegated to `filter-trusted-comments.sh --json` (#545) — the single source of trust truth; the tier set is never re-implemented inline. Only `OWNER` / `MEMBER` / `COLLABORATOR` survive, so a later planted `## Implementation Plan` from a non-contributor can never override the operator's (#1315).
- Selection is by anchored heading through `select-plan-comment.sh`; a loose substring match selected an evaluation that quoted the plan heading (#1240, #1251). The raw `gh issue view --json comments` pipe is blocked by `enforce-comment-trust.py`, which made an earlier fix inert (#1253).
- The old fence had to run as a SINGLE bash command because its shell variables died across calls; the helper makes that moot, and it prints the plan on stdout so the model can see it.
- Plan amendments (#1435, #1440): under `PIPELINE_PLAN_GATE=annotate` a `Revise` plan evaluation is never folded back into the plan, so its `**Recommendations:**` are amendments to the plan of record. The evaluator scores the PR against plan + amendments — otherwise an amendment-driven change reads as scope creep, and a dropped amendment is invisible to the only stage that could catch it.

## Review and tests

- Green-CI short-circuit (#957): the full local suite re-run duplicated the green CI suite. It trusts that CI runs the same suite as `PIPELINE_TEST_CMD` — true for the dogfood repo; consumers with divergent CI should know this trust boundary.
- The suite runs at most once and never via `run_in_background`: harness auto-backgrounding caused duplicate overlapping sweeps (#955, #956).
- The CI verdict is read from the dispatched `PREFLIGHT=` line, never a rollup query of the evaluator's own: a lone rollup row arms `enforce-ci-wait.py` and wedges every trusted eval (#1445).
- The cross-cutting guard aggregator moved into `pr-eval-preflight.sh`; a failure there is `PREFLIGHT=block REASON=guards` and no eval runs (#1132, #1445).
- CI is the oracle for pre-existing failures (#1322); the `PRE-EXISTING:` list check runs the subject check over the PR body's list (#1329).
- Executable verification fires per claim with a negative control (#1218); fixtures live under `.claude/scratch/` and are cleaned by literal path only.

## CI wait

- The `--watch` runs in the foreground: a backgrounded Bash returns at once and ends the subagent's turn before the verdict (#684).
- The preflight line is stale after any push — a Step 7 fix or a Step 8 rebase — so the triple is re-emitted as three separate calls: the hook compares row timestamps, and three commands in one call share one, so Stop is denied three times and the issue escalates `needs-human`.
- The failing job's first error line comes from `gh run view <RUN_ID> --log-failed | head -20`, `RUN_ID` taken from the failed check's `detailsUrl`.

## Rebase

- Feature PRs land as merge-commits (#459), so an advanced base alone is not a reason to rebase, and a needless rebase forces a CI re-watch. The helper rebases nothing; it reports `REBASE=needed` only when the PR is not `MERGEABLE` (after settling `UNKNOWN`), `DIRTY`, or a file changed on both sides since the merge-base.
- Mergeability is read in Step 8, never from the preflight's `REASON`: `REASON` carries exactly one advisory, so a concurrent `ci-pending` hides `mergeable` and the PR would strand on the gate's `block-mergeable` (#1445). That query is not a rollup read, so the CI-wait hook stays out of scope.

## Output

- pr-eval output is ≈20% of total pipeline spend and output tokens are uncacheable, hence the TERSENESS directive (#728).
- The auto-merge gate moved out of the evaluator to the orchestrator (#1444); the evaluator's verdict line is its terminal state.
