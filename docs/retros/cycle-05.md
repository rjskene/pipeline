cycle-issues: 
pending-verdicts: 1300
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 25
friction: harness-friction-window = tracker cycle 4 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: Boot block's `_cpr_dir` "anchors via plugin cache glob" | with `CLAUDE_PLUGIN_ROOT` unset in the subshell it resolved to the cache copy (`~/.claude/plugins/cache/claude-pipeline-local/pipeline/0.23.24/`), not the dogfood working tree; only the sourced `_resolve-plugin-root.sh` then repointed `CLAUDE_PLUGIN_ROOT` to the working tree — a stale cache resolver would silently drive boot.
HARNESS-FRICTION: (orchestrator) backlog #24 assumed subagents "may load fresh skill bodies" | a classify subagent dispatched 20 min after #1292 merged still ran the pre-#1292 Boot fence (reported the stale 0.23.24 cache path) although the on-disk `skills/classify-issue/SKILL.md` carries the anchor and resolves to the working tree when executed directly — subagents receive the SESSION-cached skill body too, so a skill fix cannot be observed by the loop until the session restarts
HARNESS-FRICTION: Boot block's `${CLAUDE_PLUGIN_ROOT:+/home/rjskene/claude-pipeline-evolve/}` implies the env var reaches the Bash subshell | it was unset there — `_cpr_dir` fell through to the `~/.claude/plugins/cache/.../0.23.24/` glob, and only the sourced resolver set `CLAUDE_PLUGIN_ROOT` back to the working tree.
HARNESS-FRICTION: Skill says the path-hint is "the same weight class as the Blast-radius B→D prior" yet also "only breaks ties" and that "LOC is never a classify-time input" for blast-radius, while the rule table's patch-size row scores on LOC | the two priors conflicted on this issue with no stated precedence; resolved by the patch-size row + precedent, not by the skill text.
HARNESS-FRICTION: issue Scope names only `_token-usage-lib.sh` + `capture_agent_cost.py` for the regex table | a third mirror of the same table lives in `scripts/capture-agent-costs.sh:113` and is the one the backfill actually runs
HARNESS-FRICTION: issue asks for a fixture-wide "every sidecar description attributes (0 unattributed)" assertion | the fixture contains a deliberate never-attributing negative control, so literal 0 is unachievable; assertion had to become set-equality with one declared control
HARNESS-FRICTION: issue #1300 `## Scope` says the sweep's "BLOCKING when unset" claim is mirrored in `skills/execute-issue-plan/SKILL.md` and `skills/evaluate-issue-pr/SKILL.md` | neither file contains any exact-match-sweep prose (zero grep hits for `exact-match-guard-sweep`/`no-test-root`); the only mirror is `skills/evaluate-issue-plan/SKILL.md:146`
HARNESS-FRICTION: issue #1300 lists `cost:` rows among the summary lines falling past the ≤60-line relay cap | `cost:` rows are emitted only by `print_post_report` under `--post`, which returns before `apply_bound` is ever called, so they are never truncated
HARNESS-FRICTION: skill Step 4 exact-match sweep + Step 6 draft path assume a real defect exists | the issue's repro premise was falsified during Step 4, leaving only 1 of 6 planned cases RED-able — no skill guidance on planning when the reported bug does not reproduce
HARNESS-FRICTION: background-task output path is spelled under the system temp root | the Read tool is blocked by `hooks/restrict_paths.py` for that exact path, so a backgrounded command's own output file is unreadable from this session
HARNESS-FRICTION: (orchestrator, correction) the cycle-3 comment claimed `plan-waves.sh` over-serialized #1291/#1293 "sharing no file" | the #1298 planner showed both plans touched `tests/config-drift-allowlist.txt`, so the three-wave plan was correct and the orchestrator's hand-run {#1291,#1293} wave was the actual deviation (it merged only because the two edits hit different lines)
HARNESS-FRICTION: skill Step 3 says a non-zero sweep exit means `PIPELINE_TEST_ROOTS` is "unset or misconfigured" and is BLOCKING | `PIPELINE_TEST_ROOTS` is unset on this host and the sweep still returned `REASON=swept` rc=0 — the exact claim #1300 exists to retire, hit live while evaluating #1300
HARNESS-FRICTION: skill says an unset/misconfigured `PIPELINE_TEST_ROOTS` makes `exact-match-guard-sweep.sh` exit 3 (`REASON=no-test-root`) and is BLOCKING | `PIPELINE_TEST_ROOTS` is unset in this repo's `pipeline.config` yet the sweep self-resolved to `tests/` and returned `ROOTS=1 FILES=654 GUARDS=16 REASON=swept` rc=0 — the doc's "unset ⇒ blocking" causal claim does not hold here.
HARNESS-FRICTION: comment template demands TERSENESS (passing rows one line, Recommendations ≤3) | the `## Executable verification` section requires a positive+negative command and observed output per guard claim, so `**Guard claims verified:**` cannot be terse — the two directives pull opposite ways on the same comment.
HARNESS-FRICTION: constraint "Do NOT read any prior agent's conversation history or session logs" | verifying the attribution claims required reading `.claude/logs/subagents.log` (a dispatch-description observability log, not conversation content) — the boundary between "session log" and "observability artifact" is unstated, and the evaluation's strongest evidence came from that file.
HARNESS-FRICTION: prompt said the plan lists `tests/test-cost-latency-report.sh` among RED's files | the plan's `**Shared tests (split-role):** None` block explicitly argues that file needs NO edit; I added Scenario 45c anyway to keep Task 4 test-covered under the no-GREEN-test-edits contract.
HARNESS-FRICTION: prompt's step-1 list omits `tests/test-agent-costs-stage-map.sh` | it is the largest RED surface in the plan (3 positives + interpolated shape + 2 controls + the fixture-wide set-equality).
HARNESS-FRICTION: skill Step 4 says a non-zero sweep exit means "fix `PIPELINE_TEST_ROOTS` for the host before relying on a `None` declaration" | with the var unset the sweep self-defaulted to `tests/` and returned `REASON=swept` rc=0 — exactly the claim this issue exists to retire.
HARNESS-FRICTION: plan Task 2's sample `STAGE_FALLBACK_PATTERNS` regex `\breview[ -]?code[ -]?changes\b` (no gap tolerance) | binding contract required tolerating `#N` between "Review" and "code changes" (`Review #1280 code changes`), so the actual regex used `\breview\b(?:\s+#\d+)?\s+code[ -]?changes\b|\bcode[ -]?review\b`.
HARNESS-FRICTION: my first `scripts/cost-latency-report.sh` edit put an apostrophe (`orchestrator's`) inside a bash single-quoted awk script, prematurely closing the quote and breaking ~145 unrelated test assertions | caught via `bash -n` before running the full suite; rewrote the comment without contractions.
HARNESS-FRICTION: `skills/evaluate-issue-plan/SKILL.md` L146 said an unset `PIPELINE_TEST_ROOTS` makes the sweep vacuous (exit 3, BLOCKING) | with the var unset on this host the sweep returned `EXACT_MATCH_SWEEP=ok ROOTS=1 FILES=654 GUARDS=16 REASON=swept`, rc=0 — the exact claim #1300 retires.
HARNESS-FRICTION: the plan quoted the Arm 3 plan-draft advisory as a measured `10` | the same regex over the host's `.claude/logs/plan-drafts/` now reports 15 (28 drafts) — a plan-measured number over a gitignored append-only directory is stale by the time RED runs, which is exactly why the arm asserts nothing.
HARNESS-FRICTION: the system prompt says to use the session scratchpad directory for all temporary files | `hooks/restrict_paths.py` blocks Read on that path as "outside project boundary", so plan text had to be staged under the project's `.claude/scratch/` instead.
HARNESS-FRICTION: `scripts/run-retro.sh` live mode is documented as needing only `--cycle`/`--tracker` | it silently degrades to an all-empty report (`cycle-issues:` blank, `no cycle window`, no `pending-verdicts:`) unless `PIPELINE_REPO` is exported in the calling shell — the script never sources `pipeline.config`, and every Bash call is a fresh shell.
HARNESS-FRICTION: `grep -F "<pattern>"` is the documented way to match a fixed string | `grep` resolves to `ugrep` here, which parses a leading `-` in the pattern as a flag and errors out; `grep -F -e "<pattern>"` is required.

