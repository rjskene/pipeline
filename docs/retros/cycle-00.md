cycle-issues: 1272 1273 1274

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
escapes: later-fix = 0

gate-yield: Flagged/evals = 0/1
gate-yield: Revise/plans = 3/6

weak-model pass: n/a (no calibration slate; spec §8 cycle-1 deliverable)

usage: five_hour=4% seven_day=33% threshold=85

prev-delta: n/a (no previous cycle)

## Diagnose

Cycle 0 is the tooling cycle (spec §11): no scorecard row was targeted; the slate is fixed by the spec — `scripts/run-retro.sh` (#1272), `skills/evolve/SKILL.md` + friction capture (#1273), housekeeping (#1274). Cycle 0 is exempt from the must-move-a-row rule and is measured by the mass row and by working in cycle 1.

Bootstrap findings that changed the slate mid-cycle: the Bash-side plugin-root resolver fell through to the published cache in the `--plugin-dir` clone (fixed with `PIPELINE_USE_LOCAL_PLUGIN=true` in the clone config; spec §3.2 synced in #1273); `hooks/restrict_paths.py` blocks the spec §3.3 main-checkout config read (redesigned as a tracker attestation in #1273); `check-config-drift.sh` scans `docs/` so the spec's mention of `PIPELINE_TRUST_PROFILE` redded four suite tests on clean HEAD (hotfix #1275 → PR #1276); the clone's suite had host-config-coupled baseline failures (three test guards fixed as #1274 item 7; two prescribed `pipeline.config` hand-patches applied — `PIPELINE_TEST_CMD` → `run-test-suite.sh` per #1132, NEXT-knob doc lines).

Verdicts for cycle 0 (immediate rows): mass — skill prose +2005 words (new `skills/evolve/`) +108 (fullsend friction capture) against −2848 words / −527 LOC from the self-audit retirement (#1274); scripts +982 LOC (`run-retro.sh`), tests +2488 LOC / +4 files, hooks −1467 LOC / −1. Net prose ≤ 0 holds (docs+skills); net code mass is UP by design (the loop's own tooling). Friction — 60+ `HARNESS-FRICTION:` lines captured (cycle comment on #1271); dominant classes: `restrict_paths.py` path-shaped-text false positives (backlog #7/#12), Boot-block resolver provenance in the clone, stale/rounded baselines, prose-pinning guards that need hand-extension per new skill (backlog #8). Gate yield — plan-eval Revise-first 3/3 (100% vs 35% baseline), all Approved on round 2; pr-eval Approved 3/3, 0 Flagged. Escapes — 0 attributable (1 hotfix was a pre-existing baseline red, not a cycle regression).

## Post

```
COMPUTED prose-pinning tests/grep claude.md = 39
COMPUTED harness mass/words = 55738
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 71488
COMPUTED harness mass/hooks loc = 3533
COMPUTED harness mass/scripts loc = 20982
COMPUTED harness mass/hooks = 13
COMPUTED issue-number archaeology in skill bodies/refs = 357
COMPUTED issue-number archaeology in skill bodies/distinct = 134
COMPUTED harness mass/tests = 409
COMPUTED prose-pinning tests/grep skill.md = 169
COMPUTED harness mass/scripts = 86
COMPUTED escapes/hotfix = 5
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 12
COMPUTED friction/hotfix = 5
COMPUTED escapes/later-fix = 0
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
verdict-candidates: 1272
```
