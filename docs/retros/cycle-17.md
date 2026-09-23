cycle-issues: 
pending-verdicts: 1382 1381 1380
verdict-candidates: 

friction: denials = n/a (no cycle window)
friction: harness-friction-lines = 15
friction: harness-friction-window = tracker cycle 16 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: skills/classify-issue/SKILL.md step 7 uses `"${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh"` unguarded | `CLAUDE_PLUGIN_ROOT` is unset in a fresh Bash subshell under the dogfood `PIPELINE_USE_LOCAL_PLUGIN=true` install, so the literal step-7 line resolves to `/scripts/...` and fails; steps 0a/1 use the `${CLAUDE_PLUGIN_ROOT:-.}` form and work. (#1381 classify)
HARNESS-FRICTION: issue #1381 Scope item 4 names `tests/test-path-b-default-sonnet-routing.sh` for a behavioral `REASON=default-sonnet` case | that file is a pure static grep/awk lint over `skills/fullsend/SKILL.md` + `pipeline.config.example` + `scripts/init.sh` with no `gh` stub and no live dispatch — the behavioral cases were placed in `tests/test-resolve-execute-dispatch.sh`. (#1381 plan)
HARNESS-FRICTION: issue #1381 Affected areas names `tests/test-body-path-extractor.sh` as the home for "a wave test" | the wave assertion is green before any code change, because `bp_drop_negated_lines` already shipped in #1347; the issue's framing implies a red test. (#1381 plan)
HARNESS-FRICTION: dispatch prompt said post a `## Evaluation` comment | the skill template and `scripts/run-retro.sh` L928-929 require `## Plan Evaluation` on an issue — a bare `## Evaluation` body is classified as a PR eval, not a plan eval. (#1381 plan-eval)
HARNESS-FRICTION: dispatch prompt said "apply the `plan-reviewed` label per the skill" as a terminal-state requirement | the skill's step 6 forbids any label change on a Revise verdict, so the two halves of that instruction are unsatisfiable together. (#1381 plan-eval)
HARNESS-FRICTION: BOOT FENCE said sourcing pipeline.config + exporting CLAUDE_PLUGIN_ROOT is safe/needed before plugin-script Bash calls | it also exports `PIPELINE_PROJECT_ROOT=<main-checkout>` from the live pipeline.config, and the outer session independently pre-exports `CLAUDE_PLUGIN_ROOT`/`PIPELINE_PROJECT_ROOT`/`PIPELINE_USE_LOCAL_PLUGIN=true` pointing at the main checkout; both leaked into `run-test-suite.sh` chunks and caused 6 false-positive failures until explicitly unset before each invocation. (#1380 execute, backlog #96)
HARNESS-FRICTION: the plan's design decision "Do NOT write `FILE_PATH_RE=` into `_high-uncertainty-match.sh`" reads as being about a second assignment | `tests/test-body-path-extractor.sh` S1 is a plain substring grep that also catches the literal in a COMMENT, so an explanatory comment mentioning it reddened S1. (#1381 execute GREEN)
HARNESS-FRICTION: dispatch prompt said the RED agent measured 13 pre-existing failures | an independent baseline at the same commit measured 16; the extra three are wall-clock-hour-dependent checkpoint fixtures. (#1381 execute GREEN, backlog #98)
HARNESS-FRICTION: `skills/evaluate-issue-pr/SKILL.md` Step 4 says the #1329 subject check is `grep -F -e <basename> -e <dir>/ <test>` per touched path | for a `scripts/*.sh` touched path the `<dir>/` arm is `scripts/`, which matches ~350 of ~450 test files — the dir arm is vacuous outside its `hooks/*.py` motivating case. (#1381 pr-eval, backlog #97)
HARNESS-FRICTION: `skills/evaluate-issue-pr/SKILL.md` Step 4 says a body claiming untouched failures without the `## Pre-existing failures` list is Flagged | a green full-suite head CI makes the claim moot, so the documented outcome would block an otherwise-clean PR on a body-format omission that is fixable in-eval. (#1381 pr-eval)
HARNESS-FRICTION: `skills/evaluate-issue-pr/SKILL.md` (#1329) says "a body claiming untouched failures without the list is Flagged" | the in-repo precedent — PR #1384's own pr-eval comment, since merged — is fix-in-eval (append the section, verdict stays Approved); the skill has no fix-in-eval branch for the missing-section case. (#1382 pr-eval)
HARNESS-FRICTION: skill Step 11.2 prescribes `auto_merge_should_fire` checks `baseRefName == $PIPELINE_BASE_BRANCH` | correct on this clone, but the CLAUDE.md prose describing `staging` as "the base branch for all pipeline work" does not match the evolve-clone reality. (#1380 pr-eval)
HARNESS-FRICTION: `skills/fullsend/SKILL.md` states the `#<N>` cost-attribution key only in the PATH C leaf paragraph | it binds every dispatch; twelve cycle-16 dispatches described with bare integers wrote `issue=""` on every cost row and `run-retro.sh --post` reported `n/a (no cost records)` for all three issues (orchestrator, backlog #93)
HARNESS-FRICTION: #1381 shipped the `do not edit — verify only:` cue for `## Affected areas` hits | a backticked path in ORDINARY PROSE is still an edit edge — #1380's Context sentence naming `setup-worktree.sh` serialized a disjoint 2D+1B slate into 2 waves, and no negation cue can help a sentence that forbids nothing (orchestrator, backlog #95)
HARNESS-FRICTION: `skills/fullsend/SKILL.md` split-role GREEN dispatch contract enumerates the red/green, staging, suite and cross-cutting-guard directives | it never names execute Step 8b, so the closing code review never ran on the PATH B and #1374's `role=review` cost row did not appear (orchestrator, backlog #94)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words 52 (baseline 56400 -> computed 56452)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 15 -> computed 15)
delta issue-number archaeology in skill bodies/refs -3 (baseline 352 -> computed 349)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 1 (baseline 187 -> computed 188)
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
doc/behaviour contradictions (one session): cycle 15: 1 new shape (the evolve Step 3 rule from #1367 — list every `docs/` + `tests/fixtures/` hit under Affected areas — is read by `plan-waves.sh` as edit edges unless the line carries a negation cue, serializing a disjoint slate into 2 waves until #1372's line was rephrased with `do not edit`; the same listing put `docs/security-model.md` in the body and the word-bound high-uncertainty match routed a cheap D to opus; backlog #87) · the cycle-14 "Step 4" shape: 0 lines (fixed by #1367) · Step 8b `superpowers:code-reviewer` (2 lines in cycle 14, 1 pre-merge line in cycle 15) fixed by #1374. cycle 14: 1 new shape (the evaluators' fixture bullet is labelled "Step 4" across issue #1362/#1366/#1367 bodies and backlog #73/#75 — it is the `## Executable verification` bullet at evaluate-issue-pr:65; the #1367 plan-evaluator's Revise caught the mislabel before it shipped into the evolve skill) · cycle-13 shapes (Case G pairing, Step 11.2 async-dispatch NOTE) fixed by #1366; "Step 4" pointer fixed by #1367 round 2. Cycle 13: 2 new shapes (evaluate-issue-pr Step 4 fixture bullet sits inside the Case G byte-identical block — a pr-eval-only edit can never pass, backlog #75; Step 11.2 prose does not name the new `NOTE: … async-dispatch` outcome, #66 standing) · both Step 8 / Step 11.2 shapes from cycle 12 fixed by #1362
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 22.3M (cycle 16, reconstructed by `agent_id` — every row landed `issue=''` because the orchestrator's dispatch descriptions used bare `1380` instead of the `#<N>` attribution key, so `run-retro.sh --post` reported `n/a (no cost records)`; backlog #93 — #1380 22.3M D: exec 18.81M sonnet (111 tool uses / 1369 s — the most expensive D yet, a hook change with four adversarial fail-open arms) + pr-eval 3.50M (27 / 319 s) · #1381 35.9M B split-role: classify 0.53M + plan 7.35M + 0.93M round 2 + plan-eval 5.57M + 1.35M round 2 + exec RED 5.84M opus (36 / 854 s) + exec GREEN 4.69M opus (42 / 1167 s) + pr-eval 9.61M (57 / 446 s) · #1382 11.4M D: exec 7.16M sonnet (68 / 948 s) + pr-eval 4.26M (30 / 362 s); no `role=review` row on the PATH B — the GREEN dispatch prompt omitted execute Step 8b entirely, backlog #94; fullsend 90 min in TWO waves for a disjoint 2D+1B slate, the second wave caused by a prose backtick, backlog #95). Cycle 15: 18.4M (cycle 15, instrument-true — #1372 9.0M D: exec ≈4.6M opus (43 tool uses / 400 s; `REASON=high-uncertainty` from a listed doc filename, #87) + pr-eval ≈3.9M (27 / 290 s) · #1373 18.4M A: classify 0.5M + plan ≈5.0M + 0.6M round 2 + plan-eval ≈3.7M + 0.4M round 2 + exec ≈2.7M (23 / 613 s) + review 0.4M + pr-eval ≈3.6M (20 / 227 s) · #1374 20.0M A: classify 0.3M + plan ≈4.0M + 1.2M round 2 + plan-eval ≈4.3M + 0.3M round 2 + exec ≈3.7M (26 / 417 s) + review 1.0M + pr-eval ≈3.6M (21 / 238 s); fullsend 37 min in ONE wave (1D+2A); A plan-evals 3.7M / 4.3M first round vs 7.6M / 5.8M in cycle 14 — the dispatch prompt scoped them to "the pins the edit could break, not the full battery" (#83 watch: coached this cycle)). Cycle 14: 19.9M (2A+1D). 19.9M (cycle 14, instrument-dedup'd — #1366 23.9M A: classify 0.5M + plan 5.0M + plan-eval 7.6M (49 tool uses, 706 s — full 67-file pin battery on a scratch copy) + exec 7.1M (47 / 890 s) + pr-eval 3.7M (24 / 345 s) · #1367 19.9M A: classify 0.5M + plan 2.4M + 0.7M round 2 + plan-eval 5.8M + 1.1M round 2 + exec 4.2M (37 / 484 s) + pr-eval 4.5M (29 / 292 s) · #1368 10.8M D collapsed: exec 7.8M sonnet (65 / 434 s) + pr-eval 3.0M (21 / 224 s); fullsend 51 min in ONE wave for a disjoint 2A+1D slate; the two A issues' plan-evals (13.4M) are 31 % of the cycle's agent spend vs the scorecard's 14 % plan-eval share). Cycle 13: 15.2M (1A+2D). Cycle 12: 11.4M (3D). Cycle 11: 17.0M; cycle 10: 23.4M; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: n/a (calibration run aborted: reason=no-pr)

usage: five_hour=9% seven_day=53% threshold=85


## Diagnose

### Verdicts on cycle 16
- **#1380 — confirmed.** `_deny_log.py:_resolve_log_dir` routes every denial to the main-checkout `.claude/logs/` via `git rev-parse --git-common-dir`. Main log holds 283 rows (cycle 15: 0 rows all cycle, 139 rows stranded in worktree-local copies); no worktree-local `hook-denials.jsonl` survives; `tests/test-restrict-paths-hook.sh` now passes `PIPELINE_LOGS_ENABLED=false` through both `env -i` boundaries (~30 rows/run → 0). Caveat, not a regression: the `session=unknown` token no longer discriminates probe rows from real worktree-agent denials (262/266 in-window) — #1373's proxy is invalidated by the very fix that made the row readable. Tracked as backlog 99 (provenance field), not re-opened against #1380.
- **#1381 — split.** High-uncertainty half **confirmed**: `hu_strip_path_tokens` drops backticked path-shaped spans before the carve-out grep, so a listed filename no longer routes a cheap D to opus. Wave half **no-effect**: the negation-cue mechanism only helps a line that forbids something, and `bp_body_paths` still harvests backticked tokens from free prose — cycle 16's own disjoint 2D+1B slate serialized into 2 waves on a Context-sentence mention. The residual is backlog 95 and is this cycle's PATH B pick.
- **#1382 — confirmed.** `mkdir -p .claude/scratch` is unconditional in `setup-worktree.sh` (line 143) and in the PATH C leaf setup (`path-c-split-worktree.sh` line 62). Friction count re-verified against cycle 17's worktrees at step 5.

### Slate rationale
Cycle 16 produced three new instrument/cost failures and the loop is currently blind in its own cost row. Ranked picks:
1. Backlog 93 + 94 (merged, PATH B) — both are dispatch-contract defects in one file, so filing them separately guarantees a serialized wave. 93 is the highest-value item on the board: twelve dispatches wrote `issue=""` and the whole cycle median had to be hand-reconstructed. Prose alone already failed once (the rule exists in the PATH C leaf paragraph), so the fix carries a verification arm.
2. Backlog 95 (PATH B) — one spurious wave per slate is the largest recurring wall-clock and base-refresh cost in the loop, and it is the unfinished half of a cycle-16 verdict.
3. Backlog 96 (PATH D) — six false test failures in one executor, each costing a baseline re-run and a pre-existing-failure argument.

Deferred: 97 (two evaluators reached the same benign outcome, contract gap but no wrong verdict), 98/88 (host-failing tests, needs an operator hand-patch), 99 (blocked on a provenance design that should follow 93's instrument work).

## Post

### Slate outcome

All three issues merged in ONE wave. The disjoint 2B+1D slate planned as a single wave with no hand rephrase — the first direct evidence that #1381's negation-cue half plus disciplined body authoring holds, and the standing counter-example to cycle 16, which serialized an equally disjoint slate on a single prose backtick.

| Issue | Path | PR | Merge | Tokens | Stages |
|---|---|---|---|---|---|
| #1387 | B split-role | #1392 | 2ba8d1b | 49.5M | 4 |
| #1388 | B split-role | #1391 | 246f29e | 26.5M | 4 |
| #1389 | D collapsed | #1393 | 21d53bd | 30.8M | 2 |

Median 30.8M, up 38% on cycle 16's 22.3M. Two PATH B issues plus a D that cost like a B, with two executor recoveries and two extra fix dispatches folded in.

### The instrument came back

Twelve of twelve dispatch descriptions carried the attribution key, so `run-retro.sh --post` printed real per-issue cost rows for the first time since cycle 15. That was hand-applied discipline, not the merged fix — #1387 landed at the end of the cycle it was measuring — so the verdict on whether the hoisted rule governs a fresh orchestrator belongs to cycle 18.

`friction/denials` also read for real for the first time: 633 rows, dominated by the deletion guard (417), then comment-trust (154), CI-skip markers (55) and path restriction (7). Cycle 15 saw zero rows in the main log because they were all stranded in worktree-local copies; #1380 fixed that, and the number it revealed is large enough to be its own backlog item.

### Gate yield

Three real defects caught before merge, the highest of any cycle so far, and two of them were in the loop's own machinery:

- **#1387, pr-eval.** The hoisted attribution block bound only dispatch sites authored BELOW it. `classify`, `plan` and `plan-eval` — three of the nine shapes it prescribes — are authored in Steps 1b and 2 ABOVE it and have no sites below. The rule as written would have excluded exactly the cycle-16 offenders it was written to catch. Rescoped in-eval (`4463364`).
- **#1389, pr-eval.** `--changed-only` re-sources the config resolver under `set -a` after the entry scrub, re-exporting the main checkout into spawned tests — in the exact mode execute Step 6b uses by default. The headline fix would have been silently defeated in its most common invocation. Hoisted in-eval (`e0156cb`), hermetic case added and RED-verified.
- **#1388, closing review.** `bp_declared_lines` applied both terminator rules to one shared flag, so a bold line inside an `## Affected areas` block silently truncated it — the same silent-edge-loss class the issue exists to close, reached by a different vector. Reproduced by the orchestrator, fixed `5ec7dc4` with additive B16/B17.

The #1387 catch is the one worth remembering: a plan can be verified end to end, a suite can be green, and the change can still not do the thing it was filed to do, because placement in a document is behaviour.

### What cost the money

Both PATH B GREEN agents dropped out after committing and before pushing, each at the same point: a full-suite chunk that the Bash tool auto-backgrounded past its ~120 s ceiling. One also yielded waiting on the closing-review subagent it had just been told to dispatch. In both cases the orchestrator-owned `recover-push` ladder finished the work — hand-running the locked suites, running the cross-cutting guards, pushing, and authoring both PR bodies.

Two directives collided to produce this. "Never background a test run" is unachievable when the harness backgrounds it for you unless an explicit timeout is passed, and "dispatch a closing code review" is narrate-and-yield with extra steps unless the dispatch site says to consume the result inside the same turn. Both are now backlog #101 and #100, and #100 is a direct regression introduced by this cycle's own #1387 — the fix for a missing review created a new way to strand a PR.

### Verdicts

Cycle 16 resolved at step 2: #1380 confirmed, #1382 confirmed, #1381 split (high-uncertainty half confirmed, wave half no-effect and re-filed as #1388, which is now merged).

Cycle 17's three issues are all `Measured by: retro (next cycle)` and carry forward to cycle 18 as pending.

### New backlog

#100 closing-review drop-out · #101 the un-backgroundable test run · #102 `recover-label` reported for a PR that does not exist · #103 the deletion guard's relative-only scratch carve-out · #104 633 denials and the comment-trust field list the skills still prescribe · #105 a reviewer that reported no blocking findings while its own finding stood · #106 a host-failing test that hardcodes `staging`.
