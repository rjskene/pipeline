cycle-issues: 
pending-verdicts: 1368 1367 1366
verdict-candidates: 

friction: denials = n/a (no cycle window)
friction: harness-friction-lines = 18
friction: harness-friction-window = tracker cycle 14 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: issue #1366 says "pay for [the Step 11.2 sentence] by trimming redundant words in the same Step 11.2 passage" with a 0-net-word file budget | the paired Step 4 clause (+27) also lands in evaluate-issue-pr, and all unpinned Step 11.2 redundancy totals −48, so a 0-net result needs one trim outside 11.2 (Step 11.1) — noted in the plan's design decisions (#1366 plan)
HARNESS-FRICTION: issue #1366 budgets evaluate-issue-plan at ≤ +40 words for "one sentence" | the paired fixture clause consumes 27 of those 40, so the Step 3 sentence only fits (36 words) by also trimming the unpinned 24-word #1200 anecdote in the same Step 3 (#1366 plan)
HARNESS-FRICTION: skill Step 4 bullet says `mktemp -d -p "$PWD/.claude/scratch"` fixtures are safe to work in | `hooks/restrict_paths.py` blocks any Bash command text containing a bare ` / ` token, including pathlib's `a / "b"` operator and the anecdote phrase `keyset-caught / literal-missed` inside a python heredoc string — had to switch to `joinpath` and marker-slicing (#1366 plan-eval)
HARNESS-FRICTION: skill says "Clean up literally: `rm -rf .claude/scratch/<name>`" implying `rm -rf` is fine when the target is scratch | `hooks/block_deletions.py` blocks the command whenever `rm -rf` appears ANYWHERE in the text (e.g. inside a python string literal used as a replace anchor), not only as an executed deletion target (#1366 plan-eval)
HARNESS-FRICTION: operating rule "one test file per `bash` invocation" via a `while read` loop over the 67-file list | `tests/test-migrate-from-subtree.sh` consumes the loop's stdin, silently skipping the next file (`test-migration-cleanup-claudemd`) — batch runners need `< /dev/null` on the inner `bash` or a `for` over an array (#1366 plan-eval)
HARNESS-FRICTION: issue #1367 body + plan say "evaluate-issue-pr Step 4 mandates a literal `.claude/scratch/<name>` recursive cleanup" | the rule is the `## Executable verification` "Build a fixture when needed" bullet (line 65); numbered Step 4 (lines 95–144) has no fixture/scratch text (#1367 plan-eval)
HARNESS-FRICTION: dispatch prompt said "In python heredocs never use a bare '/' string literal — use pathlib" | `restrict_paths.py` also blocks the pathlib ` / ` join operator as "path outside project boundary: /"; `Path.joinpath(...)` was needed (#1367 plan-eval)
HARNESS-FRICTION: execute-issue-plan Step 8b prescribes `Agent(subagent_type: "superpowers:code-reviewer")` | no such agent type exists in this session's list; used `general-purpose` with the requesting-code-review template instead (#1366 execute)
HARNESS-FRICTION: skill Step 1 says attachments are mirrored to `.claude/scratch/issue-<N>/` by setup-worktree.sh | `.claude/scratch/` did not exist in the worktree at all (first redirect into it failed; had to `mkdir -p`) (#1366 execute)
HARNESS-FRICTION: execute-issue-plan Step 8b says dispatch `Agent(subagent_type: "superpowers:code-reviewer")` | that agent type is not registered in this session's agent list; used `general-purpose` with the requesting-code-review template instead (#1367 execute)
HARNESS-FRICTION: execute-issue-plan Step 6a says run `$PIPELINE_TYPECHECK_CMD` | the variable is unset in pipeline.config (no-op, not an error) (#1367 execute)
HARNESS-FRICTION: none (#1368 execute)
HARNESS-FRICTION: evaluate-issue-pr `## Executable verification` mandates a negative control per guard claim, and the Step 4 addition points every dispatch at that recipe | running that control against `hooks/block_deletions.py` writes a synthetic `session=unknown` denial row into the worktree's gitignored `.claude/logs/hook-denials.jsonl` (the executor's identical 18:10 row shows it happens on every eval that follows the rule) — the #1360 `run-retro` denials row has no way to tell a deliberate negative control from real friction (#1367 pr-eval)
HARNESS-FRICTION: restrict_paths.py hook blocks any Bash command whose text contains the literal control-file basename | the command only wrote a `{}` stub into a `.claude/scratch/` fixture dir, never the real file — evaluator fixtures that need a stub of that file must obfuscate the name in command text (#1368 pr-eval)
HARNESS-FRICTION: evolve SKILL Step 3, backlog #73/#75 and issues #1362/#1366/#1367 all call the evaluators' fixture bullet "Step 4" | it is the `## Executable verification` bullet at evaluate-issue-pr:65 — the mislabel reached a plan and was caught only by the #1367 plan-evaluator's Revise (orchestrator)
HARNESS-FRICTION: `run-retro.sh --post` `friction/denials` = 16 for cycle 14 | 13 rows are in the cycle; the window is date-granular (`Cycle 14 (2026-09-21`) so cycle 13's 3 same-day rows are counted twice (orchestrator, backlog #80)
HARNESS-FRICTION: `run-retro.sh` friction/denials counts every `hook-denials.jsonl` row as friction | 5 of the 13 cycle-14 rows are plan-evaluator negative controls (`session=unknown`) and probes run from a worktree cwd log to the worktree's own file, which the retro never reads (orchestrator, backlog #81)
HARNESS-FRICTION: memory rule "from now on run cycles through `scripts/evolve-loop.sh`; never drive a cycle by hand while a launcher is armed" | this session WAS the armed launcher's `claude -p` (PPID chain → evolve-loop.sh) — the skill invocation arrives as a user prompt, so the process tree, not the prompt shape, decides whether to launch a wrapper (orchestrator)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words 15 (baseline 56400 -> computed 56415)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 15 -> computed 15)
delta issue-number archaeology in skill bodies/refs -3 (baseline 352 -> computed 349)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
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
doc/behaviour contradictions (one session): cycle 14: 1 new shape (the evaluators' fixture bullet is labelled "Step 4" across issue #1362/#1366/#1367 bodies and backlog #73/#75 — it is the `## Executable verification` bullet at evaluate-issue-pr:65; the #1367 plan-evaluator's Revise caught the mislabel before it shipped into the evolve skill) · cycle-13 shapes (Case G pairing, Step 11.2 async-dispatch NOTE) fixed by #1366; "Step 4" pointer fixed by #1367 round 2. Cycle 13: 2 new shapes (evaluate-issue-pr Step 4 fixture bullet sits inside the Case G byte-identical block — a pr-eval-only edit can never pass, backlog #75; Step 11.2 prose does not name the new `NOTE: … async-dispatch` outcome, #66 standing) · both Step 8 / Step 11.2 shapes from cycle 12 fixed by #1362
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 19.9M (cycle 14, instrument-dedup'd — #1366 23.9M A: classify 0.5M + plan 5.0M + plan-eval 7.6M (49 tool uses, 706 s — full 67-file pin battery on a scratch copy) + exec 7.1M (47 / 890 s) + pr-eval 3.7M (24 / 345 s) · #1367 19.9M A: classify 0.5M + plan 2.4M + 0.7M round 2 + plan-eval 5.8M + 1.1M round 2 + exec 4.2M (37 / 484 s) + pr-eval 4.5M (29 / 292 s) · #1368 10.8M D collapsed: exec 7.8M sonnet (65 / 434 s) + pr-eval 3.0M (21 / 224 s); fullsend 51 min in ONE wave for a disjoint 2A+1D slate; the two A issues' plan-evals (13.4M) are 31 % of the cycle's agent spend vs the scorecard's 14 % plan-eval share). Cycle 13: 15.2M (1A+2D). Cycle 12: 11.4M (3D). Cycle 11: 17.0M; cycle 10: 23.4M; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=45% seven_day=33% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 47 -> computed 47)
prev-delta harness mass/words 0 (previous 56415 -> computed 56415)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 82082 -> computed 82082)
prev-delta harness mass/hooks loc 0 (previous 4617 -> computed 4617)
prev-delta harness mass/scripts loc 0 (previous 23613 -> computed 23613)
prev-delta harness mass/hooks 0 (previous 15 -> computed 15)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 349 -> computed 349)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 138 -> computed 138)
prev-delta harness mass/tests 0 (previous 448 -> computed 448)
prev-delta prose-pinning tests/grep skill.md 0 (previous 187 -> computed 187)
prev-delta harness mass/scripts 0 (previous 92 -> computed 92)

## Diagnose

**Verdicts for cycle 14 (pending → resolved; provisional at step 2, finalized at step 5 against this cycle's run):**
- **#1366 confirmed (provisional)** — cycle-14 friction lines naming the fixture re-creation gap, the Case G pairing, or the async-dispatch NOTE: 0 (the one prose contradiction was the "Step 4" label, #1367's class); plan-eval Revise-from-missed-pin: 0 of 2 first rounds. Finalized at step 5: this cycle's evaluator A issue edits the paired `## Executable verification` block again, so Case G pairing and the "run every test that greps the skill" rule are both exercised on a real plan-eval.
- **#1367 confirmed (provisional)** — dispatch-contradiction lines 0 (cycle 13: 2); pr-eval doc-drift fixes 0 of 3 (cycle 13: 2 of 3). Finalized at step 5: every cycle-15 filing lists its `docs/` + `tests/fixtures/` hits under Affected areas (done at step 3 with `grep -rl`), and the pr-eval doc-drift fix count on this slate is the measurement.
- **#1368 confirmed (unit half)** — `tests/test-setup-worktree-sync-defaults.sh` green on the merged head, CI green; the calibration half (run #6, operator-gated) stays in `verdict-candidates`.

**Cycle-14 friction audit (18 lines):** `restrict_paths` bare-`/` in python heredocs ×2 (#82) · `superpowers:code-reviewer` agent type absent ×2 (new class; #84 cost row is its twin) · probe rows in the deny log ×2 (#81) · `block_deletions` scanning a python string literal ×1 (#45/#73 residue) · `.claude/scratch/` absent in a fresh worktree ×1 (new) · `test-migrate-from-subtree.sh` eats a loop's stdin ×1 (new) · fixture stub named like a protected file ×1 (new) · the "Step 4" mislabel ×2 (fixed by #1367) · #1366 word-budget arithmetic ×2 (one-off) · `$PIPELINE_TYPECHECK_CMD` unset no-op ×1 (#18 class) · orchestrator wrapper/process-tree ×1 (memory fixed). Reproduced #82 directly (logging disabled): `python3 - <<'EOF' … "a".split("/") … EOF` → rc=2 `BLOCKED: path outside project boundary: /`; the pathlib join and `echo a / b` likewise; `python3 -c '…split("/")…'` (inline, quoted) → rc=0. No test pins a lone-`/` candidate.

**Slate (1 D + 2 A, 0 C; files disjoint — `hooks/restrict_paths.py` / the two evaluators / `execute-issue-plan`):**
1. **D — backlog #82: `restrict_paths.py` drops the lone `/` candidate.** Interpreter-owned heredoc bodies stay scanned by design (fail closed), so a python `'/'` string literal or the pathlib `a / "b"` operator surfaces as the candidate `/` and is denied as an out-of-boundary path — 4 of the 13 cycle-14 deny-log rows, the dominant restrict_paths FP class two cycles running. One skip in the candidate loop next to the `"//"` jq skip; `/etc/passwd`, `//etc/passwd` and the `cd /` gate stay denied as negative controls; cage test untouched.
2. **A — backlog #81: evaluator negative controls stop polluting the deny log.** The paired `## Executable verification` "Run a negative control" bullet gains one clause: a guard hook invoked directly is run with `PIPELINE_LOGS_ENABLED=false` in its env (the logger's env-wins gate), so the probe leaves no `session=unknown` row (5 of 13 cycle-14 rows) and no invisible worktree-local row. No hook or retro code — the existing gate is the mechanism. Exercises the #1366 paired-edit rule.
3. **A — backlog #84 + the cycle-14 `superpowers:code-reviewer` class: execute-issue-plan Step 8b dispatch.** The prescribed agent type is not registered in the dogfood session (2 lines; `docs/operational-notes.md` §4 already documents the workaround) and the description carries no stage token, so the reviewer's cost row lands as `stage=plan` (#1367) or nowhere (#1366). Step 8b dispatches `general-purpose` with `description: "code review #<N>"` — the `capture-agent-costs.sh` shape fullsend already mandates for the PATH C closing review — and uses `superpowers:code-reviewer` only when the session lists it. ≤ 0 net words; operational-notes §4 collapses to a pointer.

Deferred: #80 (window granularity — one cycle today; would conflict with nothing but is a run-retro edit best paired with the next retro change), #79, #73 hook-message half, #69, #71, #6. Watch: #83 (A plan-eval cost — two A issues this cycle, both editing a skill; the #1366 rule prescribes the full `grep -l` battery). New backlog candidates for step 6: `setup-worktree.sh` creating `.claude/scratch/`; `test-migrate-from-subtree.sh` stdin; fixture-stub basename denial; `block_deletions` python-literal scan.

## Post

Cycle 15 — wrapper-driven headless (`scripts/evolve-loop.sh --cycles 1` → `claude -p /pipeline:evolve start --cycles 1`, PID 4027339), 2026-09-22 04:43 → 05:40 UTC (≈ 57 min loop / **37 min fullsend**, 04:55 → 05:32; execute + pr-eval 05:15 → 05:32). Step 0: nothing to forward-sync (staging already an ancestor of `ad244f4`). 3/3 merged, all auto-merged by their evaluator, **0 pre-merge fixes**: #1372 D → PR #1375 `82b8447` (opus collapsed-D — `REASON=high-uncertainty` because the listed `docs/security-model.md` matched the word-bound vocab, #87) · #1373 A → PR #1377 `bbcdf03` (plan round 2) · #1374 A → PR #1376 `509f796` (plan round 2). **ONE wave** — after a hand rephrase: `plan-waves.sh` first put #1372 alone in wave 1 because its Affected-areas docs hits (listed per the #1367 rule, "unchanged") read as edit edges to #1373/#1374; rewriting that line with the `do not edit` cue dropped the edges (#87). Sequence: classify ×2 (≈ 2 min, sequential by orchestrator slip) → plan ×2 (6.5 min) → plan-eval ×2 (6.6 min; BOTH Revise → round-2 plans 1.6 min → round-2 evals 1.1 min) → three parallel executors (400 / 613 / 417 s) → three parallel evaluators (290 / 227 / 238 s).

### Step 5 output (`run-retro.sh --post`)

COMPUTED prose-pinning tests/grep claude.md = 47
COMPUTED harness mass/words = 56412
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 82082
COMPUTED harness mass/hooks loc = 4621
COMPUTED harness mass/scripts loc = 23613
COMPUTED harness mass/hooks = 15
COMPUTED issue-number archaeology in skill bodies/refs = 347
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
COMPUTED friction/harness-friction-window = cycle 15 issue comments
COMPUTED friction/denials = 0 (hook-denials.jsonl; none in window)
cost: issue=#1372 tokens=9018150 stages=2
cost: issue=#1373 tokens=18418471 stages=5
cost: issue=#1374 tokens=19965714 stages=5
cost: loop-own tokens/issue median = 18418471
cost: backfill = ran
verdict-candidates: 1374 1373 1372

**Verdicts (cycle 14 pending → resolved):** #1366 **confirmed** — 0 cycle-15 lines name the fixture re-creation gap, the Case G pairing, or the async-dispatch NOTE; the #1373 plan-evaluator ran Case G on its prototype (the new rule, exercised) and neither Revise this cycle was a missed pin. #1367 **confirmed** — dispatch-contradiction lines 0 (cycles 14–15); pr-eval doc-drift fixes 0/3 two cycles running; every cycle-15 filing listed its `docs/` + `tests/fixtures/` hits — with the two side effects recorded under #87. #1368 **confirmed (unit half)** — merged test green, CI green; the calibration half waits for run #6 (operator-gated) and stays in `verdict-candidates`.

**Pending → cycle 16 (all three need UNCOACHED prompts — every cycle-15 dispatch named the `PIPELINE_LOGS_ENABLED=false` prefix, the `Path.joinpath` workaround and the `code review #<N>` shape):** #1372 (restrict_paths `boundary: /` rows 4 → 0; pathlib / `'/'` friction lines 2 → 0), #1373 (`session=unknown` rows in the MAIN log 5 → 0 with ≥ 1 evaluator having run a direct probe; this cycle 0 but coached), #1374 (`superpowers:code-reviewer` lines 2 → 0; reviewer cost rows `stage=pr-eval role=review` for every A/B issue — this cycle 2/2 but coached).

**Denials audit (#78/#80/#81):** main `hook-denials.jsonl` 0 rows in window (the date-granular window is moot — one cycle today). The three worktrees' gitignored logs held 136 + 1 + 2 rows: `tests/test-restrict-paths-hook.sh` invokes the hook via `env -i`, dropping the prefix and writing ~30 rows per run (seen by the #1372 executor and evaluator), one pre-prefix `enforce-comment-trust` probe (#1373 pr-eval observation), two more in wt-1374. None reached the retro → #85 (the observability.md sentence "denials from linked worktrees land in the one durable main-checkout file" is false when `CLAUDE_PROJECT_DIR` is the worktree). Real friction denials this cycle: 0 agent-reported.

**Mass:** words 56415 → 56412 (−3: #1373 pr 6648 → 6621 / plan 2591 → 2619; #1374 execute 5187 → 5185 / fullsend 14632 → 14630; obs +38, docs net −25) · hooks 15 / 4617 → 4621 (+4, budget ≤ +4 held) · scripts 92 / 23613 (0) · tests 448 / 82082 (`tests/*.sh` only — the +40 LOC in `tests/test_restrict_paths.py` is invisible to the row; budget ≤ +40 held) · refs 349 → 347. **Escapes:** hotfix 0, revert 0, later-fix 0. **Gate yield:** pr-eval 0 fixes / 3; plan-eval 2 Revise / 2 first rounds — both real plan-text defects caught by prototype (#1373: an unsatisfiable `grep -c … → 3` verify line, actual 5; #1374: the §4 replacement text contradicted its own Task 5(a) grep assertion), both applied verbatim in round 2 and approved. Prose budgets: all six held. Fixtures left under `.claude/scratch/`: `issue-1374-cand/` (planner scratch, gitignored) — 1. Weak-model pass: n/a. **Cost:** loop-own median 18.4M (cycle 14: 19.9M, 13: 15.2M) — A issues 18.4M / 20.0M with two plan rounds each; A plan-evals 3.7M / 4.3M first round (cycle 14: 7.6M / 5.8M) after the dispatch prompt scoped them to the pins the edit could break (#83: coached — the #1366 rule text still prescribes the full battery); the D ran on opus (9.0M) by the #87 accident. Executors: 43 (D) / 23 / 26 tool uses; evaluators 27 / 20 / 21. Friction lines: 16 from agents + 3 orchestrator (cycle 14: 18).

**Orchestrator observations:** (1) the two classify dispatches ran sequentially by orchestrator slip (one Agent call per message) — 1 min lost, no other effect; (2) the plan-waves edge came from the body fallback (#1372 had no plan comment yet — a D collapses classify+plan into execute), while #1373/#1374 used their plans' `**Files to change:**` — so the #1367 listing rule bites only D issues and only before their collapsed plan exists; (3) the five-hour window ended the cycle at 84 % (start 45 %) — one more cycle would trip the 85 % gate at Step 0; (4) merged worktrees + local branches removed at cycle end; the wt-1372 deny log (136 rows) went with the worktree.
