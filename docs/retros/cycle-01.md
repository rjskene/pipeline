cycle-issues: 

delta prose-pinning tests/grep claude.md 1 (baseline 38 -> computed 39)
delta harness mass/words 738 (baseline 55000 -> computed 55738)
delta harness mass/skills 1 (baseline 18 -> computed 19)
delta harness mass/tests loc 2488 (baseline 69000 -> computed 71488)
delta harness mass/hooks loc -1467 (baseline 5000 -> computed 3533)
delta harness mass/scripts loc 982 (baseline 20000 -> computed 20982)
delta harness mass/hooks -1 (baseline 14 -> computed 13)
delta issue-number archaeology in skill bodies/refs 6 (baseline 351 -> computed 357)
delta issue-number archaeology in skill bodies/distinct 4 (baseline 130 -> computed 134)
delta harness mass/tests 4 (baseline 405 -> computed 409)
delta prose-pinning tests/grep skill.md 4 (baseline 165 -> computed 169)
delta harness mass/scripts 2 (baseline 84 -> computed 86)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): 4

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 0
friction: compactions = n/a (no transcript substrate)
friction: hotfix = 5
friction: manual-merge = 0
friction: human = 12

escapes: hotfix = 5
escapes: revert = 0
escapes: later-fix = 19

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: n/a (no calibration slate; spec §8 cycle-1 deliverable)

usage: five_hour=10% seven_day=34% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 39 -> computed 39)
prev-delta harness mass/words 0 (previous 55738 -> computed 55738)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 71488 -> computed 71488)
prev-delta harness mass/hooks loc 0 (previous 3533 -> computed 3533)
prev-delta harness mass/scripts loc 0 (previous 20982 -> computed 20982)
prev-delta harness mass/hooks 0 (previous 13 -> computed 13)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 357 -> computed 357)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 134 -> computed 134)
prev-delta harness mass/tests 0 (previous 409 -> computed 409)
prev-delta prose-pinning tests/grep skill.md 0 (previous 169 -> computed 169)
prev-delta harness mass/scripts 0 (previous 86 -> computed 86)

pending-verdicts: 1272

## Diagnose

Pending verdict from cycle 0: #1272 → `confirmed` (run-retro.sh produced this retro; the cycle-0 comment already recorded it — run-retro's `pending-verdicts:` harvest does not yet read the `- verdicts:` line, see loop-tooling fixes below). No cost/latency verdicts exist yet: every real-work cost row still shows the spec baseline because no calibration substrate exists — which is why backlog #1 is this cycle's anchor.

