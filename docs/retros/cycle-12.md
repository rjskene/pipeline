cycle-issues: 
pending-verdicts: 1341 1340 1339
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 21
friction: harness-friction-window = tracker cycle 11 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: fullsend Step 1a fence + the cycle-10 comment say the direct `fetch-issue-attachments.sh` call is hard-denied | the exact fence (env assignments, `\`-newline continuation, then `bash …/fetch-issue-attachments.sh`) ran un-denied — `command_mask.segments()` keeps the continuation as the head word; the same shape bypasses `enforce-base-branch.py` (filed #1342) (orchestrator)
HARNESS-FRICTION: plan-waves.sh --stage=execute serialized #1339 → #1340 on `tests/test-cage-invariant-enforce-comment-trust.sh` | #1339 never names that file — its body's `tests/*.sh` glob literal was expanded against the corpus (#54 class); three waves for three disjoint issues (orchestrator)
HARNESS-FRICTION: evolve SKILL Step 5 says the PostToolUse hook sees no usage since `Agent` dispatches are async | with `run_in_background:false` the hook captures a `source=forward` row and the backfill adds a `source=retroactive` row for the same agent_id under a different record_key — every `--post` cost row this cycle is 2× (backlog #70) (orchestrator)
HARNESS-FRICTION: dispatch directive requires the leaf report to end with `HARNESS-FRICTION:` lines | the #1340 `pipeline:tdd-implementer` report carried none at all (backlog #71) (orchestrator)
HARNESS-FRICTION: none observed — Boot fence, trust gate, marker/hint parsers, BEGIN-LABEL-APPLY, and verify step all behaved as documented. (#1341 classify)
HARNESS-FRICTION: plan-issue SKILL.md Step 3b says run `fetch-issue-attachments.sh <N>` for interactive single-issue planning | `hooks/enforce-comment-trust.py` BLOCKS that exact call ("direct fetch-issue-attachments.sh bypasses the comment-trust filter"), so the documented step cannot execute from plan-issue (#1341 plan)
HARNESS-FRICTION: `restrict_paths.py` — "path outside project boundary: /" | tripped by a `` `/tmp` `` literal inside a heredoc string and separately by the `"$S"/` trailing-slash form; neither was a filesystem access. (#1341 plan-eval)
HARNESS-FRICTION: skill fixture bullet says `rm -rf .claude/scratch/<name>` literal, never a variable | confirmed live — `block_deletions.py` denied `rm -rf "$S"`; the plan's own item-2 fix (`$PWD`-anchored mktemp) is consistent with this carve-out. (#1341 plan-eval)
HARNESS-FRICTION: none — doc/skill/hook claims matched observed behavior throughout. (#1339 execute)
HARNESS-FRICTION: skill says "Clean up literally: `rm -rf .claude/scratch/<name>`, never a variable" | `block_deletions.py` blocks `rm -rf "$VAR"` even for scratch paths — the doc is right, but the block message doesn't say that a literal path would be allowed, so the first attempt costs a retry. (#1339 pr-eval)
HARNESS-FRICTION: skill fixture bullet says `mktemp -d -p .claude/scratch` | relative `-p` yields a relative `$W`, which breaks `git remote add origin "$W/origin.git"` (resolved relative to the fixture repo) — needs `-p "$PWD/.claude/scratch"`. (#1339 pr-eval)
HARNESS-FRICTION: caller said the two fence rewrites must be net ≤ 0 words each | plan-prescribed rewrite is inherently +1 token per site (`fetch-attachments`); prose delta 0 — `≤ 0` is unsatisfiable as a strict token count under the plan's own text (#1340 pr-eval)
HARNESS-FRICTION: `fetch-issue-attachments.sh` header says it refuses to run without `PIPELINE_PROJECT_ROOT` (worktree-side guard) | invoked bare from the worktree with the var unset, it still ran (`pipeline.config` in cwd supplies the var); guard is vacuous under dogfood, pre-existing, not this PR's scope (#1340 pr-eval)
HARNESS-FRICTION: skill Step 11.2 says `no-log-dir`/`unresolvable-root` are the expected worktree outcomes for the capability-refusal resolver | resolved fine (`SOURCES=resolved`) from the worktree — no friction, but the prose over-warns (#1340 pr-eval)
HARNESS-FRICTION: plan listed nine prose-pin tests as the full pin set and said no trim phrase is a pinned needle | `tests/test-evaluator-executable-verification-prose.sh` (unlisted) pins the whole `## Executable verification` block byte-identical across both evaluators, so the plan-eval-only L54 trim was a confirmed failure under `--changed-only` (#1341 execute)
HARNESS-FRICTION: plan's fullsend baseline is 14640 and Task 4 targets ≤ 14640 | worktree base 5c3e67b (post-#1340) measures 14641; edits still landed at 14632 (under both) (#1341 execute)
HARNESS-FRICTION: plan cites Step 8 as L239-243 (31 words) | the block starts at L238 (heading) and is 39 words; the plan's "replace the whole Step 8 block" intent was unambiguous, so no effect (#1341 execute)
HARNESS-FRICTION: plan's Task 4 anchor `**Friction capture:**` is described as an L345 insertion point | the string occurs 3× in fullsend/SKILL.md; needed the preceding "...hunting a race that does not exist." as a disambiguating anchor (#1341 execute)
HARNESS-FRICTION: execute-issue-plan Step 8b prescribes `Agent(subagent_type: "superpowers:code-reviewer")` | no such agent type is registered in this session; dispatched `general-purpose` with the superpowers `code-reviewer.md` template instead (#1341 execute)
HARNESS-FRICTION: `run-test-suite.sh --changed-only` reported `test-path-b-default-split-role.sh` as a parallel-pass flake (RECOVERED on retry) in both runs | passes serially; unrelated to this diff but adds noise to every changed-only run that selects it (#1341 execute)
HARNESS-FRICTION: plan Task 4 states fullsend baseline `wc -w` = 14640 | actual base count at `5c3e67b` was 14641 (harmless; head 14632 still under either). (#1341 pr-eval)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words 47 (baseline 56300 -> computed 56347)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 14 -> computed 14)
delta issue-number archaeology in skill bodies/refs 0 (baseline 352 -> computed 352)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 0 (baseline 187 -> computed 187)
delta harness mass/scripts 0 (baseline 91 -> computed 91)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it); cycle 8: 2 (#1323 CI-red placeholder-grep test the executor mis-classed as pre-existing; #1321 three fail-closed regressions — `\rm` alias bypass, `xargs`-wrapped rm, brace/glob tmp targets — CI green, cage tests blind to them); cycle 9: 1 (#1327 `command_mask` import not co-located in the phase2-coexistence sandbox copy — CI red, executor mis-classed the test as pre-existing, the #53 class again); cycle 10: 2 (#1334 CI-red head from a scanner guard its own `--changed-only` run skipped — the guard's regex began with `-c` and grep had parsed it as an option, dead code on every prior run; and the `${CLAUDE_PLUGIN_ROOT:-.}` form in the rewritten Step 6b diffing the MAIN tree under dogfood — a proven false green `selected=0/442`, fixed with a `$PWD` anchor); cycle 11: 1 (#1339 fixture scanner test self-tripped on its own `SCANNERMARK` grep — scenario 11's `RESULT=fail` discriminated only by glob order; CI green, fixed `177503c` pre-merge)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): 5 (cycle 11: plan-issue Step 3b denied call — fixed by #1340; Step 8b `superpowers:code-reviewer` unregistered — backlog #6; relative `mktemp -p` — fixed by #1341; Step 11.2 over-warns worktree outcomes; evolve SKILL Step 5 "async dispatch → hook sees no usage" false under `run_in_background:false`)
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 17.0M dedup'd by agent_id (cycle 11: #1339 14.9M D collapsed, exec 58 tool uses/10.5M · #1340 17.0M D collapsed, exec 66/12.7M · #1341 21.2M A, plan 45 + plan-eval 28 + exec 35 + pr-eval 23; `run-retro.sh --post` printed 2× these — `forward` + `retroactive` rows per agent, backlog #70). Cycle 10 dedup'd: 23.4M (#1334 B row 43.2M, not 50.9M — its classify/plan/plan-eval rows were also doubled); cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=1% seven_day=61% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 46 -> computed 46)
prev-delta harness mass/words 0 (previous 56347 -> computed 56347)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 80720 -> computed 80720)
prev-delta harness mass/hooks loc 0 (previous 4466 -> computed 4466)
prev-delta harness mass/scripts loc 0 (previous 23272 -> computed 23272)
prev-delta harness mass/hooks 0 (previous 14 -> computed 14)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 352 -> computed 352)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 137 -> computed 137)
prev-delta harness mass/tests 0 (previous 444 -> computed 444)
prev-delta prose-pinning tests/grep skill.md 0 (previous 187 -> computed 187)
prev-delta harness mass/scripts 0 (previous 91 -> computed 91)

## Diagnose

Verdicts at Step 2 — `run-retro.sh` printed `pending-verdicts: 1341 1340 1339`. All three merged in cycle 11's three SERIAL waves, so the post-merge exposure inside cycle 11 is partial (#1339: two downstream agents; #1340: zero plan-issue dispatches after merge; #1341: zero agents). Criteria set here, resolved in `## Post` with cycle-12 data (the cycle-9/10/11 pattern):

- **#1339** (`--changed-only` selects scanner/sweep tests) — provisional **confirmed** on cycle-11 evidence: the #1340 and #1341 executors ran under the fix; 0 CI-red heads from a skipped test (cycle 10: 1), and the #1341 executor's `--changed-only` run surfaced the unlisted byte-identical pin test (`test-evaluator-executable-verification-prose.sh`) — selection working as designed. Final criterion: CI-red heads from a test `--changed-only` skipped = 0 across the cycle-12 slate.
- **#1340** (`filter-trusted-comments.sh fetch-attachments` as the sanctioned attachment entry) — criterion: `enforce-comment-trust` true-positive denial lines on the attachment path 2/cycle (cycles 7–11) → 0; fullsend Step 1a and plan-issue Step 3b run un-denied BY DESIGN (helper form), not by the #1342 continuation accident — the orchestrator runs Step 1a exactly as the fence reads. Note the confound: until #1342 lands, a `\`-continuation shape would also pass; the measure is the single-line helper form.
- **#1341** (rebase only when not MERGEABLE · `$PWD`-anchored scratch fixtures · inherited-`CLAUDE_PLUGIN_ROOT` clause) — criterion: the three classes 6 lines (cycle 10) → 0 in cycle 12; `doc/behaviour contradictions` row 5 → ≤ 2.

Backlog re-rank (friction 20 lines in cycle 11; classes: prose-vs-plan drift 6, orchestrator-observed harness defects 4, hook-message residue 4, known TP 1, restrict_paths FP 1, vacuous guard 1, flake 1, missing leaf tail 1, `none` 2):

1. **#1342 → D (already filed, cycle 11)** — `command_mask.segments()` keeps a `\`+newline continuation as the head word, so `enforce-base-branch.py` / `enforce-comment-trust.py` allow `ENV=x \⏎ gh pr create --base main` and `ENV=x \⏎ gh issue view --json body,comments` (rc 0; single-line → rc 2). A live guard bypass on two of three mask-based hooks; +≤ 15 hook LOC, non-cage tests only.
2. **#70 → D** — every `run-retro.sh --post` cost row is 2×: the PostToolUse hook writes a `source=forward` row for a synchronous `Agent` (`run_in_background:false` — it DOES see usage) and the backfill adds a `source=retroactive` row for the same `agent_id` under a different `record_key`. Verified in the live log: 9/9 cycle-11 agents have a forward+retroactive pair with identical `agent_id` (e.g. #1339 execute `acadf3cd` 10.5M ×2). `cost-latency-report.sh` L847 already collapses pairs by `agent_id` (#880); `run-retro.sh` L672 dedups on `record_key` only. Fix = mirror the #880 collapse in the retro rollup + correct the evolve SKILL Step 5 "async → no usage" clause. Until then no cost verdict is trustworthy.
3. **#54 → D** — root cause found: `plan-waves.sh` L248/L249/L252 iterate `${FILES[$N]}` / `${WAVE_FILES[$WAVE]}` UNQUOTED, so a body token like `tests/<star>.sh` (passes `FILE_PATH_RE`, slash-shaped) is pathname-expanded against the orchestrator cwd at comparison time — cycle 11 turned #1339's glob literal into every test file and serialized #1339 → #1340 on a cage test #1339 never names; three waves for three disjoint issues (fullsend 69 min). Second shape (cycle 8, #1323): a "do NOT change `<file>`" mention counts as an edge. Fix = `set -f` at the top of `plan-waves.sh` + drop glob-metachar tokens in `_extract-body-paths.sh` + skip negated-mention lines; tests for each. Metric: wall-clock — waves for disjoint slates N → 1.
4. #67 (D, capability-refusal WARN on every inline eval), #68 (D, `setup-worktree.sh` unbound `PIPELINE_SYNC` knobs under `set -u`), #69 (D, `--reset` leaves stale sandbox worktrees), #6 (A, `superpowers:code-reviewer` ref — held one cycle so #1341's contradictions-row measure stays unconfounded), #71 (A, leaf report tail), #63, #62, #39.

Slate for cycle 12 — 3 D, 0 A, 0 C. File sets: `hooks/command_mask.py` + 4 non-cage tests · `scripts/run-retro.sh` + its cost-rows test/fixture + evolve SKILL Step 5 · `scripts/plan-waves.sh` + `scripts/_extract-body-paths.sh` + plan-waves tests. Disjoint by construction — and the #54 and #70 bodies carry no glob literal, so the pre-fix planner cannot manufacture an edge against #1342's `tests/test-cage-invariant-` glob.

Why this slate: #1342 is a fail-open guard defect (the only escape class filed this loop that weakens a hard-deny); #70 restores the loop's own cost instrument before any further cost verdict is written; #54 recurred in two cycles and is the largest wall-clock lever the loop has (3 serial waves → 1 for disjoint slates). #1339/#1340/#1341 are measured, not touched.

Dispatch discipline this cycle: Step 1a run verbatim from the fence (measures #1340); no rebase coaching (measures #1341); `git merge --ff-only origin/evolve` in the main checkout after the wave and prune merged worktrees before Step 5; dispatch prompts say "resolve `CLAUDE_PLUGIN_ROOT` from the worktree via the Boot fence in the same call".

## Post

Cycle 12 — interactive session (`/pipeline:evolve start --cycles 1`, `PIPELINE_HEADLESS=true` in config), 2026-09-15 09:14 → 09:50 UTC (≈ 36 min loop / ≈ 24 min fullsend, 09:20 → 09:44). 3/3 merged, all auto-merged by the evaluator: #1342 D → PR #1348 `a377ea5` (evaluator fix `23da13e`) · #1346 D → PR #1349 `1ec8d6e` (evaluator fix `02a9778`) · #1347 D → PR #1350 `0c3c3ba` (evaluator fix `391226d`). ONE wave, three parallel collapsed-D executors (sonnet, `REASON=default-sonnet`) then three parallel opus evaluators; plan-waves found no shared file (the bodies carried no glob literal by construction — the base planner still emitted `tests/test-cage-invariant-*.sh` as an edge for #1342 and #1347's own `docs/??.md` / `src/[ab].py` examples as edges, harmless because nothing else named them).

### Step 5 output (`run-retro.sh --post`)

COMPUTED prose-pinning tests/grep claude.md = 46
COMPUTED harness mass/words = 56347
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 80891
COMPUTED harness mass/hooks loc = 4475
COMPUTED harness mass/scripts loc = 23318
COMPUTED harness mass/hooks = 14
COMPUTED issue-number archaeology in skill bodies/refs = 352
COMPUTED issue-number archaeology in skill bodies/distinct = 137
COMPUTED harness mass/tests = 444
COMPUTED prose-pinning tests/grep skill.md = 187
COMPUTED harness mass/scripts = 91
COMPUTED escapes/hotfix = 0
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 0
COMPUTED friction/hotfix = 0
COMPUTED escapes/later-fix = 0
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/harness-friction-window = cycle 12 issue comments
COMPUTED friction/denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
cost: issue=#1342 tokens=11417032 stages=2
cost: issue=#1346 tokens=10675945 stages=2
cost: issue=#1347 tokens=12844531 stages=2
cost: loop-own tokens/issue median = 11417032
cost: backfill = ran
verdict-candidates: 1347 1346 1342

Cost rows are instrument-true for the first time (#1346 live in the merged tree): each row equals Σ max-per-`agent_id` over the forward/retroactive pair, verified against the raw log — #1342 6,649,043 + 4,767,989 = 11,417,032 · #1346 5,315,995 + 5,359,950 = 10,675,945 · #1347 6,190,350 + 6,654,181 = 12,844,531 → **loop-own median 11.4M** (cycle 11 hand-dedup'd 17.0M; the cycle-11 retro's #1341 figure 21.2M was a forward-row lower bound — the collapse gives 21.41M). Executors: 51 / 53 / 52 tool uses, 376 / 468 / 505 s, 6.6M / 5.3M / 6.2M. Evaluators: 30 / 31 / 29 tool uses, 565 / 653 / 686 s, 4.8M / 5.4M / 6.7M — each carrying one fix + RED proof against a scratch copy of the base scripts.

Mass: words 56347 → 56347 (0; #1346's SKILL.md edit 2265 → 2265) · scripts 91 (+46 LOC: `run-retro.sh` +14, `_extract-body-paths.sh` + `plan-waves.sh` +32 — #1347 over its ≤ 30 by 2) · hooks 14 / 4475 LOC (+9, #1342 under ≤ 15) · tests 444 (+171 LOC: #1342 +80, #1346 +18 net, #1347 +120 — over its ≤ 80; no new files). Escapes: hotfix 0, revert 0, later-fix 0. Gate yield: **3 real defects fixed pre-merge**, all CI green and test-blind — #1342 pinned only one of the issue's two comment-trust shapes (the Step 1a fetch-attachments continuation was unpinned; Case Y); #1346's two `refute_sub` median controls went vacuous when the fixture grew (re-pinned to the real script's 65M/80M); #1347's `bp_drop_negated_lines` `else if` let a line with both cues keep its path (B11). Weak-model pass: n/a (no calibration run this cycle). Fixtures left behind: 0 under `.claude/scratch/` (only the loop's own `evolve-*.md` drafts and the sanctioned `plan-drafts/`).

Hook denials (real): 1 — `block_deletions.py` denied the orchestrator's Step 6 tracker-edit call because a NEW backlog entry's prose spelled the recursive-rm pattern inside a python heredoc (the #45 class, third occurrence; reworded). Zero agent-side denials reported. `restrict_paths` 0. `enforce-comment-trust` 0 — Step 1a ran un-denied in the #1340 helper form.

### Verdicts

- **#1339 — confirmed.** CI-red heads caused by a test `--changed-only` skipped: 1 (cycle 10) → 0 (cycle 11, 2 executors under the fix) → **0 (cycle 12, 3 executors; every head CI green)**. The #1341 executor's run in cycle 11 also proved selection of an unlisted byte-identical pin test.
- **#1340 — confirmed.** `enforce-comment-trust` true-positive lines on the attachment path: 2/cycle (cycles 7–10) → 1 (cycle 11, the pre-merge plan-issue dispatch) → **0**; fullsend Step 1a ran verbatim in the helper form and was allowed BY DESIGN (the #1342 continuation accident is now closed too, so the single-line and continuation forms of the raw call are both denied — Case Y). plan-issue Step 3b was not exercised (D-only slate).
- **#1341 — confirmed.** rebase-on-MERGEABLE / relative-`mktemp -p` / inherited-`CLAUDE_PLUGIN_ROOT` lines: 6 (cycle 10) → **0** (all three evaluators: "MERGEABLE/CLEAN, no rebase"; scratch fixtures `$PWD`-anchored; every agent resolved the root from its worktree). `doc/behaviour contradictions` row 5 → **2** (Step 11.2 over-warn — third cycle, folded into #67; Step 8 three-dot diff direction — new #72). The rate model (#66) holds: two new shapes per cycle, the standing sweep stays.
- Pending (retro next cycle): #1342 (guard false negatives on continuation shapes 2 hooks → 0 — proven by Case P/X/Y + RED against the base mask; formal verdict cycle 13), #1346 (cost rows trustworthy — already true this cycle; formal verdict cycle 13 on the first cycle whose retro runs entirely under it), #1347 (wall-clock: waves for a disjoint slate → 1 in cycle 13; this cycle's single wave predates the fix).

### Friction (10 lines; cycle 11: 20)

Classes: dispatch-prompt drift by the ORCHESTRATOR 3 (#1346's "21.2M" was the retro's lower-bound figure; #1347's "base emits all four glob tokens" was true only before the executor posted its plan; "poll ~10 s for the rollup" did not recur) · doc/behaviour contradictions 2 (Step 11.2 over-warn, third cycle → #67; Step 8 three-dot diff direction → #72) · prose-vs-plan drift 1 (#1342 PR body "the continuation shape", singular, vs two issue shapes — caught and fixed by the evaluator) · hook-message/prose residue 1 (fixture re-creation vs the literal-path rule → #73) · orchestrator-observed 2 (fullsend `## Wave plan` says edges come from "body-substring grep" while `--stage=execute` prefers the plan comment's **Files to change:** and falls back to the body only for plan-less issues — for a D-only slate the Pass A/B edges are ALWAYS body-derived because the plans do not exist yet; `block_deletions` heredoc-prose denial, #45) · `none` 3 (all three executors — the #71 tail contract was met by every leaf this cycle, dispatch-site directive made explicit).

### Cycle-13 candidates

#67 (D, capability-refusal WARN + Step 11.2 over-warn — 3 cycles) · #72 (A, Step 8 diff direction) · #73 (D, `block_deletions` message + fixture recipe) · #6 (A, `superpowers:code-reviewer` ref — held two cycles) · #68 (D, `setup-worktree.sh` unbound knobs) · #69 (D, `--reset` stale sandbox worktrees) · #71 (A, tdd-implementer frontmatter tail rule — met by directive this cycle, still unpinned in the agent file). Verdict data needed: #1347 wants a ≥ 2-issue slate whose bodies name overlapping-but-unshared paths or globs; #1342 wants one run of the continuation shape under the merged hooks (any dispatch fence with a `\`-newline).
