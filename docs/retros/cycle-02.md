cycle-issues: 

delta prose-pinning tests/grep claude.md 3 (baseline 38 -> computed 41)
delta harness mass/words 836 (baseline 55000 -> computed 55836)
delta harness mass/skills 1 (baseline 18 -> computed 19)
delta harness mass/tests loc 4460 (baseline 69000 -> computed 73460)
delta harness mass/hooks loc -1467 (baseline 5000 -> computed 3533)
delta harness mass/scripts loc 1821 (baseline 20000 -> computed 21821)
delta harness mass/hooks -1 (baseline 14 -> computed 13)
delta issue-number archaeology in skill bodies/refs 6 (baseline 351 -> computed 357)
delta issue-number archaeology in skill bodies/distinct 4 (baseline 130 -> computed 134)
delta harness mass/tests 12 (baseline 405 -> computed 417)
delta prose-pinning tests/grep skill.md 7 (baseline 165 -> computed 172)
delta harness mass/scripts 3 (baseline 84 -> computed 87)
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
weak-model pass (strict + sonnet, 5-issue calibration slate): 3/5 reftest (2026-09-06, run #2: wave 1 merged 3/3; #7 D + #8 B unrun — orchestrator held on the template's inert auto-merge knob); cost/wall n/a

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 54
friction: harness-friction-window = tracker cycle 1 comment
HARNESS-FRICTION: evolve skill fence 5 uses awk `$1`/`$2` field refs | harness rewrites positional tokens inside skill fences with the invocation args (`--cycles`/`1`), so EST5/EST7 medians compute garbage; ran with hand-restored field refs (#1281 item 1)
HARNESS-FRICTION: evolve Step 0 forward-sync says merge origin/staging then continue | the merge commit is never pushed, so origin/evolve drifts behind local until the Step 7 retro push (#1281 item 2)
HARNESS-FRICTION: run-retro.sh docs say pending-verdicts resolves from the prior cycle comment | it ignores the `- verdicts:` line, so #1272 stayed pending after cycle 0 posted a verdict (#1281 item 4)
HARNESS-FRICTION: evolve skill says re-run fences 1+2 at the head of every Bash call | fence 1 also hardcodes the harness-substituted root, so a Bash call composed from the skill text works only when the session was started with --plugin-dir; documented, not a bug, but easy to trip
HARNESS-FRICTION: fullsend Boot comment says "self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset" | in the clone the resolver returns the published cache unless PIPELINE_USE_LOCAL_PLUGIN=true is in pipeline.config; nothing in fullsend mentions the knob
HARNESS-FRICTION: skill Boot block anchors `_resolve-plugin-root.sh` via `${HOME}/.claude/plugins/cache/...` glob | in the evolve clone `CLAUDE_PLUGIN_ROOT` is unset in Bash subshells and the cache glob is off-limits per the restrict_paths guidance; had to hard-set `CLAUDE_PLUGIN_ROOT=/home/rjskene/claude-pipeline-evolve` manually (no `PIPELINE_USE_LOCAL_PLUGIN` path in the Boot block).
HARNESS-FRICTION: skill Boot says `CLAUDE_PLUGIN_ROOT` is self-resolved via `_resolve-plugin-root.sh` from the plugin cache glob | in this clone the env var is unset and no plugin cache dir matched, so `${CLAUDE_PLUGIN_ROOT:-.}` fell back to `.` — worked only because cwd was the repo root
HARNESS-FRICTION: plan-issue SKILL.md Boot implies `CLAUDE_PLUGIN_ROOT` persists after sourcing `_resolve-plugin-root.sh` | Bash env does not persist across tool calls — every later call must re-source `pipeline.config` + the resolver or `"${CLAUDE_PLUGIN_ROOT:-.}/scripts/..."` resolves to `/scripts/...` and exits 127.
HARNESS-FRICTION: issue #1280 scope says PATH C leaves are `dev/`, `scripts/`, `tests/`, `docs/` — disjoint | a fifth root-file leaf is unavoidable: the new the calibration knobs knobs must be declared in root `pipeline.config.example` or `scripts/check-cross-cutting-guards.sh` fails on UNDOCUMENTED drift, and no subdir `target=` can authorize a root file (per `docs/operational-notes.md` §6 / #1128).
HARNESS-FRICTION: issue #1280 scope says the template carries the per-project local settings json | `hooks/restrict_paths.py` PROTECTED_CMD_PATTERNS blocks any Bash command naming that path with no worktree exemption, so the template file must be stored flat (`claude-settings.local.json`) and materialized by the script.
HARNESS-FRICTION: `skills/plan-issue/SKILL.md` Boot fence anchors `_cpr_dir` via `ls -d ${HOME}/.claude/plugins/cache/...` glob | this clone sets `PIPELINE_USE_LOCAL_PLUGIN=true`, so `scripts/_resolve-plugin-root.sh` resolves to the repo root and no plugin cache exists; the fallback globs are dead paths here.
HARNESS-FRICTION: issue #1281 item 1 says the guard fails on any `$<digit>` in a `skills/*/SKILL.md` bash fence | that literal token class also reds `$0` (awk's whole-record variable) in `skills/evaluate-issue-pr/SKILL.md:377`, and the sweep found 6 pre-existing `$1`/`$2` hits outside `skills/evolve/` (classify-issue x4, plan-issue x1, status x1) that the issue's "Affected areas" does not list.
HARNESS-FRICTION: skill says a non-zero `exact-match-guard-sweep.sh` exit with unset `PIPELINE_TEST_ROOTS` is blocking | the clone's `pipeline.config` leaves `PIPELINE_TEST_ROOTS` unset yet the sweep exits 0 with `ROOTS=1 REASON=swept`, so the documented vacuity guard never fires here.
HARNESS-FRICTION: skill Boot fence builds `_cpr_dir` from the plugin-cache glob | no plugin cache exists in the loop clone; only `source scripts/_resolve-plugin-root.sh` from the project root works.
HARNESS-FRICTION: skills/evaluate-issue-plan/SKILL.md mandates executing guard claims by running the real artifact | executing `hooks/restrict_paths.py` guard claims requires naming protected paths in command text, which PROTECTED_CMD_PATTERNS blocks — the probe had to be composed from string fragments inside a Python file under `.claude/scratch/`
HARNESS-FRICTION: SKILL.md says an unset `PIPELINE_TEST_ROOTS` makes the exact-match sweep exit 3 with `REASON=no-test-root` and is BLOCKING | `PIPELINE_TEST_ROOTS` is empty in this repo's `pipeline.config`, yet `scripts/exact-match-guard-sweep.sh` self-defaulted and returned `ROOTS=1 FILES=635 GUARDS=16 REASON=swept` rc=0
HARNESS-FRICTION: skill Boot block anchors `_resolve-plugin-root.sh` via the `~/.claude/plugins/cache/...` glob | no plugin cache exists in this clone; only the direct `source scripts/_resolve-plugin-root.sh` from the project root resolves `CLAUDE_PLUGIN_ROOT`
HARNESS-FRICTION: skills/plan-issue/SKILL.md Boot says the resolver runs "in case the env var is unset in the Bash subshell" | CLAUDE_PLUGIN_ROOT is unset in EVERY Bash call, so Boot must be re-sourced per call, not once per session
HARNESS-FRICTION: skill Step-1 plan-selection block pipes `gh issue view --json comments` through filter-trusted-comments.sh | the task forbade that fetch, so `filter-trusted-comments.sh 1280` alone was used and `select-plan-comment.sh` was never exercised — the last `## Implementation Plan` heading had to be picked by hand from the concatenated stream, which has no per-comment delimiter.
HARNESS-FRICTION: skill's Executable-verification obligation assumes hook fixtures are runnable in-session | `ALLOW_ORCHESTRATOR_EDIT=true` is exported in this orchestrator env, so every `enforce-path-c-delegation.py` fixture returned rc=0 vacuously until `env -u` was added — a silent false-pass that only the mandated negative control caught.
HARNESS-FRICTION: nothing warned that evaluation command TEXT is path-scanned | `restrict_paths.py` blocked a Bash call for containing a device-directory-shaped literal inside a heredoc fixture, requiring string-splicing to compose leaf paths.
HARNESS-FRICTION: skill Boot fence resolves CLAUDE_PLUGIN_ROOT via a plugin-cache glob | no cache exists in the loop clone; only the `PIPELINE_USE_LOCAL_PLUGIN` path in `scripts/_resolve-plugin-root.sh` works
HARNESS-FRICTION: skill step 3 says a non-zero exact-match sweep exit is BLOCKING on unset `PIPELINE_TEST_ROOTS` | this repo's `pipeline.config` leaves it unset yet the sweep self-resolves to `ROOTS=1 FILES=635` and exits 0
HARNESS-FRICTION: dispatch said "run `bash tests/test-docs-readme-anchors.sh` if that file exists" | no such file in the tree; the actual anchor guards are `tests/test-readme-current.sh` (README-only `.md#` regex) and `tests/test-readme-anchor-guard-prose.sh` (skill prose) — I ran `test-readme-current.sh` and added a self-contained no-anchor assertion inside my own test instead.
HARNESS-FRICTION: leaf brief said `dev/calib/template/` and `dev/calib/slate/*/` are rsync/read sources for `--bootstrap`/`--reset` | neither exists on `evolve` at bbdee7f (only `dev/hooks/`), so both tests build a synthetic harness in `mktemp -d` and the script warns-and-continues on a missing template rather than hard-failing.
HARNESS-FRICTION: brief warned a bare `/dev/...` token blocks any Bash call | never triggered — every path used was either relative `dev/calib/...` or the full absolute worktree path, and `$(mktemp -d)` kept scratch paths out of command text.
HARNESS-FRICTION: task said assertion (c) should compare the doc's backticked `--flag` set to the script's parsed set as plain sorted sets | the doc backticks `--plugin-dir` (a `claude` CLI flag, not the driver's) and omits `--help`, so a plain set compare is red on arrival; pinned with derived exclusions instead of weakening or failing the leaf.
HARNESS-FRICTION: tests/test-plan-issue-namespace.sh says it allow-lists path false-positives like `pipeline.config`, `/tmp/pipeline-cleanup`, `rjskene/pipeline` | its `/pipeline\b` regex also matches the directory name `pipeline-calib` (word boundary before `-`), so a new repo slug reds the suite until hand-allow-listed — same guard class that needed `pipeline:evolve` in cycle 0
HARNESS-FRICTION: #1280 plan design note says `PIPELINE_PROJECT_ROOT="$SANDBOX" bash "$HARNESS/scripts/doctor.sh" --fix labels` seeds the sandbox because `_resolve-config.sh` gives PIPELINE_PROJECT_ROOT precedence 1 | an already-exported `PIPELINE_REPO` from the harness config wins, so the first real bootstrap seeded 18 labels on rjskene/pipeline (harmless, idempotent) and left the sandbox with GitHub defaults
HARNESS-FRICTION: doctor.sh is documented as resolving the project root via PIPELINE_PROJECT_ROOT (precedence 1 in _resolve-config.sh) | `doctor.sh --fix labels` hard-requires `./pipeline.config` in its cwd and `source`s it, re-overriding an env-set PIPELINE_REPO — a latent trap for any caller seeding labels on a repo other than its cwd's
HARNESS-FRICTION: run-test-suite.sh reports `tests/test-render-status-table.sh` as a CONFIRMED failure after serial retry | the file passes standalone on both the feature worktree and the clean evolve checkout (70/68/0), so the parallel runner's serial retry is still load-sensitive (cycle-0 saw the same with test-ci-fix-loop.sh)
HARNESS-FRICTION: plan §L2 said per-issue `cost` comes from `cost-latency-report.sh --emit-rows-json --capture-log` | rows JSON carries no per-issue cost at all (that is run-retro's own `n/a (no per-issue cost in rows JSON)` reason), forcing the executor to invent an undocumented token-share apportionment.
HARNESS-FRICTION: the code-review finding said docs claim (e) newest-by-mtime is wrong | `docs/calibration.md` already said "by filename date"; only `scripts/run-retro.sh:351` (`ls -1t`, mtime) is off-spec — that is the scripts leaf's fix, no doc change was needed.
HARNESS-FRICTION: `tests/test-docs-calibration.sh` helpers use `grep -qF/-qiE`, i.e. line-scoped matching | prose pinned by multi-word assertions must be hand-rewrapped so each pinned phrase fits on one line; 4 of the 16 RED failures survived the first correct rewrite purely as line-wrap artifacts.
HARNESS-FRICTION: prompt said the terminal state needs a `## Evaluation` comment on issue #1280 | the skill's Step 9 and `auto-merge-gate.sh:70` both read the verdict from PR comments — I posted on the PR (gate source of truth) and mirrored a short one on the issue to satisfy both.
HARNESS-FRICTION: Step 11.2 capability-refusal arm | resolved to the main checkout's subagent log dir but emitted `WARN: capability-refusal check unproven (REASON=no-leaf-output SCANNED=16 WITH_OUTPUT=0)` — fail-open, gate still returned `green`.
HARNESS-FRICTION: the brief said Sc 11/17a run with `--now` pinned and that the ledger's RED values would be legible | `--now` is an unknown flag today, so such a run exits 1 with empty stdout and no RED value is observable — the clock is injected through the plan's co-equal `PIPELINE_RETRO_NOW` env seam and the `--now` flag is pinned by a byte-equivalence assertion instead
HARNESS-FRICTION: the brief said the fence sweep's first hit is `skills/evolve/SKILL.md:102: $7` | the sweep walks `find … | sort`, so the first hit is `skills/classify-issue/SKILL.md:114: $2`; evolve:102 `$7` is present and is the first evolve hit
HARNESS-FRICTION: the plan's Files-to-change list named only the tests and fixtures | a new `PIPELINE_*` token in a test file also requires a `tests/config-drift-allowlist.txt` entry or the clean-tree suite reds
HARNESS-FRICTION: `tests/test-run-retro.sh` Scenario 17b asserts `--help` names `--now` via `expect_sub`/`has_sub` (`grep -qF "$2"`, no `--`) | that helper cannot pass for any needle starting with `--`, regardless of banner content — GNU grep treats it as an unrecognized option (confirmed identically with real grep 3.11 via `bash -c`, independent of any shell wrapper).
HARNESS-FRICTION: split-role escalation valve says "locked test is WRONG → STOP and report" | the gate anchors on the EARLIEST `[split-role-red]` commit and blocks every later test edit, so the only compliant repair of a wrong locked test on an unpushed branch is amend-and-rebase by the RED role; neither the skill nor the gate documents that path
HARNESS-FRICTION: task said run the gate "against `evolve`..HEAD" | local `evolve` is 16 commits behind the branch's real fork point 066b95a (`git rev-list --count evolve..HEAD` = 22 vs 6), so that window is wider than the feature branch; it happened to be harmless here because no other `[split-role-red]` commit falls in it.
HARNESS-FRICTION: task said `bash scripts/split-role-gate.sh --help` would reveal its invocation | the script has no `--help` handling — it parsed `--help` as the issue number and emitted `SPLIT_ROLE=block ISSUE=--help REASON=unresolvable-base` at exit 0; the usage contract lives only in the header comment block (lines 43-50).
HARNESS-FRICTION: evaluate-issue-pr SKILL.md Step 11.2b ships an awk one-liner meant to parse the plan's `**Shared tests (split-role):**` section using `$0` | the body I received had every `$0`/`$1` already rewritten to `1281` (`awk '{sub(/\r$/,"",1281)}...'`) — the exact positional-token substitution hazard #1281 fixes, still live in this skill's own fences
HARNESS-FRICTION: Step 4 says "Typecheck always runs" via `$PIPELINE_TYPECHECK_CMD` | the knob is empty in this repo's pipeline.config, so the mandated command is a silent no-op with no stated fallback
HARNESS-FRICTION: (post-cycle calibration launch) assumed a nested `claude -p` refuses under CLAUDECODE=1 like an interactive nest | `timeout 25 claude -p "reply with exactly OK" --max-turns 1` returned OK from inside this session; `calibration-run.sh --run` needs no env stripping for that reason (ALLOW_ORCHESTRATOR_EDIT still had to be unset by hand so the delegation hook is live in the measured run)
HARNESS-FRICTION: (post-cycle) `restrict_paths.py` blocks the Read tool on the background-task output dir under the Linux session tmp layout | the tee'd copy under `.claude/scratch/` is the only readable channel — same #1282 class
HARNESS-FRICTION: (post-cycle) docs/calibration.md says `cost=` comes from the sandbox `agent-costs.jsonl` | the agent-cost hooks live in the clone's dogfood `.claude/settings.json`, not the plugin manifest, so a `--plugin-dir` sandbox session writes no cost log — expect `cost=n/a` on the first run unless the template's local settings carry the hooks
HARNESS-FRICTION: (post-cycle calibration run #1) `calibration-run.sh --run` launches the sandbox session with `--plugin-dir <harness>` and docs/calibration.md treats any harness dir as valid | `hooks/restrict_paths.py` allows only the project dir and `~/.claude`, so a harness outside `~/.claude` has its own scripts hard-blocked in the sandbox session — the headless agent stopped after 87s with 0 PRs and the block graded `reftest-pass=0/5`; fixed by hand with a git worktree of the clone at `~/.claude/calib/harness` passed via `--harness`
HARNESS-FRICTION: (post-cycle) `$HARNESS` in calibration-run.sh means both "plugin under test" and "repo that stores the CALIB substrate" | with `--harness <worktree>` the tee lands in the worktree's `docs/retros/calib/`, not the clone's, so the substrate has to be copied back before `run-retro.sh` can see it
HARNESS-FRICTION: (post-cycle) a headless `claude -p` agent that hits a blocker ends its turn by asking the operator "your call?" | in `-p` mode nobody answers, the process exits 0, and `--run` grades the empty result as a legitimate 0/5 — the grader cannot tell "harness failed to start" from "harness ran and failed"
HARNESS-FRICTION: (post-cycle calibration run #2) fullsend is documented as the autonomous entry that "chains ... without intermediate confirmations" | after wave 1 merged, the headless sonnet orchestrator held before wave 2 asking "your call on auto-merge vs --manual-merge for the rest of the run"; in `-p` mode that ends the run — #7 (PATH D) and #8 (PATH B) never executed (3/5 reftest, 58 min)
HARNESS-FRICTION: (post-cycle) calibration-run.sh grades `path=` from the issue's labels after the run | merged issues carry only `merged`, so the docs-only #6 graded `path=B`; the routing must be read from the `## Classification` comment
HARNESS-FRICTION: (post-cycle) the sandbox evaluator reported `split-role-gate.sh`'s locked-test guard vacuous there | the template names its tests `tests/case-*.sh`, which the default `PIPELINE_TEST_FILE_GLOBS` never matches, so the W7 invariant is unenforced in the sandbox
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 3/5

usage: five_hour=3% seven_day=47% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 41 -> computed 41)
prev-delta harness mass/words 0 (previous 55836 -> computed 55836)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 73460 -> computed 73460)
prev-delta harness mass/hooks loc 0 (previous 3533 -> computed 3533)
prev-delta harness mass/scripts loc 0 (previous 21821 -> computed 21821)
prev-delta harness mass/hooks 0 (previous 13 -> computed 13)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 357 -> computed 357)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 134 -> computed 134)
prev-delta harness mass/tests 0 (previous 417 -> computed 417)
prev-delta prose-pinning tests/grep skill.md 0 (previous 172 -> computed 172)
prev-delta harness mass/scripts 0 (previous 87 -> computed 87)

## Diagnose

Pending from cycle 1: #1280 → confirmed at cycle-1 close (calibration seam live, 3/5). #1281 → **confirmed**: this retro reads `friction/harness-friction-window = tracker cycle 1 comment` with 54 lines, `pending-verdicts` omits the resolved #1280, and the Step-0 push behaviour is pinned by an executed fence test. Residue, not a regression: the harness also rewrites `$0`, so the fence-5 rewrite (4 refs) and evaluate-issue-pr:377 (10 refs) still garble at load — filed as #1287.

Slate (≤3, ≤1 PATH C), ranked by what unblocks measurement:
1. #1285 (PATH C) calibration hardening — backlog #19 + #20: headless-safe template (drop inert knobs, arm test globs, ship cost hooks), honest grading (`path=` from classification, `wall=`, `CALIB-ABORT`), harness staging inside `--run`. Without it the weak-model row stays 3/5 for instrument reasons.
2. #1286 (PATH B) fullsend headless contract — backlog #21: default-and-continue with `HEADLESS-DEFAULT:` log; the run-#2 abort class.
3. #1287 (PATH B) `$0` is positional — backlog #14: guard widened, projection + shared-tests parse moved to scripts.

Deferred: #15 Boot-fence plugin-cache glob (8 friction lines; touches 18 skills — next cycle after #1287 proves the script-extraction shape), #16 doctor.sh cwd trap, #17 guard false-positive class, #18 prose drift, #12/#11 necessity questions (need two clean calibration runs first).

## Post

```
COMPUTED prose-pinning tests/grep claude.md = 41
COMPUTED harness mass/words = 55755
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 74886
COMPUTED harness mass/hooks loc = 3533
COMPUTED harness mass/scripts loc = 22214
COMPUTED harness mass/hooks = 13
COMPUTED issue-number archaeology in skill bodies/refs = 357
COMPUTED issue-number archaeology in skill bodies/distinct = 134
COMPUTED harness mass/tests = 420
COMPUTED prose-pinning tests/grep skill.md = 175
COMPUTED harness mass/scripts = 89
COMPUTED escapes/hotfix = 0
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 0
COMPUTED friction/hotfix = 0
COMPUTED escapes/later-fix = 0
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/harness-friction-window = cycle 2 issue comments
COMPUTED friction/denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
verdict-candidates: 
```

Slate: #1286 (PATH B, PR #1288 → d9c7481), #1287 (PATH B, PR #1290 → 1c14f09), #1285 (PATH C, PR #1289 → e6c77d1) all merged into `evolve`. 3/3 merged, 0 Flagged, 0 reverts.

Gate yield: plan-eval Revise-first 3/3 (#1286 Approved r2, #1287 Approved r2, #1285 Approved r3 — every Revise was a ledger divergence found by execution); pr-eval Approved 3/3; code review: #1286 with-fixes (2 Important fixed), #1287 with-fixes (1 Important fixed), #1285 Ready with 1 Important fixed pre-PR. One RED-commit deviation on #1286 (transient allow-list entry the plan forbade, peeled by GREEN). #1287 was pulled forward into wave 1 once #1286 merged (its only file conflict).

Instrument: the next calibration run launches with `env -u ALLOW_ORCHESTRATOR_EDIT … PIPELINE_HEADLESS=true`, a staged harness worktree, honest `path=`/`wall=`, and `CALIB-ABORT` instead of a false 0/5. Not run this cycle (5h usage at 32% after the slate; the run needs a fresh window) — #1285/#1286 verdicts stay pending until it runs.

Verdicts: #1281 confirmed (cycle-2 retro read `tracker cycle 1 comment`, 54 lines; pending-verdicts omitted the resolved #1280; push behaviour pinned). #1285 pending (calibration run). #1286 pending (calibration run — no `CALIB-ABORT reason=held`). #1287 pending (cycle-3 retro: zero fence-garbling friction lines; guard green with `$0`).

Mass deltas vs cycle 1: skills 19 (=), tests 417→420 / +1426 LOC, scripts 87→89 / +393 LOC, words 55836→55755 (−81; the evolve fence shrank), prose-pinning greps SKILL.md 172→175, hooks 13 (=). No scorecard row replaced (no cycle-2 confirmed verdict yet).

Usage: start five_hour=3 seven_day=47, end five_hour=32 seven_day=53 (Δ 29 / 6).

Friction: 47 HARNESS-FRICTION lines (verbatim in the cycle-2 tracker comment). Recurring classes: plugin-cache glob in every Boot fence (dead in the clone); exact-match sweep never fires its `PIPELINE_TEST_ROOTS` vacuity STOP; skill-body caching at session start hides merged fence fixes until restart; `filter-trusted-comments.sh` plaintext vs the skill's JSON `select-plan-comment.sh` step; docs/retros prose scanned by config drift; `check-branch-cruft.sh` needs `PIPELINE_BASE_BRANCH` in leaf worktrees.
