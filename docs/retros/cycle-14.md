cycle-issues: 
pending-verdicts: 1362 1361 1360
verdict-candidates: 

friction: denials = n/a (no cycle window)
friction: harness-friction-lines = 19
friction: harness-friction-window = tracker cycle 13 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: skill step 2 jq `max_by(.createdAt) | .createdAt // empty` — fine standalone, but wrapping it inside a jq object literal (as I first did) yields empty output on zero comments; non-issue when run verbatim. (#1362 classify)
HARNESS-FRICTION: `restrict_paths.py` denied a Bash call whose python heredoc contained the string literal `'/'` (used in `split('/')`) as "path outside project boundary: /" | the token was a string-split delimiter, not a filesystem path — worked around with `os.path.basename` (#1362 plan)
HARNESS-FRICTION: plan-issue skill Step 6 says the draft filename is `<N>-<timestamp>.md` | the caller's dispatch contract fixed it to `1362.md` (used the caller's path; post-plan.sh accepted it) (#1362 plan)
HARNESS-FRICTION: issue #1362 says the three resolver tokens "MUST remain in that paragraph (test (m) slices it and greps each token)" | the (m) slice runs to `**Split-role gate` and includes the bash fence's `case` arms, so the prose line alone is not what the test pins — removing a token from the prose only still passes. (#1362 plan-eval)
HARNESS-FRICTION: docs said "Bash tool reads under /tmp are blocked" | confirmed true — a stray `> /tmp_out.log` redirect (not even `/tmp/...`, just a bad relative-looking path) hit a permission error; switched to `.claude/scratch/` per the doc's own guidance, no actual friction beyond my own typo. (#1360 execute)
HARNESS-FRICTION: none (#1361 execute)
HARNESS-FRICTION: plan said Task 3 touches only pr-eval and only the two prose-pin tests matter | Step 4 bullet is inside the canonical block pinned byte-identical across both evaluators by `test-evaluator-executable-verification-prose.sh` Case G — the edit cannot ship without touching `evaluate-issue-plan/SKILL.md` (#1362 execute)
HARNESS-FRICTION: plan predicted `wc -w` 6672 | 6656 actual (Task 3's +16 never landed) (#1362 execute)
HARNESS-FRICTION: skill Step 9a says use `derive-pr-title.sh` output as-is | issue-title passthrough named a change that didn't ship; needed manual trim to keep the CHANGELOG line truthful (#1362 execute)
HARNESS-FRICTION: skill says clean scratch fixtures with a literal `.claude/scratch/<name>` path; a non-recursive `rm .claude/scratch/<name>/*` glob was hard-denied because the hook resolved the relative path against the MAIN checkout (`…/claude-pipeline-evolve/.claude/scratch/…`) instead of the `cd`'d worktree, failing the whole compound command (commit+push had to be re-issued) | `rm -rf .claude/scratch/<name>` in a standalone call was allowed. (#1360 pr-eval)
HARNESS-FRICTION: dispatcher rule "never use recursive-remove spellings anywhere in command text" conflicts with the skill's mandated `rm -rf .claude/scratch/<name>` cleanup form | the `rm -rf` literal-path form is the only one the hook accepts. (#1360 pr-eval)
HARNESS-FRICTION: evaluate-issue-pr Step 11.2 prose lists only `no-sources`/`no-leaf-output` WARN outcomes for a `resolved` arm | after this PR a third stderr outcome (`NOTE: … async-dispatch`) exists and the skill prose does not name it (issue #1361 defers that trim to the cycle's PATH A sweep) (#1361 pr-eval)
HARNESS-FRICTION: PR/issue scope named only 2 scripts + 2 tests | `docs/observability.md` pinned the old four-state contract verbatim and had to be fixed in-eval to avoid shipping a false doc statement (#1361 pr-eval)
HARNESS-FRICTION: issue #1362 Notes said "do not edit evaluate-issue-plan/SKILL.md (its fixture bullet already satisfies the pin; the mid-fixture clause is a pr-eval-only finding)" | Case G pins the whole `## Executable verification` block byte-identical across BOTH evaluators, so no pr-only edit to that bullet can ever pass — the plan's Task 3 was infeasible as written (#1362 pr-eval)
HARNESS-FRICTION: dispatch prompt said "Fixtures: `mktemp -d -p ...`, cleaned by a LITERAL `.claude/scratch/<name>` path" while also banning recursive-remove spellings in command text | the skill's own cleanup recipe (`rm -rf .claude/scratch/<name>`) is that banned spelling; used a fixed-name dir + `rm -f` + `rmdir` instead (#1362 pr-eval)
HARNESS-FRICTION: evolve SKILL pause fence `gh pr list … --base staging --head evolve --state merged` / `--base evolve --state merged` run with gh's default `--limit 30` | 38 PRs merged onto evolve since the last merge-back — the 2026-09-21 merge-back body needed `--limit 100` by hand (orchestrator)
HARNESS-FRICTION: fullsend Step 1b says PATH D issues are excluded from per-stage classify/plan but never says HOW the orchestrator knows an unclassified issue is D | the `<!-- pipeline:path=D -->` body marker is the only signal before classify runs; worked by convention (orchestrator)
HARNESS-FRICTION: orchestrator dispatch prompts (memory-derived) said "never use recursive-remove or hard-reset spellings anywhere in command text" | `block_deletions.py` has allowed the literal `.claude/scratch/<name>` form since #1335 and evaluate-issue-pr Step 4 mandates it — my blanket rule was the contradiction two evaluators reported (orchestrator, backlog #76)
HARNESS-FRICTION: run-retro `friction/denials` = 3 from the deny log | agents reported 4 denials; the #1360 evaluator's glob-remove denial has no record and replays rc=0 through both hooks — not a hook denial (orchestrator, backlog #78)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words -14 (baseline 56400 -> computed 56386)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 15 -> computed 15)
delta issue-number archaeology in skill bodies/refs 1 (baseline 352 -> computed 353)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests 0 (baseline 447 -> computed 447)
delta prose-pinning tests/grep skill.md 0 (baseline 187 -> computed 187)
delta harness mass/scripts 0 (baseline 92 -> computed 92)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it); cycle 8: 2 (#1323 CI-red placeholder-grep test the executor mis-classed as pre-existing; #1321 three fail-closed regressions — `\rm` alias bypass, `xargs`-wrapped rm, brace/glob tmp targets — CI green, cage tests blind to them); cycle 9: 1 (#1327 `command_mask` import not co-located in the phase2-coexistence sandbox copy — CI red, executor mis-classed the test as pre-existing, the #53 class again); cycle 10: 2 (#1334 CI-red head from a scanner guard its own `--changed-only` run skipped — the guard's regex began with `-c` and grep had parsed it as an option, dead code on every prior run; and the `${CLAUDE_PLUGIN_ROOT:-.}` form in the rewritten Step 6b diffing the MAIN tree under dogfood — a proven false green `selected=0/442`, fixed with a `$PWD` anchor); cycle 11: 1 (#1339 fixture scanner test self-tripped on its own `SCANNERMARK` grep — scenario 11's `RESULT=fail` discriminated only by glob order; CI green, fixed `177503c` pre-merge); cycle 12: 3 (#1342 executor pinned one of the issue's two comment-trust continuation shapes — the Step 1a `fetch-issue-attachments.sh` shape was unpinned, Case Y added `23da13e`; #1346 two `refute_sub` median controls went vacuous when the fixture grew to 10 records — re-pinned `02a9778`; #1347 `bp_drop_negated_lines` used `else if`, so `never edit X; you do not need…` kept `X` — B11 added `391226d`; all three CI green, tests blind)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): cycle 13: 2 new shapes (evaluate-issue-pr Step 4 fixture bullet sits inside the Case G byte-identical block — a pr-eval-only edit can never pass, backlog #75; Step 11.2 prose does not name the new `NOTE: … async-dispatch` outcome, #66 standing) · both Step 8 / Step 11.2 shapes from cycle 12 fixed by #1362. Cycle 12: 2 (cycle 12: evaluate-issue-pr Step 11.2 over-warns `no-log-dir`/`unresolvable-root` on worktrees — third cycle, backlog #67; Step 8 `git diff --name-only HEAD...origin/$PIPELINE_BASE_BRANCH` lists base-only files, not the PR's — backlog #72). Cycle 11: 5 (plan-issue Step 3b denied call — fixed by #1340; Step 8b `superpowers:code-reviewer` unregistered — backlog #6; relative `mktemp -p` — fixed by #1341; Step 11.2 over-warns; evolve SKILL Step 5 "async dispatch → hook sees no usage" — fixed by #1346)
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 15.2M (cycle 13, instrument-dedup'd — #1360 17.6M D collapsed, exec 71 tool uses/10.3M/747 s + pr-eval 37/7.2M/1163 s · #1361 15.2M, exec 62/9.2M/497 s + pr-eval 31/6.0M/622 s · #1362 12.8M A, classify 0.9M + plan 3.2M + plan-eval 2.2M + exec 4.0M + pr-eval 2.7M; fullsend 50 min in ONE wave for a disjoint 1A+2D slate — cycle 11's comparable slate took 69 min in 3 waves, #1347 confirmed). Cycle 12: 11.4M (first instrument-true cycle, #1346). Cycle 11 hand-dedup'd: 17.0M; cycle 10: 23.4M; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=53% seven_day=21% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 47 -> computed 47)
prev-delta harness mass/words 0 (previous 56386 -> computed 56386)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 81991 -> computed 81991)
prev-delta harness mass/hooks loc 0 (previous 4617 -> computed 4617)
prev-delta harness mass/scripts loc 0 (previous 23613 -> computed 23613)
prev-delta harness mass/hooks 0 (previous 15 -> computed 15)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 353 -> computed 353)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 138 -> computed 138)
prev-delta harness mass/tests 0 (previous 447 -> computed 447)
prev-delta prose-pinning tests/grep skill.md 0 (previous 187 -> computed 187)
prev-delta harness mass/scripts 0 (previous 92 -> computed 92)

## Diagnose

**Verdicts for cycle 13 (pending → resolved; provisional at step 2, finalized at step 5 against this cycle's run):**
- **#1360 confirmed (provisional)** — `friction: denials` rendered an integer with a per-hook split on the cycle-13 `--post` run (`3 (hook-denials.jsonl; enforce-base-branch=1 enforce-comment-trust=1 restrict_paths=1)`) after 13 cycles of `n/a`; agreement with agent-reported denials was 3 vs 4 (the unlogged glob-remove claim replays rc=0 through both hooks — backlog #78, re-checked at step 5 this cycle).
- **#1361 measured this cycle** — metric is `HARNESS-FRICTION:` lines naming `capability-refusal check unproven` (cycles 10–12: 1–2 each; cycle 13: 0, but two of its three evals ran the pre-merge gate). Every cycle-14 eval runs the merged `auto-merge-gate.sh`; expected 0 lines and a `NOTE: … async-dispatch` only on background-dispatch records.
- **#1362 measured this cycle** — metric is the contradictions row: no cycle-14 line naming Step 8 diff direction, Step 11.2 resolver hedging, or the fixture re-creation gap (the last is the dropped Task 3 → carried by this cycle's A issue).

**Slate (2 A + 1 D, 0 C; files disjoint — evaluators' skills / evolve skill / `setup-worktree.sh`):**
1. **A — evaluator paired prose sweep (cycle 14): backlog #75 + #73 skill half + #66 cycle-14 input.** The Step 4 fixture bullet lives inside the `## Executable verification` block pinned byte-identical across both evaluators (Case G), so the mid-fixture re-creation clause #1362 dropped needs a PAIRED edit; evaluate-issue-pr Step 11.2 must name the `NOTE: capability-refusal arm skipped (REASON=async-dispatch …)` stderr outcome as normal (#1361 landed after #1362's sweep); evaluate-issue-plan gets one sentence — for any plan editing a `skills/*/SKILL.md`, the tests to run are every `tests/*` file that greps that skill path, not just the pins the issue names (the #1362 Task 3 miss).
2. **A — evolve skill Step 3/4 sweep: backlog #76 + #77 + the cycle-13 orchestrator `--limit` line.** Step 3 filing greps `docs/` + `tests/fixtures/` for the changed token and lists hits under Affected areas (2 of 3 cycle-13 PRs needed an in-eval doc fix); Step 4 dispatch guidance carries the fixture-cleanup rule with the literal `.claude/scratch/<name>` carve-out spelled out (two cycle-13 evaluators flagged the orchestrator's blanket ban as contradicting the skill); the pause fence's `gh pr list` calls pass `--limit 100` (gh default 30 truncated 38 merged PRs on 2026-09-21). Body is at 2978/3000 tokens, so ≤ 0 net words.
3. **D — backlog #68: `scripts/setup-worktree.sh` dereferences `$PIPELINE_SYNC_ENVS` / `$PIPELINE_SYNC_VENVS` unguarded under `set -euo pipefail`.** A `pipeline.config` that predates those knobs (the calibration sandbox's) crashes every worktree setup with an unbound-variable error and every sandbox dispatch worked around it inline, inflating the strict baseline. Default the four `PIPELINE_SYNC_*` knobs to empty in the script; regression test with a knob-less config. Consumer-facing (greenfield configs from older `init.sh` too).

Deferred: #79 (per-line deny-log parse — no malformed line seen yet), #73 hook-message half (hooks surface; keep this cycle's D on scripts), #69, #71, #6. Step-5 orchestrator task this cycle: compare the `friction/denials` row against the agents' reported denials line-by-line (#78).

## Post

Cycle 14 — wrapper-driven headless (`scripts/evolve-loop.sh --cycles 1` → `claude -p /pipeline:evolve start --cycles 1`, PID 3631774), 2026-09-21 17:20 → 18:35 UTC (≈ 75 min loop / **51 min fullsend**, 17:36 → 18:27). Step 0: nothing to forward-sync (staging already an ancestor). 3/3 merged, all auto-merged by their evaluator, **0 pre-merge fixes**: #1368 D → PR #1369 `7f3b056` (sonnet collapsed-D, RED observed `PIPELINE_SYNC_ENVS: unbound variable`) · #1367 A → PR #1370 `2cb2f82` (plan round 2) · #1366 A → PR #1371 `6e19b75`. **ONE wave** (`Wave 1: execute #1366, #1367, #1368 in parallel`; `--emit-edges` 0 blockers). Sequence: classify ×2 (≈ 1 min) → plan ×2 (7.5 min) → plan-eval ×2 (11.8 min; #1367 Revise → round-2 plan 1.6 min → round-2 eval 2.1 min) → three parallel executors (890 / 484 / 434 s) → three parallel evaluators (345 / 292 / 224 s).

### Step 5 output (`run-retro.sh --post`)

COMPUTED prose-pinning tests/grep claude.md = 47
COMPUTED harness mass/words = 56415
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 82082
COMPUTED harness mass/hooks loc = 4617
COMPUTED harness mass/scripts loc = 23613
COMPUTED harness mass/hooks = 15
COMPUTED issue-number archaeology in skill bodies/refs = 349
COMPUTED issue-number archaeology in skill bodies/distinct = 138
COMPUTED harness mass/tests = 448
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
COMPUTED friction/harness-friction-window = cycle 14 issue comments
COMPUTED friction/denials = 16 (hook-denials.jsonl; block_deletions=8 restrict_paths=6 enforce-base-branch=1 enforce-comment-trust=1)
cost: issue=#1366 tokens=23863195 stages=5
cost: issue=#1367 tokens=19900653 stages=5
cost: issue=#1368 tokens=10834491 stages=2
cost: loop-own tokens/issue median = 19900653
cost: backfill = ran
verdict-candidates: 1368 1367 1366

**Verdicts (cycle 13 pending → resolved):** #1360 **confirmed** — the `friction/denials` row renders an integer with a per-hook split for the second cycle; the #78 audit found the log a superset of the agents' reports (the cycle-13 reported-but-unlogged class did not recur). #1361 **confirmed** — `WARN … unproven` friction lines 0 in cycles 13 and 14 (1–2 per cycle in 10–12); caveat: every cycle-14 eval was a synchronous dispatch and read `no-refusal`, so the `async-dispatch` NOTE arm is still unexercised on a real eval. #1362 **confirmed** — no cycle-14 line names Step 8 direction, Step 11.2 resolver hedging, or the fixture re-creation gap.

**Pending → cycle 15:** #1366 (contradictions row: fixture re-creation / Case G pairing / async-dispatch NOTE lines → 0; plan-eval Revise-from-missed-pin count), #1367 (dispatch-contradiction lines → 0; pr-eval doc-drift fixes on the cycle-15 slate, this cycle 0; the cycle-15 filing lists every `docs/` + `tests/fixtures/` hit), #1368 (unit half green; calibration half by run #6, operator-gated).

**Denials audit (#78, 13 in-window rows — the row says 16 because the window is date-granular and includes cycle 13's 3 same-day rows, backlog #80):** 5 plan-evaluator negative controls (`session=unknown`, direct hook invocations; the #1367 pr-evaluator's probe from a worktree cwd landed in the worktree's own log and is invisible — #81) · 3 #1366-planner variable-target removals (by design; it then used the literal path) · 4 `restrict_paths` denials of a bare `/` token in python heredocs — string literal and the pathlib join operator (2 agents reported it; #82, now the dominant restrict_paths FP class) · 1 `restrict_paths` denial of a fixture stub named like a protected file (#1368 evaluator). Real friction rows: 5 of 13.

**Mass:** words 56386 → 56415 (+29: #1366 evaluate-issue-pr 6656 → 6648, evaluate-issue-plan 2552 → 2591; #1367 evolve body 2206 → 2204, budget 2975/3000) · scripts 92 / 23613 LOC (0 net: four `${VAR:-}` defaults) · hooks 15 / 4617 (0) · tests 448 (+91 LOC, one new file). **Escapes:** hotfix 0, revert 0, later-fix 0. **Gate yield:** pr-eval 0 fixes / 3; plan-eval 1 Revise / 2 first rounds (#1367 — the plan pointed the new dispatch rule at evaluate-issue-pr "Step 4", a label the issue body, backlog #73/#75 and #1362/#1366 all carried; the bullet is under `## Executable verification`, and the evaluator's prescription was applied verbatim in round 2). Prose budgets: #1366 pr ≤ 0 held (−8), plan ≤ +40 held (+39); #1367 ≤ 0 held (−2); #1368 scripts ≤ +4 held (0), tests ≤ 60 missed (91, advisory — reference fixture is 85). Fixtures left under `.claude/scratch/`: 0. Weak-model pass: n/a (no calibration run). **Cost:** loop-own median 19.9M (cycle 13: 15.2M, cycle 12: 11.4M) — the slate shape moved from 1A+2D to 2A+1D and each A carried the full 5-stage ceremony; the two A plan-evals alone were 13.4M (31 % of the cycle's agent spend vs the scorecard's 14 % plan-eval share) because both prototyped the whole edit on a scratch copy and ran the full 67-file pin battery — #83 watches whether #1366's new Step 3 rule locks that in. Executors: 47 / 37 (A, opus) and 65 (D, sonnet) tool uses; evaluators 24 / 29 / 21. Friction lines: 13 from agents + 4 orchestrator (cycle 13: 19).

**Orchestrator observations:** (1) this process confirmed it IS the wrapper's `claude -p` by walking `ps -o ppid=` to `evolve-loop.sh` — the skill invocation arrived as a user prompt, so the memory rule "run cycles through the wrapper" must be checked against the process tree before launching a second wrapper; (2) the usage gate's five-hour window reset mid-cycle (55 % → 0 % at ≈ 18:00 UTC) — `start` values are the honest ones for the cycle comment; (3) the #1367 executor's code-review subagent was attributed as a `plan` row (#84); (4) merged worktrees `wt-1366/1367/1368` + local feature branches removed at cycle end.
