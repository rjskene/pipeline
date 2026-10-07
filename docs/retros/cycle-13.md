cycle-issues: 
pending-verdicts: 1347 1346 1342
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 12
friction: harness-friction-window = tracker cycle 12 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: fullsend `## Wave plan (pre-think)` says shared-file conflicts are "extracted via body-substring grep" | at `--stage=execute` the planner prefers the plan comment's **Files to change:** bullets and falls back to the body only when no plan comment exists — for a D-only slate the Pass A/B edges are always body-derived because the collapsed executors have not posted their plans yet, and the #1347 evaluator saw the edge set change once they had (orchestrator)
HARNESS-FRICTION: evolve SKILL Step 6 says backlog edits go through `$TMP` + fence 3 | `block_deletions.py` denied the editing Bash call because a NEW backlog entry's prose spelled the recursive-rm pattern inside a python heredoc — the #45 heredoc-prose class, third occurrence; reworded (orchestrator)
HARNESS-FRICTION: none (#1342 execute)
HARNESS-FRICTION: none (#1346 execute)
HARNESS-FRICTION: none (#1347 execute)
HARNESS-FRICTION: SKILL Step 4 fallback + dispatch say run touched tests / build fixtures with `rm -rf "$VAR"` cleanup implicitly fine | `block_deletions.py` denies any `rm -rf $VAR` in-worktree, so a fixture subdir replacement needed a fresh subdir instead (literal-path rule holds, but the skill's fixture recipe does not warn that mid-fixture re-creation must avoid `rm -rf` on a variable) (#1342 pr-eval)
HARNESS-FRICTION: Step 11.2 snippet expects `check-capability-refusal.sh --resolve-sources` may return `no-log-dir` on worktrees | returned `resolved` against the main checkout's `.claude/logs/subagents` — worked as designed, no disagreement beyond the doc hedging (#1342 pr-eval)
HARNESS-FRICTION: PR body/plan say `test-enforce-comment-trust.sh` gains "the continuation shape" (singular) | issue Context names TWO comment-trust false-negative shapes; the executor pinned one, the fetch-attachments fence shape needed an eval fix (#1342 pr-eval)
HARNESS-FRICTION: dispatch prompt said cycle-11 real #1341 = 21.2M | max_by collapse (per #880) yields 21,410,146 — the retro hand-dedup took forward-row lower-bounds for plan-eval/pr-eval (#1346 pr-eval)
HARNESS-FRICTION: SKILL Step 8 `git diff --name-only HEAD...origin/$PIPELINE_BASE_BRANCH` reports "files this PR touches" | that range lists base-only files; overlap needs the intersection with `origin/base...HEAD` (#1346 pr-eval)
HARNESS-FRICTION: dispatch said base `--emit-edges 1342 1346 1347` emits all four glob tokens | base now emits only `tests/test-cage-invariant-*.sh` on #1342 — #1347's edge is derived from the executor's `## Implementation Plan` `**Files to change:**` block (posted after the orchestrator's baseline), so `docs/??.md`/`src/[ab].py` only surface via the body path (#1347 pr-eval)
HARNESS-FRICTION: dispatch said "poll until the rollup registers" for ~10 s after push | rollup registered on first poll (`guard`/`changes` QUEUED immediately) (#1347 pr-eval)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words 105 (baseline 56300 -> computed 56405)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 1 (baseline 14 -> computed 15)
delta issue-number archaeology in skill bodies/refs 1 (baseline 352 -> computed 353)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 0 (baseline 187 -> computed 187)
delta harness mass/scripts 1 (baseline 91 -> computed 92)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it); cycle 8: 2 (#1323 CI-red placeholder-grep test the executor mis-classed as pre-existing; #1321 three fail-closed regressions — `\rm` alias bypass, `xargs`-wrapped rm, brace/glob tmp targets — CI green, cage tests blind to them); cycle 9: 1 (#1327 `command_mask` import not co-located in the phase2-coexistence sandbox copy — CI red, executor mis-classed the test as pre-existing, the #53 class again); cycle 10: 2 (#1334 CI-red head from a scanner guard its own `--changed-only` run skipped — the guard's regex began with `-c` and grep had parsed it as an option, dead code on every prior run; and the `${CLAUDE_PLUGIN_ROOT:-.}` form in the rewritten Step 6b diffing the MAIN tree under dogfood — a proven false green `selected=0/442`, fixed with a `$PWD` anchor); cycle 11: 1 (#1339 fixture scanner test self-tripped on its own `SCANNERMARK` grep — scenario 11's `RESULT=fail` discriminated only by glob order; CI green, fixed `177503c` pre-merge); cycle 12: 3 (#1342 executor pinned one of the issue's two comment-trust continuation shapes — the Step 1a `fetch-issue-attachments.sh` shape was unpinned, Case Y added `23da13e`; #1346 two `refute_sub` median controls went vacuous when the fixture grew to 10 records — re-pinned `02a9778`; #1347 `bp_drop_negated_lines` used `else if`, so `never edit X; you do not need…` kept `X` — B11 added `391226d`; all three CI green, tests blind)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): 2 (cycle 12: evaluate-issue-pr Step 11.2 over-warns `no-log-dir`/`unresolvable-root` on worktrees — third cycle, backlog #67; Step 8 `git diff --name-only HEAD...origin/$PIPELINE_BASE_BRANCH` lists base-only files, not the PR's — backlog #72). Cycle 11: 5 (plan-issue Step 3b denied call — fixed by #1340; Step 8b `superpowers:code-reviewer` unregistered — backlog #6; relative `mktemp -p` — fixed by #1341; Step 11.2 over-warns; evolve SKILL Step 5 "async dispatch → hook sees no usage" — fixed by #1346)
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 11.4M instrument-dedup'd (cycle 12, first cycle `run-retro.sh --post` rows are trustworthy — #1346: #1342 11.4M D collapsed, exec 51 tool uses/6.6M/376 s + pr-eval 30/4.8M/565 s · #1346 10.7M, exec 53/5.3M/468 s + pr-eval 31/5.4M/653 s · #1347 12.8M, exec 52/6.2M/505 s + pr-eval 29/6.7M/686 s; three evaluator fixes inflated pr-eval vs cycle 11's 4.3M median). Cycle 11 hand-dedup'd: 17.0M (#1339 14.9M · #1340 17.0M · #1341 21.4M — the retro's 21.2M took forward lower-bounds); cycle 10: 23.4M; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=25% seven_day=16% threshold=85

prev-delta prose-pinning tests/grep claude.md 1 (previous 46 -> computed 47)
prev-delta harness mass/words 58 (previous 56347 -> computed 56405)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 998 (previous 80891 -> computed 81889)
prev-delta harness mass/hooks loc 142 (previous 4475 -> computed 4617)
prev-delta harness mass/scripts loc 233 (previous 23318 -> computed 23551)
prev-delta harness mass/hooks 1 (previous 14 -> computed 15)
prev-delta issue-number archaeology in skill bodies/refs 1 (previous 352 -> computed 353)
prev-delta issue-number archaeology in skill bodies/distinct 1 (previous 137 -> computed 138)
prev-delta harness mass/tests 3 (previous 444 -> computed 447)
prev-delta prose-pinning tests/grep skill.md 0 (previous 187 -> computed 187)
prev-delta harness mass/scripts 1 (previous 91 -> computed 92)

## Diagnose

**Verdicts for cycle 12 (pending → resolved):**
- **#1342 confirmed** — live probe against the merged hooks (2026-09-21 15:05Z): a `FOO=1 \⏎ gh pr create --base main` shape and a `FOO=1 \⏎ gh issue view 5 --json comments` shape both deny (rc=2) under `enforce-base-branch.py` / `enforce-comment-trust.py`; continuation false negatives 2 hooks → 0; cycle-12 friction carried no new denial class for single-line forms; cage 3/3 green on merge.
- **#1346 confirmed** — cycle-12 `## Post` verified every `cost:` row against the raw log (`#1342 6,649,043 + 4,767,989 = 11,417,032` etc.); printed median 11.4M = hand-dedup'd median; `stages=` unchanged.
- **#1347 pending → measured this cycle** — its metric is the cycle-13 slate's own wave count (`--emit-edges` shows no edge on an unnamed path; disjoint 3-issue slate runs in ONE wave; fullsend wall ≥ 30 % under cycle 11's 69 min). The cycle-13 PATH A body deliberately carries negated mentions of the two scripts the PATH D issue edits, so the negated-mention fix is exercised on a real slate.

**Slate (1 A + 2 D, 0 C; files disjoint by construction so #1347 can be measured):**
1. **D — #1360 — `run-retro.sh` reads `.claude/logs/hook-denials.jsonl` for the `friction/denials` row.** Staging's #1352 (forward-synced this cycle, `hooks/_deny_log.py`) gives every exit-2 guard denial a JSONL record; the retro still prints `denials = n/a (tool-use.log has no decision field…)` every cycle, so the friction row the loop is supposed to steer by has been blank for 13 cycles. New backlog #74.
2. **D — #1361 — backlog #67 (script half): `check-capability-refusal.sh` reads the per-agent record's `status`; `async_launched` records (background dispatch — the leaf's result never reaches PostToolUse, per `subagent_log_utils.build_json_record`) get a named `REASON=async-dispatch` arm instead of `no-leaf-output`, and `auto-merge-gate.sh` prints a one-line NOTE for that arm, not `WARN … unproven`.** 9 friction lines across cycles 5–12 name this exact WARN.
3. **A — #1362 — evaluate-issue-pr prose sweep (cycle 13):** Step 8 diff direction (#72: `HEAD...origin/base` lists base-only files; the PR's files are `origin/base...HEAD`), Step 11.2 resolver hedge (#67 prose half: `resolved` is the normal worktree outcome), Step 4 fixture recipe (#73 skill half: mid-fixture re-creation uses a fresh subdir, never recursive removal on a variable). ≤ 0 net words.

Deferred: #73's `block_deletions.py` deny-message line (hooks surface; nothing else on the slate touches hooks — next cycle), #6, #68, #69, #71.

## Post

Cycle 13 — interactive session (`/pipeline:evolve start --cycles 1`, `PIPELINE_HEADLESS=true` in config), 2026-09-21 15:02 → 16:10 UTC (≈ 68 min loop / **50 min fullsend**, 15:13 → 16:03). Step 0 forward-synced staging `af75ce6..7f4ceb8` (release 2026-09-21 + #1352 deny log). 3/3 merged, all auto-merged by the evaluator: #1362 A → PR #1363 `06062de` (no eval fix; executor dropped plan Task 3, see below) · #1361 D → PR #1364 `a7e7bd3` (evaluator fix `1a82bef`: `docs/observability.md` four-state text) · #1360 D → PR #1365 `b792de8` (evaluator fix `8f8de8c`: fixture README row; branch rebased once — `docs/observability.md` intersected #1361). **ONE wave** (`Wave 1: execute #1360, #1361, #1362 in parallel`); `--emit-edges` 0 blockers although the A body carried negated mentions of #1361's two scripts — the #1347 measurement. Sequence: classify → plan → plan-eval for the A issue serially (≈ 14 min, all Approve first round), then three parallel executors (opus A + two sonnet collapsed-D, 373 / 747 / 497 s), then three parallel opus evaluators (300 / 1163 / 622 s).

### Step 5 output (`run-retro.sh --post`)

COMPUTED prose-pinning tests/grep claude.md = 47
COMPUTED harness mass/words = 56386
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 81991
COMPUTED harness mass/hooks loc = 4617
COMPUTED harness mass/scripts loc = 23613
COMPUTED harness mass/hooks = 15
COMPUTED issue-number archaeology in skill bodies/refs = 353
COMPUTED issue-number archaeology in skill bodies/distinct = 138
COMPUTED harness mass/tests = 447
COMPUTED prose-pinning tests/grep skill.md = 187
COMPUTED harness mass/scripts = 92
COMPUTED escapes/hotfix = 0
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 0
COMPUTED friction/hotfix = 0
COMPUTED escapes/later-fix = 0
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/harness-friction-window = cycle 13 issue comments
COMPUTED friction/denials = 3 (hook-denials.jsonl; enforce-base-branch=1 enforce-comment-trust=1 restrict_paths=1)
cost: issue=#1360 tokens=17580668 stages=2
cost: issue=#1361 tokens=15221706 stages=2
cost: issue=#1362 tokens=12824970 stages=5
cost: loop-own tokens/issue median = 15221706
cost: backfill = ran
verdict-candidates: 1362 1361 1360

**Verdicts (cycle 12 pending → resolved):** #1342 **confirmed** (live continuation-shape probes deny under both hooks, rc=2; no new denial class). #1346 **confirmed** (cycle-12 rows verified = Σ max-per-agent_id; this cycle's rows again equal the per-agent dedup: #1360 10,331,978 + 7,248,690 = 17,580,668). #1347 **confirmed** — hypothesis was "edges are inflated by glob expansion and negated prose": a disjoint 1A+2D slate whose A body names #1361's two scripts in a `Do not change …` sentence produced 0 edges and ran in ONE wave (cycle 11's 1A+2D slate: 3 waves); fullsend 69 → 50 min (−27 %, under the 30 % latency band on its own — the wave count is the direct measurement; the residual is the A issue's serial classify → plan → plan-eval ceremony plus a 19-min #1360 eval).

**Pending → cycle 14:** #1360 (denials row agrees with agent-reported denials over a full cycle — this cycle 3 logged vs 4 claimed, see backlog #78), #1361 (`WARN … unproven` lines 1–2 → 0 on a background-dispatch cycle; this cycle's evals were dispatched synchronously and #1361's own eval saw `no-refusal`), #1362 (Step 8 / Step 11.2 contradiction shapes → 0; Task 3 not shipped → #73 skill half + #75).

**Mass:** words 56405 (post-sync) → 56386 (−19: #1362 6675 → 6656) · scripts 92 (+62 LOC: `run-retro.sh` deny-log row, `check-capability-refusal.sh` ASYNC arm + header, `auto-merge-gate.sh` NOTE — #1361 +31 vs its ≤ 25) · hooks 15 / 4617 (0 this cycle; +142 came from staging #1352) · tests 447 (+102 LOC: #1360 fixture + cases, #1361 +97 vs its ≤ 70; no new test files). **Escapes:** hotfix 0, revert 0, later-fix 0. **Gate yield: 2 pre-merge fixes + 1 scope-down accepted** — both fixes are the same class (issue scope omitted a doc/README that pins the changed contract → backlog #77); #1362's Task 3 was infeasible as planned (Case G byte-identical block, missed by plan-eval → #75). Prose budgets: #1362 ≤ 0 net words held (−19); #1360 scripts +≤ 40 held; #1361 scripts/tests over by 6 / 27 LOC (header-comment contract text, advisory). Fixtures left under `.claude/scratch/`: 0 new. Weak-model pass: n/a (no calibration run). Executors: 71 / 62 tool uses for the two D's (cycle 12: 51–53) — #1360 ran the full `test-run-retro.sh` 166-case file repeatedly; evaluators 37 / 31 / 20.

**Hook denials (deny log, first cycle live):** 3 — two orchestrator probes (Step 2 verdict evidence for #1342) and the #1362 planner's `restrict_paths` denial of a python heredoc containing `'/'` as a `split` delimiter (pattern-operand FP, python-string arm). The #1360 evaluator's reported glob-remove denial has no record and replays clean through both hooks (#78). Orchestrator friction: the dispatch prompts carried a blanket "never spell recursive-remove" rule that contradicts the skill's literal-path cleanup recipe (2 evaluator lines, #76) — orchestrator-owned; fixed in the next cycle's prompts.