Slate (≤3, ≤1 PATH C), ranked from `## Hypothesis backlog` + cycle-0 friction:
1. Calibration slate + sandbox (backlog #1, spec §8) — PATH C. Unblocks every cost/latency/escape verdict and the weak-model row (`n/a` today). Scoped to: `dev/calib/template/` (consumer-shaped sandbox source of truth), `scripts/calibration-run.sh` (`--bootstrap` creates the private sandbox repo from the template, `--reset`, `--dry-run`, `--run`), five template issues, retro ingestion contract. The first paid headless run waits for operator go.
2. Loop-tooling fixes (cycle-0 findings on the loop's own deliverables) — PATH B: (a) the harness rewrites `$1`/`$2` inside `skills/evolve/SKILL.md` fences at load (positional-arg substitution), breaking the projection math — the only skill with `$<digit>` in a fence; (b) Step-0 forward-sync merges but never pushes `evolve`, so cycle worktrees (cut from `origin/evolve`) miss the sync; (c) `run-retro.sh` `friction/hotfix`, `friction/human`, `escapes/*` rows are repo-wide, not cycle-scoped, and `pending-verdicts:` ignores the previous cycle comment's `- verdicts:` line.
3. `hooks/restrict_paths.py` false positives (backlog #7) — filed `human` per spec §6: ≥10 blocks in cycle 0 on path-shaped TEXT in command bodies (bare home prefix, proc-sys pseudo-path, the main-checkout path in heredocs/regexes), Read/Write blocked on the Linux session scratchpad (`_is_session_scratchpad` recognises only the Windows `Temp/claude/` layout), Bash reads of `.claude/settings.json` reported as "modify protected file".

Deferred (cap): fullsend Step 7 contract says verdict "on the issue" while the gate reads the PR; evaluate-issue-pr Step 8 rebase lacks an "only on conflict" qualifier; "Typecheck always runs" is a no-op with empty `PIPELINE_TYPECHECK_CMD`; auto-merge-gate's undocumented "resolved but unproven" capability-refusal state; `check-config-drift.sh` prose/fixture exclusion (3 allow-list entries share the root cause); `test-plan-issue-namespace.sh` hardcoded skill alternation.

## Post

```
COMPUTED prose-pinning tests/grep claude.md = 41
COMPUTED harness mass/words = 55836
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 73460
COMPUTED harness mass/hooks loc = 3533
COMPUTED harness mass/scripts loc = 21821
COMPUTED harness mass/hooks = 13
COMPUTED issue-number archaeology in skill bodies/refs = 357
COMPUTED issue-number archaeology in skill bodies/distinct = 134
COMPUTED harness mass/tests = 417
COMPUTED prose-pinning tests/grep skill.md = 172
COMPUTED harness mass/scripts = 87
COMPUTED escapes/hotfix = 0
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 1
COMPUTED friction/hotfix = 0
COMPUTED escapes/later-fix = 0
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/harness-friction-window = cycle 1 issue comments
COMPUTED friction/denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
verdict-candidates: 
```

Slate: #1280 (PATH C, PR #1283 → 066b95a) and #1281 (PATH B split-role, PR #1284 → 7b1b236) merged into `evolve`; #1282 filed `human` (operator-applied, not run).

Gate yield: plan-eval Revise-first 2/2 (both Approved round 2); pr-eval Approved 2/2, 0 Flagged, 0 reverts; Task-N code review: #1280 "With fixes" (2 Critical + 5 Important, all fixed in six follow-up leaf commits before the PR), #1281 "Yes" (2 Important fixed). Acceptance caught two defects the leaves missed (namespace-guard false positive on `pipeline-calib`; `--bootstrap` seeded labels on the harness repo). One locked-test defect (`has_*` helpers without `--`) was repaired by amend-and-rebase of the RED commit pre-push.

Sandbox: `rjskene/pipeline-calib` (private) bootstrapped three times idempotently, `calib-base` tag + pipeline labels seeded; first paid `--run` awaits operator go.

Verdicts: none this cycle — #1280 pending (metric `weak-model pass` needs the calibration run), #1281 pending (measured at cycle-2 step 1: `friction/harness-friction-window = tracker cycle 1 comment`, zero hand corrections). Early evidence for #1281: live `run-retro.sh --cycle 1` now reads the cycle-0 tracker comment (67 friction lines) and `pending-verdicts:` is empty because the cycle-0 `- verdicts:` line resolved all three.

Mass deltas vs baseline: skills +1 (evolve), tests +12 / +4460 LOC, scripts +3 / +1821 LOC, hooks −1 / −1467 LOC, words +836, prose-pinning greps +7 SKILL.md / +3 CLAUDE.md, issue-number refs +6. No scorecard row replaced (no confirmed verdict).

Usage: start five_hour=11 seven_day=34, end five_hour=44 seven_day=43 (Δ 33 / 9).

Friction: 45 HARNESS-FRICTION lines captured (verbatim in the cycle-1 tracker comment). Recurring classes: plugin-cache glob in every skill Boot fence is dead in the clone; positional-token substitution also rewrites `$0` (evaluate-issue-pr Step 11.2b awk) — the #1281 guard deliberately excluded `$0`; exact-match sweep never fires its `PIPELINE_TEST_ROOTS` vacuity STOP; run-test-suite serial retry still load-sensitive.
