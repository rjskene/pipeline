# Harness evolve loop — design

**Date:** 2026-09-05 · **Status:** draft, awaiting operator review · **Entry point:** `/pipeline:evolve`

## 1. Goal

A continuous, self-driving loop in which the orchestrator (Fable, interactive session) improves the
pipeline harness using the harness itself:

```
observe → diagnose → file issues → /pipeline:fullsend → measure → decide → log → observe …
```

Each cycle files a small slate of harness-improvement issues, runs them through the pipeline, then
measures whether the merged changes moved the metric they claimed to move. Confirmed changes become
the new baseline; regressions are reverted through the pipeline; the next cycle runs on the improved
harness. The loop runs until paused by the operator, by the usage gate, or by its own
diminishing-returns rule.

### Non-goals

- Not tied to the nightly `campaign-orchestrator` schedule. The loop runs in an attended orchestrator
  session and paces itself with the usage gate. Signals from other repos are read when present, never
  depended on.
- Not a rewrite of the harness. The loop changes the harness incrementally, one measured slate at a
  time, and is itself bound by the scorecard (a cycle that grows the harness must justify it).
- Weak-model support is preserved, not removed. The `strict` behaviour stays the default for
  sonnet/haiku executors; the loop may only add cheaper lanes for stronger executors and must prove
  the strict lane still works (calibration under sonnet).

## 2. Baseline (from the 2026-09-05 analysis)

Fable-era window (2026-08-01 → 09-05, pipeline repo, 55 feature PRs, ≈$2,700 captured):

| Signal | Value |
|---|---|
| stage cost share | execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4% |
| gates (plan-eval + pr-eval) | 30% of spend, ≈$810 |
| split-role red+green (19 issues) | 24% of spend, ≈$650 |
| B-over-D ceremony premium | ≈$728 foregone (breakeven table) |
| median PATH B PR | 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC |
| pr-eval yield (Jun→Sep, 3 repos, 56 evals) | 0 Flagged (pilot era: 2/30) |
| plan-eval Revise-first rate | 35% pipeline · 21% bomon-web · 28% work-orchestrator |
| staging CI after merge | 2 red in 398 pushes, none since June |
| known escape | #1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise |
| harness mass | 18 skills, 55k words (fullsend ≈26k tokens, evaluate-issue-pr ≈13k, execute ≈9k) · 84 scripts (20k LOC) · 14 hooks (5k LOC) · 405 tests (69k LOC) |
| prose-pinning tests | 165 grep `SKILL.md`, 38 grep `CLAUDE.md` |
| issue-number archaeology in skill bodies | 351 refs, 130 distinct |
| doc/behaviour contradictions found in one session | release-cadence first-parent claim · `superpowers:code-reviewer` reference · cost-architecture "attended" premise · `pipeline:tdd-implementer` namespace hook silently inert |

These numbers are cycle 0's scorecard baseline; `run-retro.sh` recomputes them each cycle.

## 3. Runtime

### 3.1 Session mode

The loop runs in the orchestrator session, in this working tree, with `/pipeline:fullsend` executing
each slate inline exactly as today. Cycles run back to back inside one invocation
(`/pipeline:evolve [--cycles N]`). State is durable on GitHub (tracker issue + labels) and in
`docs/retros/`, so auto-compaction or a killed session is recoverable with `/pipeline:evolve resume`.

### 3.2 Integration branch `evolve`

