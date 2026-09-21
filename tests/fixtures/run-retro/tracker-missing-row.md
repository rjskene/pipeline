Durable state for the self-driving harness-evolve loop. Spec: `docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md` (§10 defines this issue).

**Not a `tracker`.** Auto-close housekeeping scans only `tracker`-labelled issues; this issue carries `evolve` + `excluded` so neither the staging `/pipeline:status` slate nor tracker auto-close touches it. The `paused` label on this issue is the kill switch.

## Mode

`active` — cycle 0 (tooling) filed 2026-09-05, running via `/pipeline:fullsend 1272 1273 1274`.

## Runtime

| | |
|---|---|
| branch | `evolve` (cut 2026-09-05 from `staging` @ 2eb4569) |
| clone | `~/claude-pipeline-evolve`, session `claude --plugin-dir ~/claude-pipeline-evolve` |
| base in clone config | `PIPELINE_BASE_BRANCH="evolve"`, `PIPELINE_LOGS_ENABLED=true`, `PIPELINE_USE_LOCAL_PLUGIN=true` (Bash-side resolver → clone, not the published cache; see #1273), `PIPELINE_PROJECT_ROOT="/home/rjskene/claude-pipeline-evolve"` |
| staging isolation | main checkout `PIPELINE_LABELS_EXCLUDED="excluded\|evolve"`; nightly `40-pipeline` slate never sees `evolve` issues |
| usage gate | `scripts/usage-gate.sh` before every cycle + projection (`EST5`/`EST7`, spec §5); pause → recurring cron resume |
| merge-back | `evolve → staging` PR at loop pause; forward-sync `staging → evolve` each cycle start |

## Scorecard baseline (2026-08-01 → 09-05, pipeline repo, 55 feature PRs, ≈$2,700 captured)

| Signal | Baseline |
|---|---|
| stage cost share | execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4% |
| gates (plan-eval + pr-eval) | 30% of spend, ≈$810 |
| split-role red+green (19 issues) | 24% of spend, ≈$650 |
| B-over-D ceremony premium | ≈$728 foregone |
| median PATH B PR | 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC |
| pr-eval yield (Jun→Sep, 3 repos, 56 evals) | 0 Flagged (pilot era 2/30) |
| plan-eval Revise-first rate | 35% pipeline · 21% bomon-web · 28% work-orchestrator |
| staging CI after merge | 2 red / 398 pushes, none since June |
| known escape class | issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise |
| prose-pinning tests | 165 grep `SKILL.md`, 38 grep `CLAUDE.md` |
| issue-number archaeology in skill bodies | 351 refs, 130 distinct |
| doc/behaviour contradictions (one session) | 4 |

`scripts/run-retro.sh` (cycle 0 deliverable) recomputes these each cycle; each cycle's issues must move a named row (cycle 0 exempt).

## Hypothesis backlog (ranked; re-ranked each cycle)

1. Calibration slate + sandbox (`rjskene/pipeline-calib`, spec §8) — unblocks every cost/latency verdict.
2. Trust profile `PIPELINE_TRUST_PROFILE=strict|lean` in the dispatch/stage-model resolvers; `lean` for strong executors outside W2. Metric: $/PR, wall-clock; escapes not up.
3. fullsend prose diet 26k → ≤10k tokens. Metric: mass; orchestrator cost share.
4. Env-hermeticity sweep of test wrappers (the 1199 class). Metric: escapes found.
5. pr-eval retarget: test-validity + hermeticity over plan-compliance checklists. Metric: gate yield on planted-defect calibration issues.
6. Doc contradictions (release-cadence first-parent claim; `superpowers:code-reviewer` ref; cost-architecture premise). Metric: friction.
7. `restrict_paths.py` false positives — `human`-labelled, operator applies.
8. Prose-pinning tests → behaviour tests as suites get touched. Metric: mass.
9. B→D routing under-routes tiny fixes. Metric: $/PR.
10. Split-role only under W2 for strong executors. Metric: $/PR; escapes.
11. Superpowers necessity (operator ask, 2026-09-05): drop or gate the inner superpowers invocations (brainstorming / writing-plans / TDD / systematic-debugging / code-reviewer) per stage for strong executors (Fable/Opus) — they may add prose + tokens without measurable quality gain. Shape: per-stage `PIPELINE_SUPERPOWERS_*` knob or trust-profile row (ties to #2 `lean`). Metric: $/PR, wall-clock, gate yield, escapes not up; measured by calibration run (spec §8).
12. Guard-hook necessity (operator ask, 2026-09-05): are the PreToolUse/Stop restriction hooks (`restrict_paths.py` boundary, `block_deletions.py`, `enforce-base-branch.py`, `enforce-path-c-delegation.py`, `check-ci-skip-markers.py`, `enforce-ci-wait.py`, `enforce-comment-trust.py`) still earning their keep with strong executors? Per spec §6 the loop may NOT self-modify `restrict_paths.py` / `block_deletions.py` — those two route to `human`; the others are in scope. Metric: friction (`BLOCKED` denials per cycle, false-positive share, e.g. the §3.3 main-checkout read blocked at bootstrap) vs. incidents each hook actually prevented (git log / tracker evidence); a hook with zero true positives over N cycles is a deletion candidate, measured by calibration (`strict` + sonnet must still hold).

## Cycle issues

Cycle 0 (2026-09-05, all PATH-hint B, 0 PATH C):
- #1272 — `scripts/run-retro.sh` scorecard/deltas/friction/pending verdicts + `docs/retros/` layout
- #1273 — `skills/evolve/SKILL.md` start/stop/pause/resume/status (≤3k tokens) + `HARNESS-FRICTION:` capture in fullsend dispatch prompts + spec §3.2/§3.3 sync
- #1274 — housekeeping: retire `dev/self-audit` + hook, `metrics-snapshot.sh` version, `ci.yml` evolve push, branch-aware `dogfood-refresh.sh`, doctor `|`-split + local-override ordering

## Cycle log

One comment per cycle: issues, verdicts (confirmed / no-effect / regressed), usage snapshot, `HARNESS-FRICTION:` lines.