delta prose-pinning tests/grep claude.md 6 (baseline 38 -> computed 44)
delta harness mass/words 1258 (baseline 55000 -> computed 56258)
delta harness mass/skills 1 (baseline 18 -> computed 19)
delta harness mass/tests loc 8163 (baseline 69000 -> computed 77163)
delta harness mass/hooks loc -1446 (baseline 5000 -> computed 3554)
delta harness mass/scripts loc 2506 (baseline 20000 -> computed 22506)
delta harness mass/hooks -1 (baseline 14 -> computed 13)
delta issue-number archaeology in skill bodies/refs 9 (baseline 351 -> computed 360)
delta issue-number archaeology in skill bodies/distinct 6 (baseline 130 -> computed 136)
delta harness mass/tests 24 (baseline 405 -> computed 429)
delta prose-pinning tests/grep skill.md 15 (baseline 165 -> computed 180)
delta harness mass/scripts 6 (baseline 84 -> computed 90)
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
weak-model pass (strict + sonnet, 5-issue calibration slate): 3/5 reftest (2026-09-06, run #2: wave 1 merged 3/3; #7 D + #8 B unrun — orchestrator held on the template's inert auto-merge=false template knob); cost/wall n/a
loop-own tokens/issue (median, all captured stages): 47.8M (cycle 4: #1299 47.8M · #1300 70.1M · #1298 4.3M plan-only; cycle-3 rows re-attributed by #1299: #1291 56.8M incl. 5 execute leaves + review; scorecard median PATH B PR 23M)

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 3/5

usage: five_hour=3% seven_day=69% threshold=85


## Diagnose

Verdicts carried from cycle 4 (all still pending, each now has a measurement path):
- #1300 (prose-drift bundle) — pending: its friction half needs a fullsend window run by agents that loaded the merged skill bodies; this session predates the merge, so the first clean window is cycle 6 under the wrapper (#1303).
- #1292 (Boot fence anchor) — pending: same session-cache limit; first clean window = cycle 6 under the wrapper.
- #1291 (trust profile) — pending → measurable this cycle: the clone runs `PIPELINE_TRUST_PROFILE=lean` + `PIPELINE_PATH_B_MODEL_EXECUTE=opus` (operator go: "go lean + calib"), and calibration run #3 launched 00:50Z with `--profile lean` on harness 7d9457f (env verified in the sandbox process: TRUST_PROFILE=lean, PATH_B_MODEL_EXECUTE=opus, HEADLESS=true). Finding while arming it: the live `pipeline.config` had `set +a` at line 78 with 8 knobs after it — `PIPELINE_TRUST_PROFILE` was never exported, so the resolvers answered `REASON=explicit-knob` (strict) under a lean config; fixed on the host, guard filed as #1305.
- #1285 / #1286 (calibration launcher, headless contract) — pending → resolved at Step 5 from run #3's CALIB block.

Slate rationale (operator-set, 2026-09-08): the loop needed a manual `exit` + relaunch per cycle because skill bodies are session-cached (docs: "stays across turns (not re-read from disk)"; `/reload-plugins` is operator-only) — #1303 makes each cycle a fresh `claude -p` process (backlog #24). The `human` lane parked #1294/#1282 forever — #1304 replaces it with behaviour-test invariants + a gate token (backlog #7/#27; manual-merge lane rejected by the operator as a non-loop). #1305 is the config class found while arming lean. Caps: 2 B + 1 D, 0 C.

Measurement note: classify/plan/plan-eval run concurrently with calibration run #3; execute waits for the CALIB block so the sandbox's `wall=` rows are not contended.

## Post

**Merged 3/3.** #1305 (D, sonnet single) PR #1307 → 3daa124 · #1303 (B, `REASON=lean-single`, opus single) PR #1308 → 16df628 · #1304 (C, 4 leaves + 1 review-fix leaf, opus) PR #1309 → 2a4cae2. Wave 1 = {#1303, #1305}, wave 2 = {#1304}; base-ref drift guard `BASE=ok` both waves; clean-main `untracked-only` throughout.

**Cost rows (Step 5, backfill ran):** #1303 76.4M stages=5 (4 plan rounds ≈ 100k tokens each — evaluator found a new defect in each round's newly added scenarios) · #1304 64.6M stages=5 (3 plan rounds; 5 leaves + orchestrator review + pr-eval) · #1305 15.5M stages=4 (plan-eval skipped under lean). Loop-own median 64.6M (cycle 4: 47.8M, +35%; driven by plan rounds, not execute).

**Calibration run #3** (`--profile lean`, sonnet session, opus PATH B executor via env, harness 7d9457f, 00:50–02:07Z): `reftest-pass=2/5 wall=4577` — #14 A merged reftest=fail · #15 D pass · #17 B pass (+1 unexpected file `docs/architecture.md`) · #18 B pr-open · #16 B unrun. The run was truncated by Claude Code print mode ("Background tasks still running after 600s; terminating") while the orchestrator waited on #18's evaluator — filed #1306 (cycle 6). No held question (run #2's failure mode) → #1285 and #1286 confirmed. The one same-input signal: the docs-only issue passed its reference test under strict (run #2) and failed it under lean with plan-eval skipped for PATH A → attributable escape → #1291 lean arm **regressed** (§7); the knob is opt-in, so the revert is the operator config (clone back to `strict` after this cycle's merges), not a code revert — strict is byte-identical to pre-#1291. Wall/cost comparisons are confounded (truncation + concurrent classify/plan agents on the account).

**Lean live:** #1303 dispatched single-role (`SPLIT_ROLE=false REASON=lean-single`) only after the `set +a` fix — the profile had been invisible to the resolvers (#1305). The orchestrator-owned code review caught two real wrapper bugs before merge (bodyless tracker read counted as a completed cycle; `paused` kill switch failing open) — under strict the split-role RED author would have been the second pair of eyes; under lean the review was. pr-eval added nothing on either B/C PR.

**Escapes:** hotfix 0 · revert 0 · later-fix 0. Observed, not counted by the retro: a suite run from a linked worktree created nine real worktrees + branches in the repo (backlog #36; cleaned by hand). #17's unexpected file in the sandbox is the run-#3 equivalent.

**Mass:** words 56258 → 56401 (+143) · skills 19 · tests 429 → 439 (+10; loc 77163 → 79488) · scripts 90 → 91 (loc 22506 → 22978) · hooks 13 / 3554 loc (unchanged — #1304 touched none) · prose-pinning grep skill.md 180 → 182, claude.md 44 → 46 · archaeology refs 360 → 361.

**Friction:** 45 `HARNESS-FRICTION:` lines (window: this cycle's classify/plan/eval/execute/pr-eval agents + orchestrator). Recurring classes: `--json comments` prescribed by classify/plan-eval/pr-eval prose (session-cached bodies; #1300 landed mid-cycle-4), restrict_paths path-shaped-text blocks (#1282, now `evolve`), plan-round churn (backlog #38), in-flight-head protocol (backlog #37).

**Verdicts:** #1305 confirmed (lean-single fired ≥1; 8 stranded knobs → 0, guarded) · #1285 confirmed · #1286 confirmed · #1291 regressed (lean arm) · pending: #1303 (first wrapper-driven cycle), #1304 (human uses next cycle; #1294/#1282 relabelled `evolve`), #1300 and #1292 (first fresh-session window).

**Usage:** start five_hour=3 seven_day=69 → end five_hour=61 seven_day=79 (includes calibration run #3).

**Hand-off:** the session-per-cycle wrapper is merged — the next cycles run as `bash scripts/evolve-loop.sh --cycles N` from the clone root (fresh `claude -p` per cycle, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, projection-gated pauses).
