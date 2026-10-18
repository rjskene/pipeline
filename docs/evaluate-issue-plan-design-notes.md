# evaluate-issue-plan design notes — retired rationale

`skills/evaluate-issue-plan/SKILL.md` carries rules only. This file keeps the history and rationale that #1517 cut from it: one bullet per retired paragraph, with the issue that motivated it. Nothing here is a contract; the skill, the `scripts/evaluate-issue-plan-*.sh` helpers and the tests are.

## Structure (#1517)

- The body went from ≈2490 to ≤1300 words (floor 1000). `tests/test-evaluate-issue-plan-mass-budget.sh` pins the budget, zero `#NNN` citations outside the Boot fence, one command per bash fence, the verdict-template and label-flip literals, and the two helpers.
- Two multi-command fences became helpers that answer `--help`: `evaluate-issue-plan-opener-gate.sh` (Step 0a) and `evaluate-issue-plan-fetch-plan.sh` (Step 1). Behaviour is unchanged: the gate still exits 0 with a `REFUSED:` line and posts the same triage comment text, and the fetch still stops on `No implementation plan found for issue #N.`
- The canonical `## Executable verification` block was not cut: `tests/test-evaluator-executable-verification-prose.sh` Case G pins it byte-identical with evaluate-issue-pr's copy. The budget closed on fences, citations, rationale and template parentheticals instead.
- The report now ends with zero or more `HARNESS-FRICTION:` lines, matching fullsend's other dispatches; no gate or verdict changed.

## Dispatch model (#1186)

- Under fullsend the Agent's `model=` is never inherited from the orchestrator session: `resolve-stage-model.sh <N> plan-eval` pins `tier-max(plan producer, ${PIPELINE_STAGE_MODEL_PLAN_EVAL:-opus})`. An `opus` floor by default; PATH C follows its plan producer (`REASON=follows-producer`).
- Why: in fullsend plan approval is an auto-gate with no human behind it, so an evaluator below the tier that wrote the plan is not an independent check. Equal tier is fine — the evaluator's value is independent context.

## Comment trust (#545–#549, #565)

- The opener-association gate (#565) refuses an issue opened by an untrusted author and surfaces it for human triage instead of evaluating it — Design Principle 2. It changes no label, which is why it does not reuse `refuse-untrusted-opener.sh` (that adds `human`). The triage comment keeps its legacy wire text, which `refuse-untrusted-opener.sh` dedups on.
- The association comes from `gh api repos/<repo>/issues/<N>` because `gh issue view --json author` returns only `{login,name,id}` — no association field.
- Trust is delegated to #545's `filter-trusted-comments.sh` (`is-trusted-author`, `--json`) as the single source of trust truth; only `OWNER` / `MEMBER` / `COLLABORATOR` survive, so a later planted plan never overrides the operator's (trust dominates recency). The raw `gh issue view --json comments` pipe is blocked by `enforce-comment-trust.py` (#549).
- The old Step 1 fence had to run as a SINGLE bash command because `COMMENTS_JSON` / `PLAN` died across Bash calls (#1253); the helper makes that moot and prints the plan, so the evaluator reads it off stdout. Its `COMMENTS_JSON=`..`PLAN=` core stays byte-identical with the other two fetch sites (`tests/test-stage-plan-fetch-blocks.sh`, #1251/#1315); the issue fetch sits outside the sentinels as a stage-local line.

## Review rules

- README anchor guard (#397, #404): anchored `*.md#anchor` links in README are banned by `tests/test-readme-current.sh`, so a plan prescribing one is a Revise.
- Exact-match guard sweep (#1200): the mechanical sweep replaced an improvised `grep`; labels are fetched mechanically rather than inferred from the title because the path letter decides whether the plan carries a test deliverable. The helper never sources `pipeline.config`, so test roots are threaded explicitly; an unset var self-defaults to `tests/` and is never vacuous (#1300).
- Executable verification (#1218): guard claims are executed with a negative control, never read; divergence between prediction and observation is blocking.
- Existing-artifacts scope (#1462): at plan time only existing artifacts and proposed REDs against HEAD are executed; proposed artifacts are `not-executed: proposed artifact`.
- Scratch fixtures (#1335): fixtures live under `.claude/scratch/` and are removed by literal path only, to pass the deletion guard.

## Verdict

- Verbatim prescription (#1317): a Revise names file + what to add, remove or replace so the next planner can apply it without interpretation; round ≥2 checks only that it landed.
- `**Scope:**` line (#1435): `structural` means the approach, task split or file set is wrong; `patch` (the default) means the recommendations apply directly as amendments. The prose sits under the `**Revise scope:**` anchor, held to a 60-word budget by `tests/test-artifact-terseness-directives.sh`.
- Annotate amendments (#1440): under the default `PIPELINE_PLAN_GATE=annotate` a Revise is never folded back into the plan comment, so its Recommendations bind the executor as amendments to the plan of record.
