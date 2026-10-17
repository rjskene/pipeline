# Fullsend design notes — retired rationale

`skills/fullsend/SKILL.md` and its `references/` carry rules only. This file keeps the history and rationale that #1492 cut from them: one bullet per retired paragraph, with the issue that motivated it. Nothing here is a contract; the skill, the `scripts/fullsend-*.sh` helpers and the tests are.

## Structure (#1492)

- Every multi-command bash fence became a `scripts/fullsend-*.sh` helper that takes the wave's issue numbers and answers `--help`: fetch-attachments, approve, preflight, gate, merge-green, block-merge, dispatch-specs, release-prs, merge-order. The shared fail-closed PR derivation lives in `scripts/_fullsend-resolve-pr.sh`.
- `references/pr-eval-dispatch.md` folded into SKILL.md Step 7 (`**PR-eval invocation mode.**`), `references/scoped-halt.md` into `### Scoped halt-and-report`, and `references/merge-orchestration.md` into `## Merge orchestration (reference)`.
- `## Usage gate (#969)` became `## Usage gate`. `tests/test-fullsend-mass-budget.sh` pins the budget: body ≤4000 words, references ≤5000, zero citations, one command per fence.

## Entry point and slate

- Attachments are fetched through `filter-trusted-comments.sh fetch-attachments` because the enforce-comment-trust hook denies a direct `fetch-issue-attachments.sh` call (#1340).
- Classify runs inside plan-issue, so fullsend dispatches no classify Agent; a pre-labelled PATH D produces its own classification in the collapsed agent (#1485).
- `--debug-first` reaches the planner only through the dispatch prompt; the durable `needs-debug` label needs no propagation (#997).
- Empty `PIPELINE_PROJECT_ROOT` falls back to the Bash tool's cwd in the Boot fence (#1215).

## Plan stages

- Every stage dispatch is pinned through `resolve-stage-model.sh` because an unpinned dispatch inherits the session model, which under a Fable-ceiling session is Fable (#1186).
- `plan-eval` follows its producer's tier so a gate never sits below what it checks (#1186).
- The lean trust profile skips plan-eval for non-W2 PATH A/D only (#1291, narrowed by #1420).
- Plan gates `single`/`none` (#1429) and `annotate` (#1435) exist to cut re-plan rounds; annotate carries Revise recommendations into execute as binding amendments, except `**Scope:** structural`.
- The binding re-plan rule (quote the prescription verbatim, verify only that it landed) stopped evaluators widening scope every round (#1317).
- Plan-lifecycle flips go through `transition-issue.sh`, never raw `--add-label` (lifecycle-flip guard).

## Execute

- Execute runs wave by wave, cut from `origin/<base>`'s tip with an explicit `--base`. The pre-#1214 `checkout` + `pull --ff-only` pair stranded operator work, so the refresh became fetch-only (#626, #1214).
- `setup-worktree.sh` rejects a bare issue number (#350). Next-branch routing applies only to issues labelled `next` (#1128, #1148).
- PATH D went inline first (#700), PATH B joined (#748), then PATH C (#749/#891/#896). The run-queue is used only under `--spawn` (#750). PATH C fan-out is opt-in via `PIPELINE_PATH_C_FANOUT` (#1486).
- Per-leaf worktrees fixed the #894 shared-index race (transient `index.lock`, one leaf's files folded into another's commit); the #892/#894 live branch test run with `--manual-merge` cleared the inline-C merge gate (#896).
- One execute agent is the only shape; the two-phase split-role lane was retired (#1420). It runs the full suite before `gh pr create` because CI was catching breaks in tests the task never ran (#1108).
- The dispatch-site prompt is the binding contract because a `general-purpose` subagent never loads the skill body; narrate-and-yield ("I'll wait for the suite") strands committed work (#752, #764, #765, #771, #838, #904).
- Explicit-path staging and the cruft guard (#1028); cross-cutting guards always run pre-PR, even when only touched tests ran (#1128, #1132).
- The closing-review directive is keyed off the resolver's `PRE_PR_REVIEW=` because an unconditional MUST overrode the knob in calibration 24 (#1387, #1474).
- Git anchoring and the branch assert exist because an unanchored commit landed a RED commit on `staging` (#1106). Worktree-index staging fixes the main-index leak from a bare `git add` (#1122).
- Test runs are never backgrounded: a dropped-out agent resumed with "run everything in the foreground" dropped out again (#1208).
- "No hypothesised concurrent writer" — agents blamed a phantom race for their own unanchored commands (#1262).
- `${CLAUDE_PLUGIN_ROOT}` is valid only after the Boot fence; under dogfood the inherited value is the main checkout (#1341).
- Per-dispatch clean-main attribution names the leaking agent, which the wave-boundary check cannot (#1262). It never stashes untracked paths, because `stash -u` swept operator files (#1207).
- Stall events need idle CPU and a frozen pane (#641); `manual-merge-required` frees an evaluator slot (#489); `reason=block-verdict` means the evaluator flagged the PR (#654).
- Post-dispatch verification is the orchestrator-side backstop for the inline batch, which has no runner reap (#636, #666, #764, #814, #838, #904). The no-re-ask rule and the escalation ladder come from #1208.
- `--verify-dispatch` surfaces a silent model regression: every PATH B/D execute had inherited Opus while config said Sonnet (#1042, #1056); it was widened to A/C and the stage dispatches (#1186). `COST=miss` flags unattributed rows (#1387).
- Every dispatch description carries `#<N>` so cost attributes to the issue (#1299, #1387). `pipeline:tdd-implementer` must be namespaced; the bare name hard-failed the PATH D dispatch (#1238, #1262).
- Execute models default to `opus` on every path (#1420, #1428). The W2 high-uncertainty carve-out reuses the shared word-bound regex (#1039). The PATH B low-blast lane is an estimate (#955).

## CI, PR-eval and merge

- The CI-fix gate uses colon-less fallbacks so an explicit empty value turns it off (#858). Issue→PR resolution never takes "latest open PR" (#909).
- The preflight runs mechanical checks before any evaluator token (#1445): the body contract (#1329), the next-branch-aware base check (#1131), `PIPELINE_REPO` unset in a subshell (#801), negative-control wording that must not trip the fatal claim (#1218).
- The orchestrator, not the evaluator, fires the gate (#1444), once per wave (#1452). Batching makes later `mergeStateStatus` stale, so the merge itself is guarded (#1452).
- The capability-refusal arm reads the main checkout's logs, since a worktree has none (#1233, #1246).
- Base enforcement is layered because the PreToolUse hook alone was bypassed in production (#295, `dev/audits/295-root-cause.md`).
- An empty `WT`/`BR` would name an unrelated PR, since `git -C ""` and `gh pr list --head ""` exit 0 (#909).
- Screenshot URLs are rewritten to the merge SHA so they survive `--delete-branch` (#506, private blob form #551; opt-out restores the #383 behaviour).
- The `already closed` close error is benign: the merge auto-closes the issue (#813). Labels go through `finalize-issue-labels.sh` with an explicit `--repo` (#866, #888).
- The `manual-merge` label lets the run-queue free a slot instead of waiting 90 minutes (#489).
- `block-cage-tests-diff` stops an agent weakening the cage tests (#1304).

## Campaign and usage gate

- The fetch-only leg base advance (#626, #1214) and the leg-boundary drift guard (#1106).
- The usage read-out is advisory only (#725). The usage gate pauses or halts between waves (#969); the recurring cron replaced a turn-coupled one-shot (#1016).
- The fold wave bounds mid-campaign bug filing to one wave (#838); end-of-campaign filing is non-interactive because completion is autonomous (#863).
