cycle-issues: 

delta prose-pinning tests/grep claude.md 3 (baseline 38 -> computed 41)
delta harness mass/words 755 (baseline 55000 -> computed 55755)
delta harness mass/skills 1 (baseline 18 -> computed 19)
delta harness mass/tests loc 5886 (baseline 69000 -> computed 74886)
delta harness mass/hooks loc -1467 (baseline 5000 -> computed 3533)
delta harness mass/scripts loc 2214 (baseline 20000 -> computed 22214)
delta harness mass/hooks -1 (baseline 14 -> computed 13)
delta issue-number archaeology in skill bodies/refs 6 (baseline 351 -> computed 357)
delta issue-number archaeology in skill bodies/distinct 4 (baseline 130 -> computed 134)
delta harness mass/tests 15 (baseline 405 -> computed 420)
delta prose-pinning tests/grep skill.md 10 (baseline 165 -> computed 175)
delta harness mass/scripts 5 (baseline 84 -> computed 89)
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

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 47
friction: harness-friction-window = tracker cycle 2 comment
HARNESS-FRICTION: evolve skill Step 4 says `Skill(skill: "pipeline:fullsend", ...)` and the skill bodies are read at invocation | Claude Code caches skill bodies at session start, so a session that merged #1281 mid-run still loads the pre-fix evolve/fullsend bodies (the `$1`/`$2` fence) until restart; a haiku probe confirmed the cached body lacks the merged `MED=` line
HARNESS-FRICTION: #1281's fence-5 rewrite uses `split($0,f," ")` / `{v[NR]=$0}` on the assumption that only `$1`–`$9` are substituted | the harness rewrites `$0` too (cycle-1 pr-eval saw `sub(/\r$/,"",1281)` in evaluate-issue-pr), so the projection still needs a hand-composed fence each cycle (#1287)
HARNESS-FRICTION: run-retro full report at `--cycle N>0` echoes every prior-cycle HARNESS-FRICTION line verbatim | with 54 lines the ≤60-line Step-1 relay is almost entirely the echo and the numeric rows scroll out; the report should count them and point at the comment
HARNESS-FRICTION: skill Boot fence resolves `_cpr_dir` via `~/.claude/plugins/cache/...` globs | no plugin cache exists here; only `source scripts/_resolve-plugin-root.sh` from the project root works (as the task prompt pre-warned)
HARNESS-FRICTION: Boot fence says "Bash cwd/env do not persist across calls" | cwd persisted at project root in every call; `source ./pipeline.config` worked without `cd`.
HARNESS-FRICTION: Skill step 4a says list `.claude/scratch/issue-<N>/` populated upstream | dir was absent (standalone invocation has no upstream fetch); treated as no attachments per skill.
HARNESS-FRICTION: skill Boot fence on disk reads `${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}` | loaded text arrived as `${CLAUDE_PLUGIN_ROOT:+/home/rjskene/claude-pipeline-evolve/}` — harness expands env-var tokens inside fences at load, not only positionals (harmless here, supports #1287's premise)
HARNESS-FRICTION: on-disk label-apply fence uses the `"${*}"` rewrite idiom (from #1281) | loaded text rendered it back as `"$1"` — the idiom survives load but is not what the model sees; byte-for-byte "preserve" instruction cannot be honored from the loaded text
HARNESS-FRICTION: Boot fence says anchor via `~/.claude/plugins/cache/...` globs | no cache exists in this clone; `scripts/_resolve-plugin-root.sh` from the repo root is the only live path
HARNESS-FRICTION: issue #1286 said "the fullsend budget test must stay green" | no budget or terseness test pins `skills/fullsend/SKILL.md` at all — the ceiling had to be created by this issue's new test
HARNESS-FRICTION: plan-issue Step 4 says the exact-match guard sweep needs `PIPELINE_TEST_ROOTS` set for a trustworthy `None` | `PIPELINE_TEST_ROOTS` is unset in this repo's `pipeline.config` yet the sweep still exited 0 with `ROOTS=1 FILES=643 REASON=swept`
HARNESS-FRICTION: (orchestrator) retros under docs/retros/ are the loop's own prose and naturally name knobs | `check-config-drift.sh` scans all of docs/, so the cycle-1 retro's mention of undeclared knob tokens turned the clean evolve tip red on `check-cross-cutting-guards.sh` (found by the #1286 planner, hotfixed by rewording)
HARNESS-FRICTION: plan-issue Boot fence resolves the plugin root via `_cpr_dir="${CLAUDE_PLUGIN_ROOT:+…}"` then `${HOME}/.claude/plugins/cache/claude-pipeline{,-local}/pipeline/*/` globs | in the evolve clone both cache globs are dead paths and the `:+` form is a no-op when the var is unset, so Boot resolves nothing; only the direct `source scripts/_resolve-plugin-root.sh` worked.
HARNESS-FRICTION: `tests/test-skill-fence-positional-args.sh` header states `$0` is safe because "neither is an argv index, and the harness substitutes indices only" | the harness rewrites `$0` too — cycle-1 pr-eval received `awk '{sub(/\r$/,"",1281)}'`, which is exactly what #1287 exists to fix.
HARNESS-FRICTION: skill Step 3 says a non-zero `exact-match-guard-sweep.sh` exit is BLOCKING when `PIPELINE_TEST_ROOTS` is unset | the live `pipeline.config` has no `PIPELINE_TEST_ROOTS`, yet the helper self-defaulted to `tests/` and returned `REASON=swept ROOTS=1 FILES=643` rc=0 — the documented `REASON=no-test-root` failure mode did not fire.
HARNESS-FRICTION: issue #1285 says "no `pipeline.config.example` change (all knobs already declared)" | `PIPELINE_HEADLESS` is declared nowhere and `check-config-drift.sh` scans `scripts/ tests/ docs/`, so the token reds the drift floor unless allow-listed or declared — plan routes it through `tests/config-drift-allowlist.txt`
HARNESS-FRICTION: SKILL.md Boot fence anchors `_resolve-plugin-root.sh` via the `~/.claude/plugins/cache/...` globs | no cache exists in the loop clone; only `source scripts/_resolve-plugin-root.sh` from the project root resolves `CLAUDE_PLUGIN_ROOT`, re-sourced per Bash call
HARNESS-FRICTION: `tests/test-calibration-contract.sh` (c) asserts the doc's backticked `--flag` set equals the driver's | any prose mentioning `git worktree add --detach` in backticks would red the pin, so the docs leaf must describe the worktree without backticking git flags — nothing in the skill or doc warns about this
HARNESS-FRICTION: skill Step 1 prescribes `filter-trusted-comments.sh` output feeding `select-plan-comment.sh` in `{comments:[...]}` JSON shape | `filter-trusted-comments.sh <N>` positional mode emits concatenated plaintext bodies, not JSON — jq parse fails, plan had to be located by grepping `^## Implementation Plan` in the text dump
HARNESS-FRICTION: skill says an unset `PIPELINE_TEST_ROOTS` makes the exact-match sweep vacuous and exit 3 `REASON=no-test-root` (BLOCKING) | `PIPELINE_TEST_ROOTS` is unset in this host's `pipeline.config`, yet `exact-match-guard-sweep.sh` defaulted to `tests/` and returned `ROOTS=1 FILES=643 GUARDS=16 REASON=swept` rc=0
HARNESS-FRICTION: CLAUDE.md runtime allow-list says `.claude/logs/` plugin writes are "opt-in via PIPELINE_LOGS_ENABLED (default false)" | plan-issue Step 6 writes the plan draft to `.claude/logs/plan-drafts/` unconditionally, with no gate on that knob (host had it `true`, so the contradiction was latent).
HARNESS-FRICTION: plan-issue Step 4 says a non-zero `exact-match-guard-sweep.sh` exit means "fix `PIPELINE_TEST_ROOTS` for the host before relying on a `None` declaration", implying the var must be set | the var is unset in this repo's `pipeline.config` and the sweep still exited 0 with `ROOTS=1 FILES=643 REASON=swept`.
HARNESS-FRICTION: skill Boot block hardcodes a plugin-cache glob for `_resolve-plugin-root.sh` | no cache exists in the loop clone; only the repo-root `scripts/_resolve-plugin-root.sh` path works.
HARNESS-FRICTION: skill Step 3 sweep says thread `PIPELINE_TEST_ROOTS` from config, non-zero exit is BLOCKING | `PIPELINE_TEST_ROOTS` is unset in this repo's `pipeline.config`, yet the sweep still self-resolved `ROOTS=1 FILES=643` and exited 0.
HARNESS-FRICTION: plan-issue Boot block says `source "$(pwd)/pipeline.config"` then a `_cpr_dir` glob resolver | in this clone `scripts/_resolve-plugin-root.sh` is present at the repo root and resolves `CLAUDE_PLUGIN_ROOT` to the working tree directly, so the cache-glob fallback is dead code here.
HARNESS-FRICTION: skill Step 1 prescribes `gh issue view --json comments` piped through `select-plan-comment.sh` | the task's mandated reader `filter-trusted-comments.sh <N>` emits concatenated plain text, not the `{comments:[...]}` JSON that block needs — plan selection had to be done by heading scan instead.
HARNESS-FRICTION: plan-1286.md Risks says do NOT add a `tests/config-drift-allowlist.txt` entry for the RED window | the dispatch instruction required `check-config-drift.sh` ok at the RED commit, which is only reachable via that entry — the two are mutually exclusive.
HARNESS-FRICTION: plan A5 says extract the PR-eval paragraph with "the `PR-eval` analogue" of the guards' awk | that terminator alone yields a 178-line region (step 7b is not `   **`-indented), so a second numbered-step terminator was required for the assertion to be scoped.
HARNESS-FRICTION: the plan claimed `ROOT="$(cd "$(dirname "$0")/.." && pwd)"` fails with `cd: …/tests/..: No such file or directory` exit 1 | under `bash tests/<file>.sh` (the run-test-suite idiom) it resolves correctly and the file prints `ok`, exit 0
HARNESS-FRICTION: the skill's Boot block sources `${_cpr_dir}scripts/_resolve-plugin-root.sh` from a plugin cache glob | no plugin cache exists in this clone; only the repo-root `source scripts/_resolve-plugin-root.sh` form works
HARNESS-FRICTION: plan-issue SKILL.md step 3b says run `fetch-issue-attachments.sh` for interactive planning | skipped — caller mandated comment reads only via `filter-trusted-comments.sh`; issue has no attachments.
HARNESS-FRICTION: skill Boot block's `_cpr_dir` glob targets `~/.claude/plugins/cache/...` | no plugin cache exists in this clone; only `source scripts/_resolve-plugin-root.sh` from the repo root works.
HARNESS-FRICTION: skill step 3 says a non-zero `exact-match-guard-sweep.sh` exit is BLOCKING when `PIPELINE_TEST_ROOTS` is unset | `PIPELINE_TEST_ROOTS` is empty in `pipeline.config` here, yet the sweep self-resolved a root and exited 0 (`ROOTS=1 FILES=643`), so the blocking branch never fired.
HARNESS-FRICTION: plan-issue Step 6 mandates the `Write` tool ("not heredoc, not echo") for the draft | a verbatim-carry revision of a 45KB plan is only safe when built mechanically (sed extract + asserted single-occurrence replacements + diff against the prior round); retyping it through `Write` risks silent drift, so Bash/python construction was used.
HARNESS-FRICTION: SKILL.md Step 11.2b shared-tests awk uses `$0` written as the issue number (`sub(/\r$/,"",1286)`, `gsub(...,"",1286)`) after slash-command arg substitution | the literal in the skill body is unusable as-is; I had to restore `$0` by hand for the parser to run.
HARNESS-FRICTION: Step 4 says typecheck always runs via `$PIPELINE_TYPECHECK_CMD` | the knob is empty in this repo's `pipeline.config`, so there is nothing to run.
HARNESS-FRICTION: plan Task L2 cycle 1 specified the `gh` stub as `"issue view"*) cat "…/$2.json"` | `$2` is the literal `view` token — `gh issue view <n>` puts the issue number at `$3`, so the specified stub makes the cycle's GREEN unreachable.
HARNESS-FRICTION: plan Task L2 required the `CALIB-TOTAL … reftest-pass=%s/%s` printf literal to stay byte-identical AND an aborted run to print `reftest-pass=n/a` | `%s/%s` cannot render a single `n/a`, so satisfying both needs a second printf placed after the canonical one.
HARNESS-FRICTION: the task brief said a bare `/dev/...` token other than /dev/null blocks the whole Bash command | a measurement command containing `tee /dev/stderr` ran without being blocked.
HARNESS-FRICTION: task said run `bash scripts/check-branch-cruft.sh` | that script aborts with `PIPELINE_BASE_BRANCH unset` in a leaf worktree (no `pipeline.config` there); ran it as `PIPELINE_BASE_BRANCH=staging bash scripts/check-branch-cruft.sh`.
HARNESS-FRICTION: (orchestrator) fullsend Step 6a says run `verify-execute-completion.sh <N>` immediately after the execute batch returns and act on the token | run in the same Bash call a second after `gh pr create`, it returned `ACTION=recover-pr REASON=no-pr` while `check-ci-fix-loop.sh` in the same call already resolved PR=1289; a 5-second re-run returned `complete` — the helper's PR lookup lags PR creation, so an immediate `recover-pr` needs one retry before acting
HARNESS-FRICTION: skills/evaluate-issue-pr/SKILL.md Step 11.2b ships an inline awk in a bash fence whose `$0` refs are the parse contract | the skill body I loaded arrived with every `$0` rewritten to `1287` (e.g. `awk '{sub(/\r$/,"",1287)}'`), so the loaded parser was unusable — exactly the defect this PR fixes; I ran the branch's `scripts/parse-shared-tests.sh` on the plan body instead (`SHARED_TESTS_RAW=''`, matching the plan's `None`).
HARNESS-FRICTION: the loaded skill's Boot block anchors `_cpr_dir` via a plugin-cache glob | no plugin cache exists on this host; `source ./pipeline.config && source scripts/_resolve-plugin-root.sh` from the repo root was required on every call, and `PIPELINE_TYPECHECK_CMD` is empty so Step 4's "typecheck always runs" is a no-op here.
HARNESS-FRICTION: split-role-gate.sh docs say "locked-test-modified — a test file present at the red SHA was changed" | a pure APPEND to a locked test is allowed by design (only `removed > 0` blocks); my first negative control used an append and read as a false pass until I re-ran it with a line removal/rewrite.
HARNESS-FRICTION: skill Step 4 says "Typecheck always runs" via `$PIPELINE_TYPECHECK_CMD` | that knob is empty in this repo's pipeline.config, so the step is a silent no-op with no documented unset branch.
HARNESS-FRICTION: skill Boot block resolves `_cpr_dir` from `${CLAUDE_PLUGIN_ROOT:+...}` then plugin-cache globs | no plugin cache exists in this clone and the env var is unset per-Bash-call, so only the task-supplied `source scripts/_resolve-plugin-root.sh` form works.
HARNESS-FRICTION: task asked to verify `--dry-run` creates no stage dir | the host stage dir already existed from a prior real run, so only the hermetic Scenario-3 assertion could execute that claim.
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

usage: five_hour=4% seven_day=54% threshold=85

prev-delta prose-pinning tests/grep claude.md 0 (previous 41 -> computed 41)
prev-delta harness mass/words 0 (previous 55755 -> computed 55755)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 0 (previous 74886 -> computed 74886)
prev-delta harness mass/hooks loc 0 (previous 3533 -> computed 3533)
prev-delta harness mass/scripts loc 0 (previous 22214 -> computed 22214)
prev-delta harness mass/hooks 0 (previous 13 -> computed 13)
prev-delta issue-number archaeology in skill bodies/refs 0 (previous 357 -> computed 357)
prev-delta issue-number archaeology in skill bodies/distinct 0 (previous 134 -> computed 134)
prev-delta harness mass/tests 0 (previous 420 -> computed 420)
prev-delta prose-pinning tests/grep skill.md 0 (previous 175 -> computed 175)
prev-delta harness mass/scripts 0 (previous 89 -> computed 89)

## Diagnose

Verdicts on cycle-2 issues:
- #1287 **confirmed** — `tests/test-skill-fence-positional-args.sh` green on the evolve tip (23 passed, sweep 0 hits) and the freshly loaded evolve/fullsend bodies parse cleanly after the session restart; the 7 `$0`/positional lines in the cycle-2 window all predate the merge. Re-tested on the cycle-3 friction window at the next retro.
- #1285, #1286 **pending** — both are `Measured by: calibration run`; run #3 not yet run (deferred to keep seven-day headroom for a three-cycle stretch: 7d at 54%).

Instrument findings this step:
- Loop-own cost rows were blind: `agent-costs.jsonl` held 99 orchestrator records and 0 subagent records (every Agent dispatch is async, so the PostToolUse(Agent) payload carries no usage). A hand-run `scripts/capture-agent-costs.sh` backfill added 77 records. Per-issue totals (all stages): 40–87M tokens/issue, median ≈50M vs the scorecard's 23M median PATH B PR — the loop's own issues cost ~2× a typical PR (opus/fable pins + W2 carve-outs). Step 5 must run the backfill.
- `pending-verdicts:` empty for cycle 3 because `run-retro.sh` matches only the literal `Measured by: retro (next cycle)` (backlog #26).
- Friction classes in the cycle-2 window (47 lines): Boot-fence cache glob 10 · positional/`$0` 7 (fixed by #1287) · `PIPELINE_TEST_ROOTS` sweep vacuity 6 · config-drift 4 · plan-comment JSON 3.

Slate (≤3, ≤1 PATH C):
1. Trust profile `PIPELINE_TRUST_PROFILE=strict|lean` in the resolvers (backlog #2, folding #10; spec §12.2 minus the pr-eval triage half) — the first pipeline-cost hypothesis with a $/PR metric; `lean` is exported by `calibration-run.sh --profile lean` but read by nothing today. PATH C.
2. Boot fence self-anchor for `--plugin-dir` clones (backlog #15) — the largest friction class, 19 skills. PATH B.
3. Loop tooling: Step-5 cost backfill + per-issue cost rows, pending-verdicts matcher (#26), `docs/retros/` out of the drift scan (#25a). Unblocks every loop-own $/PR verdict. PATH B.

Deferred: #23 (plan-comment JSON, 3 lines/cycle — root cause found: the skill fence's bare `gh issue view --json comments` is blocked by the dogfood `enforce-comment-trust.py`; fix = a `--json` mode on `filter-trusted-comments.sh`), #17 (sweep vacuity STOP never fires), #3 (fullsend diet), #11/#12.

## Post

Slate 3/3 merged, 0 Flagged, 0 reverts: #1291 PR #1295 (638c897, PATH C, 5 leaves / 7 commits), #1293 PR #1296 (f9c84ba, PATH B split-role), #1292 PR #1297 (81a0470, PATH B split-role). Plan-eval rounds: #1292 1 · #1293 3 · #1291 3 (every Revise item was executed evidence, none prose taste). Orchestrator code review on #1291: 1 Critical (host `pipeline.config` operator line — applied), 0 Important, 5 Minor → backlog #28. pr-eval: 3 Approved, all three evaluators re-derived the RED/GREEN evidence by execution.

Step-5 cost rows (first cycle with them, via #1293's backfill): `#1291 40.0M · #1292 23.3M · #1293 67.3M`, loop-own median 40.0M vs the scorecard's 23M median PATH B PR. #1291's row is undercounted — its five `target=` execute leaves and the code review never attributed (backlog #29). #1293 (23.3M planned as PATH B) cost 2.9× #1292 because of two extra plan rounds and the 12-hour RED stall.

Mass deltas Step 1 → Step 5: words 55755 → 56150 (+395), tests 420 → 427, tests LOC 74886 → 76273, scripts 89 → 90, scripts LOC 22214 → 22425, prose-pinning grep skill.md 175 → 178, claude.md 41 → 44, issue refs 357 → 359. Hooks unchanged (13 / 3533).

Findings filed outside the slate: #1294 (`human`) — four PreToolUse guards exit 1 on BLOCKED, which Claude Code treats as non-blocking; proven live (`rm -rf ./nonexistent-probe` ran; `gh issue view --json comments` ran) and by the docs. Friction: 42 HARNESS-FRICTION lines this cycle (12 Boot-fence cache-glob/stale-cache lines — the class #1292 closes; 4 scratchpad/Read-tool boundary; 3 `bash a.sh b.sh` glob-as-args; the rest single). Wall-clock: the #1293 RED agent returned 12.1 h after dispatch (blocked on a refused heredoc, then parked until the next user prompt); `plan-waves.sh` serialized #1291/#1293 needlessly (run edge-respecting by hand).

Verdicts: #1287 confirmed (guard 23/0, fresh-loaded fences parse; the 7 `$0` lines in the cycle-2 window predate the merge) · #1293 confirmed (per-issue cost rows 0/3 → 3/3; `verdict-candidates: 1293 1292 1291` now lists every retro-measured issue) | pending: #1285, #1286 (calibration run #3), #1291 (calibration `--profile lean` paired with an opus executor knob — see backlog #28 — plus cycle-4 cost rows), #1292 (cycle-4 friction window: Boot-fence lines 12 → 0).

Usage: start five_hour=4 seven_day=54 → end five_hour=3 seven_day=63 (a 5h reset fell inside the 13-hour cycle; the seven-day delta is +9).
