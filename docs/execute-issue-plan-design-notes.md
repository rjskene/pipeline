# execute-issue-plan design notes — retired rationale

`skills/execute-issue-plan/SKILL.md` carries rules only. This file keeps the history and rationale that #1516 cut from it: one bullet per retired paragraph, with the issue that motivated it. Nothing here is a contract; the skill, its `references/`, the `scripts/execute-issue-plan-*.sh` helpers and the tests are.

## Structure (#1516)

- The body went from ≈3930 to ≤2000 words (floor 1500) and the references from ≈1520 to ≤800. `tests/test-execute-issue-plan-mass-budget.sh` pins the budget, zero `#NNN` citations in body and references, and one command per bash fence.
- Two multi-command fences became helpers that answer `--help`: `execute-issue-plan-fetch-plan.sh` (Step 1) and `execute-issue-plan-pre-pr.sh` (Step 9a). Fence text moved verbatim; ABORT/STOP strings and exit semantics are unchanged minus citations.
- 9a now ends with `PR_TITLE=<title>` and 9b takes the title literally, so the two steps no longer depend on shell state surviving across Bash calls.
- 9b keeps `gh pr create` in the body, not a helper, so the PreToolUse `enforce-base-branch.py` and `check-ci-skip-markers` layers still see `--base` and `--title`. It keeps the heredoc `--body`, not `--body-file`: `hooks/check-ci-skip-markers.py` scans heredoc and inline bodies but never a body file written by the Write tool. The `if [ -z "$PIPELINE_BASE_BRANCH" ]` guard sits directly above the `gh pr create \` continuation with its `exit 1` (pinned by `tests/test-execute-issue-plan-base-discipline.sh`), and the one-command fence check treats a heredoc body plus its `)"` closer as part of the enclosing command.
- The derive-pr-title rule table was dropped from the body; `scripts/derive-pr-title.sh` is its source of truth.
- Step 4 / Step 10 label flips stay raw `gh issue edit` (outside the `transition-issue.sh` tripwire scope). Step 3's `#5` check is behaviour, not a citation.

## Plan fetch

