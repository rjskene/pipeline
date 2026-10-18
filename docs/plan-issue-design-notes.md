# Plan-issue design notes — retired rationale

`skills/plan-issue/SKILL.md` and `references/classification.md` carry rules only. This file keeps the history and rationale #1514 cut from them: one bullet per retired paragraph, with the issue that motivated it. Nothing here is a contract; the skill, the `scripts/plan-issue-*.sh` helpers and the tests are.

## Structure (#1514)

- Every multi-command bash fence became one helper call: `plan-issue-trust-gate.sh` (Step 0a), `plan-issue-context.sh` (Step 3a/4a inputs), `plan-issue-classify.sh` (`freshness`, `marker`, `hint`, `decide`, `label-apply`, `verify-post`). The `BEGIN-CLASS-FRESHNESS`, `BEGIN-PATH-MARKER-PARSE`, `BEGIN-PATH-DECIDE` and `BEGIN-LABEL-APPLY` sentinel blocks moved into `plan-issue-classify.sh` as top-level statements so the extract-and-run tests still execute them; `BEGIN-PATH-HINT-PARSE` stays in the reference as one command.
- `tests/test-plan-issue-mass-budget.sh` pins the budget: body ≤1900 words, reference ≤1500, zero citations, one command per fence.
- The classify freshness and decide subcommands read `TRUSTED` from env when set (classify-issue's `$TRUSTED` contract) and fetch it via `filter-trusted-comments.sh` otherwise.

## Trust

- All comment reads go through `filter-trusted-comments.sh`, the single trust primitive (#545); plan-issue's trusted working set came from #546.
- The opener-association gate resolves `author_association` over REST because `gh issue view --json author` exposes only `{login,name,id}` (#546).
- The refusal is routed through `refuse-untrusted-opener.sh` so re-runs never accumulate duplicate triage comments and the issue leaves the ready bucket via the `human` label (#1196, #1184).
- Pipeline-posted `## Implementation Plan` / `## Classification` comments are OWNER-authored, so the cache-check and recommended_path fallback survive the filter (#546).

## Classification

- Classification folded into plan-issue step 3a; the fullsend lane no longer dispatches a separate classify agent, and the procedure lives once in `references/classification.md` (#1485).
- Same-second classify + label bump is fresh: the freshness compare is `>=`, not strict `>` (#457).
- The high-uncertainty carve-out is a semantic judgment, not a substring grep (`authoring` is not `auth`); mechanical callers use the word-bound `_high-uncertainty-match.sh` (#1039).
- The blast-radius B→D prior was calibrated on mined exemplars: #691 and #667 (1 src + test → D), #656 (script + config + test → D), #698 (3 src + tests → B boundary) (#707).
- The escalation backstop makes a wrong B→D down-route cheap and recoverable, which is what lets classification lean D (#700, #707).
- Markers and hints quoted in code spans or fenced blocks are documentation, not claims (#1500).
- The advisory path hint from create-issues is a prior, never an override (#759).

## Diagnosis

- The `needs-debug` / `--debug-first` gate establishes the root cause before planning; `--debug-first` is per-invocation only, mirroring `/pipeline:status`'s prose-argv flags (#997).
- The gate spells out the 4-step diagnosis inline since the external debugging skill invocation was removed (#1419).

## Plan shape

- The executor-capability rule exists because a leaf `tdd-implementer` has no `Skill`/`Agent` tool; a task needing one is owned by the PR-opening role (#1225).
- The exact-match guard sweep makes the plan declare the keyset/literal tests it breaks, so the executor never stalls on an unsanctioned red test (#1200).
- README uses file-level links only; anchored `*.md#anchor` references are banned (#397, #404).
- Round ≥2 re-plans apply the evaluator's prescription verbatim — evaluators had been widening scope every round (#1317).
- PATH C Task N is never a leaf task; the orchestrator runs the self-check after reassembly (#1225).

## Posting

- The planner posts its own plan via `post-plan.sh`; returning the plan body in chat stranded plans under `general-purpose` dispatch, so the dispatch site carries the terminal contract verbatim (#326).
- Plans are written with the `Write` tool, never a heredoc: hooks text-scan Bash commands (a `gh pr create` in plan prose without `--base` is denied) and an unquoted heredoc expands `$` and backticks.
- Attachments are fetched through `filter-trusted-comments.sh fetch-attachments` because the enforce-comment-trust hook denies a direct `fetch-issue-attachments.sh` call (#1340).