All loop work lands on a dedicated integration branch cut from `origin/staging` tip. The existing
`next` branch is **not** reused — it carries 52 unmerged codex-plugin commits and is routed by the
`next`-label machinery (#1131/#1148), which the loop does not need.

- **Branch:** `evolve`, created once from `origin/staging`, pushed, never deleted at merge-back.
- **Base flip:** while the loop is active the live `pipeline.config` has `PIPELINE_BASE_BRANCH=evolve`
  and the working tree is checked out on `evolve`. Every existing mechanism follows the base
  variable — `setup-worktree.sh --base`, the `.claude/base-branch` file `enforce-base-branch.py`
  reads, `auto-merge-gate.sh`'s `baseRefName == $PIPELINE_BASE_BRANCH` check, fullsend's inter-wave
  pull, the status branch check. No label routing, no per-issue special case.
- **CI:** `ci.yml`'s `pull_request` trigger has no base filter, so PRs into `evolve` get the full
  check rollup the auto-merge gate requires. Pushes to `evolve` do not run CI; cycle 0 adds `evolve`
  to the push trigger so the post-merge base is exercised too.
- **Releases:** release-please tracks `main` only. Nothing on `evolve` can cut a release.
- **Forward-sync:** at step 0 of every cycle, `git merge origin/staging` into `evolve` when staging
  has advanced. Conflicts are resolved in-session immediately; small and frequent beats large and
  rare at merge-back. (`dev/hooks/dogfood-refresh.sh` runs `merge --ff-only origin/staging` at
  SessionStart; on a diverged `evolve` that is a silent no-op, before divergence it is the same
  forward-sync — harmless either way.)
- **Merge-back** (`/pipeline:evolve pause`): finish or cleanly abort the in-flight cycle → forward-sync
  → open PR `evolve → staging` whose body lists the cycles' merged PRs and the scorecard delta →
  `gh pr merge --merge` (merge-commit per #459, **no** `--delete-branch`) → restore
  `PIPELINE_BASE_BRANCH=staging` → `git checkout staging && git pull --ff-only` → hand back to the
  operator (release cut stays a manual `docs/release-cadence.md` step). Resuming later starts with a
  forward-sync.

### 3.3 Shared plugin root — operator preconditions

The dogfood install is a symlink (`~/.claude/plugins/cache/claude-pipeline-local/pipeline/0.23.24 →
/home/rjskene/claude-pipeline`). **Whatever branch this working tree has checked out is the harness
for every session on this host.** Two consequences the operator must handle before the loop starts;
both are outside the pipeline repo boundary, so the loop reports them rather than editing them:

1. **`~/campaign-orchestrator/repos/40-pipeline.conf` must be `ENABLED=false` while the loop is
   active.** Its `run-one-campaign.sh` runs `git checkout staging && git pull` *in this directory* at
   22:00 CT, which would yank the working tree off `evolve` mid-loop.
2. **Other slates (work-orchestrator, bomon-*) will run on the `evolve` harness** while the loop is
   active. Either accept them as live canaries (the retro reads their outcomes read-only) or disable
   them for the duration. Operator's call; the loop's own fullsend runs and the calibration slate are
   the primary canaries regardless.

`/pipeline:evolve` step 0 checks both: it refuses to start if the `40-pipeline` conf is enabled, and
prints the canary status of the others.

## 4. Cycle

```
0 gate      paused label? → stop. usage projection (§5) → pause or continue.
            forward-sync evolve from origin/staging. read tracker: pending verdicts, backlog.
1 observe   bash scripts/run-retro.sh --cycle N   (≤60 lines: scorecard, deltas, friction, pending verdicts)
2 diagnose  resolve pending verdicts from cycle N-1 (§7). rank backlog vs scorecard. pick ≤3.
3 file      create-issues body template + required fields (§6). labels: evolve, cycle:N, path hint.
4 run       /pipeline:fullsend <issues>            (usage gate governs waves as today)
5 measure   run-retro.sh --cycle N --post: mass + friction now; cost/latency/escape verdicts
            deferred to cycle N+1 step 2 unless the issue requested a calibration run (§8).
6 decide    regressed → revert via /pipeline:hotfix --auto-merge, file follow-up if hypothesis holds
            no-effect → log, backlog entry demoted; confirmed → new baseline row
7 log       cycle comment on tracker; docs/retros/cycle-NN.md committed to evolve
            (`docs(evolve): cycle NN retro`, tokenomics-doc precedent); usage snapshot recorded.
→ 0         unless --cycles reached or diminishing-returns rule fires (§9)
```

Cycle wall-clock target: 1–2 h (≤3 PATH B issues ≈ 45 min each in waves of 2).

## 5. Usage gating (same substrate as campaign)

- **Decision line:** `scripts/usage-gate.sh` at step 0 and again before step 4. `pause-5h` → arm the
  recurring re-check cron via `scripts/arm-usage-resume-cron.sh --resume-command "/pipeline:evolve resume"`
  and yield (never `ScheduleWakeup`, per the fullsend contract). `halt-7d` → stop loudly, never
  auto-resume. `skip` → proceed only if it is not the resume path (R4). Inside step 4 fullsend's own
  wave-boundary gate applies unchanged.
- **Projection (anticipate, don't just react):** step 7 records the gate's `five_hour` and
  `seven_day` percentages at cycle start and end. `EST5` / `EST7` = median per-cycle delta over the
  last three cycles with a non-negative delta (window rollover makes a delta unusable); defaults
  before any data: `EST5=30`, `EST7=8`. Step 0 starts a cycle only when
  `five_hour + EST5 ≤ threshold` **and** `seven_day + EST7 ≤ threshold`. Otherwise it treats the
  state as `pause-5h` with `resume_at` = the gate's five-hour reset. Threshold is
  `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default 85), same knob as campaign.
- **Token discipline in the orchestrator:** the retro is computed by script and returns a bounded
  summary; plan/PR/eval bodies are never pasted into the orchestrator context; agent reports stay
  terse (#648). Cycle boundaries are the compaction seam — state lives on GitHub so an auto-compact
  mid-cycle is recoverable.

## 6. Issue contract

Every issue the loop files uses the create-issues body template (Context / Scope / Affected areas /
Notes) plus a mandatory `## Evolve` block:

```
## Evolve
- Cycle: N
- Hypothesis: <one sentence, falsifiable>
- Metric: <scorecard row> · expected delta: <direction + magnitude>
- Measured by: retro (next cycle) | calibration run | immediate (mass/friction)
- Prose budget: net skill-prose tokens ≤ 0  (or: +<n> because <reason>)
<!-- pipeline:path-hint=A|B|C|D -->
```

Labels: `evolve`, `cycle:N`. Caps per cycle: ≤3 issues, ≤1 PATH C. Disallowed: new tests that grep
`SKILL.md`/`CLAUDE.md` prose (behaviour tests only); any change to `hooks/restrict_paths.py`,
`hooks/block_deletions.py`, or auth/credential surfaces — those route to the `human` label via the
existing W2 carve-out and wait for the operator.

## 7. Scorecard and verdicts

| Row | Direction | Source | Regressed when |
|---|---|---|---|
| $ per merged PR, tokens/LOC (PATH B median) | down | `cost-latency-report.sh --emit-rows-json` scoped to cycle issues; calibration | calibration cost > baseline +15% |
| wall-clock per PR | down | issue created→closed; calibration | calibration time > baseline +15% |
| escapes | not up | reverts/hotfixes in cycle; Step 6b CI-fix repairs; calibration reference-test failures; later fix PR touching files changed in previous cycle | any attributable escape |
| harness mass | down | skill/agent prose bytes; test count; prose-pinning tests; hooks LOC; issue refs in skill bodies | any increase not justified in the issue |
| friction | down | hook denials (`BLOCKED` in cycle transcripts); `HARNESS-FRICTION:` lines from agent reports; compactions per cycle; hotfix/manual-merge/`human` uses | rising over two cycles |
| gate yield | informative | Flagged/evals, Revise/plans | — |
| weak-model pass | must hold | calibration slate green under `strict` + sonnet | any calibration failure |

**Verdict timing.** Mass and friction are judged at step 5 of the same cycle. Cost, latency and
escape claims are judged at step 2 of the *next* cycle (one cycle of real-work data) or immediately
when the issue requested a calibration run. Verdicts: `confirmed` (moved as claimed), `no-effect`
(within noise), `regressed` (moved against, beyond the row's threshold).

**Friction capture.** Every dispatch prompt (plan, execute, eval) gains one instruction: end the
final report with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines.
The orchestrator appends them verbatim to the cycle's tracker comment. The orchestrator records its
own friction the same way. This is the qualitative input the metrics cannot see (stale prose, hook
false positives, missing agent types).

## 8. Calibration slate (cycle 1 deliverable)

Real-work retros cannot isolate cause: the workload differs every cycle (August per-PR cost ranged
$14–$158). The calibration slate holds the inputs fixed so the harness version is the only variable,
and doubles as the end-to-end regression suite the 405 unit tests are not (the
`pipeline:tdd-implementer` namespace defect sat for months with green unit tests).

- **Sandbox repo:** `rjskene/pipeline-calib`, a small purpose-built consumer project (scripts, tests,
  docs, CI workflow, `pipeline.config`, labels seeded by `/pipeline:init`), 2–5k LOC. Cloned under
  `~/.claude/calib/pipeline-calib` — inside the boundary `restrict_paths.py` already allows, so no
  hook change.
- **Slate:** five template issues committed in the sandbox at tag `calib-base`, each with a reference
  test and an expected-files list:

  | Issue | Path | Exercises |
  |---|---|---|
  | stale doc line | A | docs-only routing |
  | one-line script bug, failing test present | D | quick-fix lane |
  | small feature needing a new test | B | full lifecycle, split-role, pr-eval |
  | body with `race`/`auth` vocabulary | B + W2 | carve-out routing to opus |
  | two-directory change | C | per-leaf worktree fan-out, cherry-pick reassembly |

- **Run:** `scripts/calibration-run.sh [--profile strict|lean] [--model sonnet|opus]` force-resets the
  sandbox base to `calib-base`, recreates the five issues, launches a headless
  `claude -p '/pipeline:fullsend <ids>'` from the sandbox directory (its plugin root is the shared
  symlink, so it runs the harness under test), waits, then emits one summary line per issue: cost,
  wall-clock, verdicts, reference test pass/fail, unexpected files. The retro ingests the summary.
- **Triggers:** an issue whose `Measured by:` is `calibration run`; and once per seven cycles under
  `strict` + sonnet for the weak-model guarantee. Not every cycle: ≈$60–120 per run, billed as
  headless usage.

## 9. Guardrails

- **Scope caps** per cycle (§6). **Safety surfaces** never self-modified (§6).
- **Prose budget** enforced by the retro's mass row; a PR that grows skill prose without a stated
  reason is `regressed` and reverted.
- **Auto-revert** through the pipeline: `/pipeline:hotfix --auto-merge` with the revert commit; the
  hotfix lane's audit-anchor issue records why.
- **Diminishing returns:** two consecutive cycles with no `confirmed` verdict → pause, post "need new
  hypotheses" on the tracker, stop.
- **Kill switch:** `paused` label on the tracker issue, checked at step 0; `/pipeline:evolve stop`
  sets it. `--cycles N` bounds an invocation.
- **Mirror check:** the pipeline improving itself on its own repo measures harness-shaped work only;
  the calibration slate on a consumer-shaped sandbox is the anti-mirror, and the weak-model row stops
  the loop from overfitting to Fable.

## 10. Durable state

- **Tracker issue** `evolve: harness loop — cycle log` (label `tracker`, excluded from the action
  queue like every tracker). Body: current mode (`active`/`paused`), scorecard baseline, `## Hypothesis
  backlog` (ranked), `## Rollout sequence` (cycle issues as they are filed). One comment per cycle:
  issues, verdicts, usage snapshot, friction lines.
- **`docs/retros/cycle-NN.md`** on `evolve`: the retro summary plus the diagnose reasoning, so a
  future reader can see why each slate was chosen.
- **Resume:** `/pipeline:evolve resume` reads the tracker and continues at the recorded step.

## 11. Cycle 0 — the loop builds its own tooling

Filed and run through fullsend on `evolve`; no harness behaviour changes yet.

1. `scripts/run-retro.sh` (+ tests, fixtures): scorecard computation over the substrate that exists
   (`agent-costs.jsonl`, verdict comments, git, transcripts for `BLOCKED` and compaction counts),
   `--cycle N` / `--post` modes, bounded output. `docs/retros/` layout.
2. `skills/evolve/SKILL.md`: the cycle above, thin — every step is a script call or a fullsend
   invocation; the skill body targets ≤3k tokens. Start/stop/pause/resume/status subcommands; the
   `pipeline.config` base flip with a backup and a `status` that reports current mode; the
   `40-pipeline.conf` precondition check.
3. Friction capture: the `HARNESS-FRICTION:` instruction in the dispatch prompts; the tracker comment
   shape.
4. Housekeeping the analysis found: delete the dead self-audit inner/outer loop stubs
   (`dev/self-audit/`, dead since 2026-06-30) and their hook; fix `metrics-snapshot.sh`'s permanent
   `pipeline_version=unknown`; add `evolve` to `ci.yml` push branches.

Cycle 0 is the only cycle whose issues are exempt from the "must move a scorecard row" rule; they
are measured by the mass row (net prose ≤ 0 after the self-audit deletion) and by simply working in
cycle 1.

## 12. Cycle 1 candidates (seed backlog)

Ranked by leverage against the baseline; the loop re-ranks each cycle.

1. **Calibration slate + sandbox** (§8) — unblocks every cost/latency verdict.
2. **Trust profile** `PIPELINE_TRUST_PROFILE=strict|lean`, resolved in `resolve-execute-dispatch.sh`
   / `resolve-stage-model.sh` from the executor model the #1186 machinery already picks. `strict` =
   today, default for sonnet/haiku. `lean` for opus-5/fable outside W2: no separate plan-eval on
   A/D; single-agent execute; pr-eval reduced to CI + the deterministic gates + a cheap risk triage
   that escalates to a full Opus review only when warranted. Metric: $/PR, wall-clock; escapes not up.
3. **fullsend prose diet**: 26k → ≤10k tokens by moving history/rationale to docs and duplicated
   bash to scripts. Metric: mass; orchestrator cost share.
4. **Env-hermeticity sweep** of test wrappers (the #1199 class: `_resolve-config.sh` early-return
   tripped by inherited vars). Metric: escapes (false-green suites found).
5. **pr-eval retarget**: test-validity mutation checks and hermeticity over plan-compliance
   checklists. Metric: gate yield on the calibration W2/B issues with a planted defect.
6. **Doc contradictions**: release-cadence first-parent claim; `superpowers:code-reviewer` reference
   in execute-issue-plan Step 8b; cost-architecture Path-2 premise. Metric: friction.
7. **`restrict_paths.py` false positives** (`cd` to configured allow-roots; path-shaped prose) —
   `human`-labelled per §6, filed for the operator, not self-applied.
8. **Prose-pinning tests → behaviour tests** as suites get touched. Metric: mass.
9. **B→D routing under-routes tiny fixes** ($728 foregone). Metric: $/PR.
10. **Split-role only under W2 for strong executors** (24% of spend). Metric: $/PR; escapes.

## 13. Risks and open items

- **Shared plugin root** (§3.3): a broken `evolve` harness affects every session on the host until
  reverted. Mitigation: each cycle's fullsend run is itself an end-to-end test; calibration; auto-revert.
  Residual risk accepted by the operator when enabling the loop with other slates live.
- **Forward-sync conflicts** on skill prose if staging keeps moving. Mitigation: per-cycle sync.
- **Verdict noise** on real-work cost/latency. Mitigation: calibration for any claimed effect; real-work
  deltas treated as `no-effect` unless >30%.
- **Loop measures a mirror**: addressed by §8 and the weak-model row; still worth an operator review of
  the backlog every few cycles.
- **Headless billing** for calibration runs (SDK-credit / API per the 2026-06-15 change) — ≈$60–120 per
  run, bounded by the §8 triggers.
- **`arm-usage-resume-cron.sh`** — verified 2026-09-05: passes an arbitrary `--resume-command`
  through verbatim (`/pipeline:evolve resume` lands in the emitted re-check prompt). Only its `--help`
  banner still says fullsend; cosmetic, folded into cycle 0 item 2.