- Trust is delegated to `filter-trusted-comments.sh --json` (#545), the single source of trust truth; only `OWNER` / `MEMBER` / `COLLABORATOR` survive, so a later planted plan from a non-contributor never overrides the operator's (#1315).
- Selection is by anchored heading through `select-plan-comment.sh` (#1240, #1247). The raw `gh issue view --json comments` pipe is blocked by `enforce-comment-trust.py`, which made the #1247 fix inert until #1253 routed it through the trust helper.
- The old fence had to run as a SINGLE bash command because `COMMENTS_JSON` died across calls (#1253 finding 2); the helper makes that moot. The plan is printed on stdout because the executor reads it there — a port that drops the `printf` hands the executor an empty plan with no error.
- Plan amendments (#1435, #1440): under `PIPELINE_PLAN_GATE=annotate` a `Revise` evaluation is never folded back into the plan, so its `**Recommendations:**` bind. `k` counts recommendations applied, not newly applied, because under `GATE=single` or `**Scope:** structural` a re-plan already transcribed them.
- Attachments under `.claude/scratch/issue-<N>/` are mirrored into the worktree by `setup-worktree.sh` / `sync-worktrees.sh`; the executor never re-fetches them.

## Implement

- PATH C fan-out knob (#1486): PATH C runs as one inline execute agent by default; the per-leaf `tdd-implementer` fan-out sits behind `PIPELINE_PATH_C_FANOUT=true`. The delegation hook is inert with the knob off.
- Per-leaf worktrees (#896): leaves committing in one worktree raced on `index.lock` and swept each other's files into commits (#894), breaking per-target commit isolation and the per-PR CHANGELOG granularity contract. Leaf returns are ~one line each, so concurrency is bounded by orchestrator context, not a git-index cap.
- `--spawn` reverts PATH C to the `spawn-claude.sh` → `claude -p` transport (#750), the reversible escape hatch; the spawned session honors the knob and already isolates per worker.
- Collapsed PATH D is consume-or-produce (#1485): `plan-issue` classifies inline and posts both stage records, so a planner-classified D consumes them; only a pre-labelled D produces them.
- The escalation backstop (#700, #748) is what makes a wrong B→D down-route cheap: the collapsed agent aborts up to a full PATH B run instead of shipping a too-large diff through D. PATH B execute is an inline `Agent` since #748.
- PATH D drops Step 8 because `evaluate-issue-pr` is its sole external review gate; the red→green→commit gate is never skipped.
- `PIPELINE_PATH_<X>_SKILLS_EXECUTE` / `_SKILL_ARGS_EXECUTE_*` let `spawn-claude.sh` inject skills; a set `_REVIEWER_EXECUTE` is a harmless redundancy with Step 8.
- A bare `git commit` in a temp repo passes locally but fails CI with exit 128 (no global identity).

## Validate

- One verification pass at a time: concurrent runs of stub/temp-file-sharing tests collide and report spurious failures, driving retry spins (#677). An unbounded `for t in tests/test*.sh` sweep pulls in tests that may block on an interactive `read`.
- A `/tmp` read is outside the project boundary, so it is denied and the agent narrate-and-yields, stranding committed-but-unpushed work (#752, #759, #750).
- Monitor-yield ban (#912): a dispatched Agent's turn ends when it stops emitting tool calls (#838, #904), so yielding on an un-awaitable background `Monitor` strands the run.
- Never `run_in_background` a test run (#1208); the dogfood suite exceeds one Bash timeout, so it is chunked instead.
- CI is the oracle for untouched failures (#1322); the subject definition and the PR-body `## Pre-existing failures` list are cross-checked by the PR evaluator (#1329).
- The cross-cutting guards always run pre-PR (#1132): an affected-tests subset missed a diff-independent invariant in #1128.

## Pre-PR review

- The review knob (#1464, #1468) defaults off since #1482; `scripts/resolve-execute-dispatch.sh` emits `PRE_PR_REVIEW=` into the dispatch prompt.
- Step 8 owner (#1225): its `Agent(...)` dispatch needs tools a leaf executor lacks, so the PR-opening role owns it and a `tdd-implementer` leaf refuses rather than substituting a self-review.
- The reviewer description `code review #<N>` is the `capture-agent-costs.sh` attribution key (`stage=pr-eval role=review`).
- Step 8 is synchronous; any future background coordination waits via `scripts/wait-for-sentinel.sh`, never an inline poll.

## Open PR

- Pre-PR guards (#1028, #1102, #1132): one aggregator call runs the cruft and config-drift arms; its cruft arm prints `INERT:` without failing, so 9a aborts on INERT too — otherwise the #1028 guard degrades from fail-closed to fail-open.
- `--base` is quoted and guarded even without `enforce-base-branch.py`: it is the second of three defense-in-depth layers (PreToolUse hook → skill guard → eval-time `baseRefName` check in `auto-merge-gate.sh`) (#1323).
- `derive-pr-title.sh` rewrites `../` to `..⁄` (U+2044) as defense-in-depth against path-escape scanners.

## Terminal

- A lingering executor holds the worktree and a concurrency slot; a second `claude` session cannot safely run in the same worktree, so evaluation blocks (#631).

## Constraints

- Explicit staging (#1015, #1028): `git add -A|.|-u` swept untracked `.claude/migration-cleanup-*` scanner output into a branch.
- Git anchoring (#1106): a RED commit landed on `staging` because an initial `cd <worktree>` did not hold for the later `git commit`.
- Worktree-index staging (#1122): a bare `git add` hit the MAIN checkout index, blocking the inter-leg `git pull --ff-only`; fullsend's `verify-execute-completion.sh --clean-main` recovers, the skill rule prevents.
- No hypothesised concurrent writer (#1262): inventing a race to explain one's own unanchored write sends the operator hunting a race that does not exist.
- The unbounded-poll ban is enforced in CI by the `check-unbounded-sentinel-polls` lint.

## References

- `references/pre-pr-review-loop.md` (Step 8), `references/path-c-per-leaf-worktrees.md` (PATH C fan-out), `references/collapsed-inline-d.md` (PATH D), `references/ci-fix-mode.md` (Step 0b) were cut to rules with the same anchors.
