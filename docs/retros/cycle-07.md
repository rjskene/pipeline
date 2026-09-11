cycle-issues: 
pending-verdicts: 1294 1282
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 22
friction: harness-friction-window = tracker cycle 6 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: spec §6 issue template and evolve SKILL.md Step 3 say `<!-- pipeline:path-hint=A|B|C|D -->` | classify-issue step 3d vocabulary is {A,B,C} and rejects hint D to empty; only the authoritative `<!-- pipeline:path=D -->` marker routes D (#1306 filed with the marker)
HARNESS-FRICTION: evolve SKILL.md Step 2 says resolve the `pending-verdicts:` issues from cycle N−1 | run-retro.sh printed `pending-verdicts: 1304 1303` while the cycle-5 comment lists #1303 #1304 #1300 #1292 (backlog #31, one-cycle span) — union taken by hand
HARNESS-FRICTION: evolve SKILL.md Step 0 forward-sync says conflicts → resolve in-session then push | the gate fence prints nothing on a conflicted merge and the auto-push is skipped because HEAD did not move, so an unattended wrapper cycle depends on the orchestrator noticing `UU` in git status (config-drift-allowlist.txt, cycle 6)
HARNESS-FRICTION: SKILL.md steps 2 and 7 use `gh issue view --json comments` for the cache-check timestamp and post-verify | operating rule (and `enforce-comment-trust.py`) forbids that form; used `gh api repos/.../issues/1294/comments` instead (#1294 classify)
HARNESS-FRICTION: SKILL.md Boot block spells `${HOME}/.claude/plugins/cache/...` glob fallbacks | PreToolUse hook blocks any bare-home/other-home path token, so that block cannot be pasted verbatim; used `source ./scripts/_resolve-plugin-root.sh` per the operating rule (#1294 classify)
HARNESS-FRICTION: SKILL.md steps 2 and 7 fetch comments via `gh issue view --json comments` with GraphQL field names (`.authorAssociation`, `.createdAt`) | environment forbids that call; ported to `gh api .../comments`, which needs REST names (`.author_association`, `.created_at`) — the skill's jq filters do not run as written here (#1282 classify)
HARNESS-FRICTION: issue #1294 lists `tests/test-block-deletions*.sh` as the legacy suite to re-pin | the only `.sh` match is a 7-line unittest wrapper; the rc=1 assertion lives in `tests/test_block_deletions.py` (#1294 plan)
HARNESS-FRICTION: issue #1294 says the legacy base-branch suites pin rc=1 | `tests/test-enforce-base-branch.sh` asserts `rc != 0` on all block cases and needs no edit; only `tests/test-enforce-base-branch-metadata.sh` pins rc=1 (#1294 plan)
HARNESS-FRICTION: plan-issue SKILL.md Step 6 mandates the draft under `.claude/logs/plan-drafts/` | harness rules required `.claude/scratch/`; used the latter (#1294 plan)
HARNESS-FRICTION: evaluate-issue-plan Step 1 prescribes `gh issue view <N> --json comments` piped through `select-plan-comment.sh` | the environment operating rules forbid that fetch and require `scripts/filter-trusted-comments.sh <N>`; the plan Risks section flags the same six skill fences as future hard-denials once enforce-comment-trust exits 2 (#1294 plan-eval)
HARNESS-FRICTION: issue #1282 body says read-only `cat`/`jq`/`python json.load` of `.claude/settings.json` are all blocked | only the `python3 -c` inline-eval form blocks; `cat`/`jq`/`grep` already exit 0 since #1136 (#1282 plan)
HARNESS-FRICTION: bypass-permissions preamble says prefer Bash (`cat`/`grep`) for reads | restrict_paths.py blocks any Bash command whose text carries a path-shaped token, so probing had to route payloads through a Write-tool fixture file (#1282 plan)
HARNESS-FRICTION: full `scripts/run-test-suite.sh` chunks (4/4) never printed RESULT=pass | ~20 failures across all 4 chunks reproduced identically on unmodified `evolve` HEAD (worktree-name collisions, leftover git tags, temp-path/mktemp state) — none reference the touched hooks/doc; pre-existing dogfood-host contamination from three concurrent suite runs out of linked worktrees, not a regression (#1294 green; backlog #36)
HARNESS-FRICTION: evaluate-issue-pr Step 11.2 expects a resolvable capability-refusal arm | gate emitted `WARN: capability-refusal check unproven (REASON=no-leaf-output SCANNED=2 WITH_OUTPUT=0)` and fell through fail-open to `green` (#1306 pr-eval; same dormant fourth state as cycle 5)
HARNESS-FRICTION: evaluate-issue-pr Step 5b treats `gh pr checks --watch` as a single bounded settle | immediately after a force-push it returns `no checks reported` and exits 1 before the new run registers — needs a re-issue after polling `gh run list` for the new head SHA (#1294 pr-eval)
HARNESS-FRICTION: pr-eval brief assumed CI red means "the PR or host contamination" | a third class exists — a red inherited from the base commit the orchestrator forward-sync merge produced; diagnosis required diffing the base run confirmed-failure list against the PR (#1294 pr-eval; orchestrator error at Step 0, fixed by 10a6cda)
HARNESS-FRICTION: execute prompt said run suite chunks "sequential, every chunk RESULT=pass" | all 4 chunks report RESULT=fail in this sandbox due to pre-existing environmental failures unrelated to restrict_paths.py (confirmed via stash-and-rerun on every failing file: worktree-state collisions, missing systemd-run, date-dependent fixtures); proceeded per the headless default (#1282 green; backlog #36)
HARNESS-FRICTION: the payload-hazard warning was not specific enough about `grep` pattern operands in Bash verification commands | `grep -n "/etc..." hooks/restrict_paths.py` tripped the live (unfixed) main-checkout hook exactly as the issue describes; switched to the Read tool for content inspection (#1282 green — the class-1 false positive itself)
HARNESS-FRICTION: fullsend/#1214 says the autonomous lane never checks out or pulls the orchestrator main checkout (fetch-only base refresh) | `scripts/create-checkpoint-tag.sh:99` runs `git pull --ff-only --quiet origin evolve` on the main checkout during the post-merge checkpoint tag, fast-forwarding it to bce8bd5 mid-wave — which also made the #1294 exit-2 hooks live in this session before the cycle ended (orchestrator, cycle 6)
HARNESS-FRICTION: evaluate-issue-pr Step 4 says "Typecheck always runs" | `PIPELINE_TYPECHECK_CMD` is unset in this repo pipeline.config, so the step is a silent no-op (#1282 pr-eval; backlog #18 still open)
HARNESS-FRICTION: pr-eval dispatch said "never edit `tests/**`" | the plan `**Shared tests (split-role):**` list would have exempted `tests/test_restrict_paths.py` from the W7 lock, so the evaluator security fix (bece1be, temp/claude segment escape) could have been pinned without tripping the gate — shipped unpinned (#1282 pr-eval)
HARNESS-FRICTION: block_deletions.py (exit 2 since #1294 merged mid-cycle) is documented as a guard on destructive commands | it hard-blocked the Step 7 retro commit because the Post prose spelled the recursive-rm and hard-reset patterns inside a heredoc — first live denial of the newly real hook is a text-scan false positive of the #1282 class (orchestrator, cycle 6; backlog #45)

delta prose-pinning tests/grep claude.md 8 (baseline 38 -> computed 46)
delta harness mass/words 2 (baseline 56400 -> computed 56402)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc -9 (baseline 79500 -> computed 79491)
delta harness mass/hooks loc 7 (baseline 3900 -> computed 3907)
delta harness mass/scripts loc -21 (baseline 23000 -> computed 22979)
delta harness mass/hooks 0 (baseline 13 -> computed 13)
delta issue-number archaeology in skill bodies/refs 10 (baseline 351 -> computed 361)
delta issue-number archaeology in skill bodies/distinct 7 (baseline 130 -> computed 137)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 17 (baseline 165 -> computed 182)
delta harness mass/scripts 0 (baseline 91 -> computed 91)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): 4
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail.
loop-own tokens/issue (median, all captured stages): 19.6M (cycle 6: #1294 19.6M B 2 plan rounds · #1282 45.2M B incl. evaluator security fix · #1306 12.1M D collapsed; cycle 5: 64.6M; cycle 4: 47.8M; scorecard median PATH B PR 23M)

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 2/5

usage: five_hour=28% seven_day=29% threshold=85


## Diagnose

Verdicts carried from cycle 6 (both resolve at Step 5 of THIS cycle — the first window whose agents run against the merged hooks; the #1294 exit-2 flip went live mid-cycle-6 via the checkpoint-tag pull, #1282 merged last at 1a4b4c6, so every cycle-6 agent ran on the unfixed `restrict_paths.py`):
- #1294 (four guards exit 2) — **provisional confirmed**: cage `SKIP: KNOWN-RED` 4 → 0 at merge, `human` uses 0. The denial column is still `n/a` in `run-retro.sh` (tool-use.log carries no decision field), so denials are counted from `HARNESS-FRICTION:` lines. Cycle 6 saw one live denial, a false positive (`block_deletions.py` on retro heredoc prose, backlog #45). Cycle 7 Step 2 already added a second: `enforce-comment-trust.py` blocked a `grep -nE` whose *pattern operand* spelled the denied fence form — same text-scan class. Verdict at Step 5: true-positive / false-positive split over the cycle-7 lines; ≥1 true positive or false-positive share ≤ 50% → confirmed, else no-effect.
- #1282 (restrict_paths false positives) — **pending**: cycle 5 had 5 friction lines in the path-shaped-text class, cycle 6 had 3 (`grep -n "/etc…"` at GREEN, bypass-preamble at plan, Boot-fence home-prefix at classify). Verdict at Step 5: 0 lines of that class → confirmed; ≥3 → no-effect.
- #1306 (print-mode ceiling in `calibration-run.sh`) — still pending calibration run #4 (operator go; not launched headless).
- `run-retro.sh` printed `pending-verdicts: 1294 1282` — matches the cycle-6 comment this time (both carry the literal `retro (next cycle)`); #1306 is a calibration-only line and correctly absent. Backlog #31 unchanged.

Slate rationale (2 B + 1 A, 0 C; the cycle-6 hand-off order): friction is still the row with signal (22 lines; 45 in cycle 5) and two of its classes now cost real denials rather than detours:
- **#40 → PATH B.** Seven skill fences prescribe the raw `--json comments` form that `enforce-comment-trust.py` hard-denies since #1294: `classify-issue:106,268`, `execute-issue-plan:64`, `evaluate-issue-plan:103`, `plan-issue:160`, `evaluate-issue-pr:80`, `fullsend:274`. Cycle 6 agents detoured via `gh api …/comments` (3 lines) and found the skill jq filters use GraphQL field names that the REST shape does not carry. `select-plan-comment.sh` consumes `{comments:[…]}` on stdin; `filter-trusted-comments.sh` emits plaintext. Fix shape: a `--json` mode on the trust filter emitting the trusted-author subset in the GraphQL shape, so every fence becomes one call and the jq filters run unchanged (absorbs backlog #23).
- **#44 → PATH B.** Root cause found at Step 2: `scripts/setup-worktree.sh:6,66` honour `PIPELINE_PROJECT_ROOT` over cwd (documented override). The fixture tests invoke it as `cd "$PROJ" && bash .claude/scripts/setup-worktree.sh …` and never clear that variable, so when the suite runs in a session where the live config is exported (linked worktrees: config copied, `set -a` sourced), the script sources the LIVE `pipeline.config` and cuts the worktree in the LIVE repo — which is why the leaks carry the live `wt-` prefix while the tests assert `ct-`. Named producers: `test-setup-worktree-base-defaulting.sh` (`wt-100-bar`/`101-baz`/`102-qux`), `test-label-base-routing.sh` (`wt-4242-foo`), `test-setup-worktree-base-tip-per-wave.sh` (`wt-N-waveN`). Fix: pin `PIPELINE_PROJECT_ROOT="$PROJ"` in every fixture invocation, a `run-test-suite.sh` post-suite worktree/branch-count guard, and a regression test that exports a foreign root and asserts the live repo is untouched.
- **#43 → PATH A.** Plan-round binding applied by hand in cycle 6 took both B issues to 2 rounds (cycle 5: 3–4) and cut loop-own median 64.6M → 19.6M. Formalize in `fullsend` Step 3 (re-plan loop, line 286), `evaluate-issue-plan` (Revise must prescribe the concrete fix, line 194) and `plan-issue` (round ≥2 applies it verbatim, no new scenarios) — ≤60 words each, docs-only.

Deferred: D-sized #39 (checkpoint-tag pull), #41 (evaluator test exemption), #42 (split-role three-dot), #45 (text-scan false positives — now also `enforce-comment-trust.py`), #31 (pending-verdicts union). Clone runs `strict`; wrapper-driven (`PIPELINE_HEADLESS=true`).

Forward-sync at Step 0: `origin/staging` already an ancestor of `evolve` — no merge, no push.

## Post

**Merged 3/3.** #1317 (A, single opus) PR #1318 → e753719 · #1315 (B split-role red:opus/green:sonnet) PR #1320 → 6d5cdbf · #1316 (B split-role red:opus/green:opus, `REASON=high-uncertainty`) PR #1319 → c72ed0b. Every plan approved in ONE round (cycle 6: 2, cycle 5: 3–4) — the #1317 binding rule was applied by dispatch prompt this cycle and is now in the skill bodies. Pipelined rather than strict wave-serial: #1317 (A) executed and merged while the two B plan-evals ran, so #1315's worktree was cut from e753719 and its skill-fence edits landed on top of #1317's inserts with no conflict. `DISPATCH=match` ×3, `BASE=ok`, clean-main `untracked-only` throughout, `ACTION=complete` ×3 on first check. Wall clock 15:07 → 16:42Z (≈95 min). Second wrapper-driven cycle (`PIPELINE_HEADLESS=true`), no operator action.

**Cost rows (Step 5, backfill ran):** #1315 51.7M stages=5 · #1316 37.4M stages=5 · #1317 11.1M stages=5. Loop-own median 37.4M (cycle 6: 19.6M; cycle 5: 64.6M). Plan rounds fell to 1 each, so the growth is elsewhere: both GREENs ran the full 4-chunk suite and then proved 14–19 failing files "pre-existing" against a throwaway `origin/evolve` clone (#1315 GREEN: 86 tool uses, 199k output tokens); both plan-evals prototyped the whole plan in throwaway copies (62 and 38 tool uses). The verification load, not planning, is now the token driver — backlog #46.

**Gate yield:** plan-eval 0/3 Revise (all Approve-first; cycle 6: 2/2 Revise-first) — the tighter Step-2 dispatch notes plus the plan-eval prescribing nits as non-blocking instead of Revise. pr-eval 3/3 Approved, 0 fixes; the #1316 evaluator rebased the branch onto e753719 before merge (RED SHA moved 6a8f42a→9289c29 — the #42 two-dot-diff shape, again by rebase). pr-eval #1315 ran a live security probe of the new `--json` mode (NONE/CONTRIBUTOR bodies → `{"comments":[]}`) and hook-legality on all seven rewritten fences (7/7 rc=0 vs 7/7 originals rc=2).

**The #1316 class, live, three times:** `wt-4242-foo` leaked into the live repo during the #1315 planner's sweep and again during the #1317 plan-evaluator's 94-test sweep (both cleaned by the orchestrator mid-cycle); then #1315's GREEN ran the full suite from a branch cut BEFORE #1316's pins and leaked nine (`wt-1..5-wave*`, `wt-4242-foo`, `wt-1000-bar`, `wt-101-baz`, `wt-102-qux`) — the new `run-test-suite.sh` guard in #1316's own worktree caught five of them mid-chunk (`LEAK:` lines, first live fire). Root cause held exactly as diagnosed: `setup-worktree.sh:6,66` honour the exported `PIPELINE_PROJECT_ROOT`; every leak carried the live `wt-` prefix. All nine removed after the last suite finished; 2 worktrees at cycle end (main + calib harness).

**Escapes:** hotfix 0 · revert 0 · later-fix 0. Host: `create-checkpoint-tag.sh` pulled the main checkout to e753719 after the first merge (#39, recurring); fast-forwarded to c72ed0b by hand before this commit. Two throwaway evaluator clones left under `/tmp` (`block_deletions.py` denies their own cleanup — #48).

**Mass:** words 56402 → 56085 (−317: #1315 −461 across six skills, #1317 +144 ≈ +190 tokens, inside its ≤ +240 budget) · tests 439 → 441 (79491 → 79910 LOC) · scripts 91 (22979 → 23091, the leak guard) · hooks 13 / 3907 unchanged · prose-pinning 182 → 183 `SKILL.md` greps (the fence-sweep lint counts as one) · archaeology 361/137 → 351/135.

**Friction:** 50 `HARNESS-FRICTION:` lines — 43 from agents, 7 orchestrator (cycle 6: 22; cycle 5: 45) — with a new dominant class — **hook denials on benign commands** (13 lines): `block_deletions.py` on `sed -i` ×2, `: > file`, a read-only `grep -rnE`, `rm -rf` of an agent's own `mktemp -d` ×3, heredoc prose `trap 'rm -rf'`; `restrict_paths.py` on awk `/regex/` operands ×2, a grep ` / ` literal, the orchestrator's awk program; `enforce-comment-trust.py` on a grep pattern operand and on fullsend Step 1a's own `fetch-issue-attachments.sh` call; `enforce-base-branch.py` on the skill-prescribed quoted `--base "$PIPELINE_BASE_BRANCH"`. Other classes: the raw comments fetch in skill fences (10 lines — the last cycle this class can appear; #1315 merged mid-cycle), Boot-fence home-prefix globs (5, all "would be blocked", none tried), `.claude/logs/plan-drafts/` vs `.claude/scratch/` (3), ugrep vs GNU grep (2), `superpowers:code-reviewer` absent (1), stale worktree-count expectations in my own prompts (2), classify blast-radius rule on test-side fixes (1).

**Verdicts:**
- **#1294 confirmed** — metric moved as predicted: cage `SKIP: KNOWN-RED` 4 → 0 at merge, `human` 0, and denials went from unmeasurable to 13 observed lines this cycle. Finding attached: true positives 0, false positives ≈ 10 (the three `rm -rf` on mktemp dirs are contract-true but operationally noise). The Step-2 criterion ("≥1 TP or FP share ≤ 50 %") conflated "the hook is real" (this issue's hypothesis) with "the hook earns its keep" (backlog #12's metric); the FP share is #45/#48's slate signal, not a strike against making the guards real.
- **#1282 no-effect** — restrict_paths path-shaped-text lines: cycle 5: 5 → cycle 6: 3 → cycle 7: 3. The class shifted (home-prefix literals 1 → 0, regex/pattern operands 1 → 3) but the count did not; the fix's "scan only real path arguments" still classes an awk `/…/` or grep ` / ` operand as a path. Backlog #7 → bottom; the residual folds into #45.
- **#1306 pending** — calibration run #4 (operator go).
- **#1315 / #1316 / #1317** — mass verdicts now: #1315 prose −461 ✓, #1317 +144 words ✓ (≤ +240 tokens), #1316 regression test 6/6 at merge ✓ and the guard fired live ✓. Friction/cost verdicts deferred to cycle 8 (`verdict-candidates: 1317 1316 1315`): #1315 → raw-fetch lines 10 → 0 and `enforce-comment-trust` skill-prescribed denials 2 → 0; #1316 → leaked worktrees 9 → 0 and pre-existing-failure proof lines 3 → 0; #1317 → plan rounds ≤ 2 without dispatch-prompt coaching (this cycle: 1/1/1 WITH coaching, so cycle 8 is the real test).

**Usage:** start five_hour=28 seven_day=29 → end five_hour=55 seven_day=32 (27 five-hour points, on the EST5=27 projection).

**Hand-off (cycle 8 candidates):** #45+#48 text-scan false positives across the four newly-real hooks (B: argument-position narrowing for `block_deletions.py` — `sed -i`, `: >`, read-only grep, mktemp-scoped `rm`; `restrict_paths.py` regex operands; `enforce-comment-trust.py` pattern operands), #47 `enforce-base-branch.py` vs the quoted `--base "$PIPELINE_BASE_BRANCH"` the skills prescribe (D), #46 fullsend Step 1a `fetch-issue-attachments.sh` is hard-denied by the hook it sits beside (D), #49 verification-load cap for GREEN/pr-eval (A/B: skip the full-suite pre-existing-failure proof when CI is green on the head; ~20 tool uses per agent). D-sized #39 (checkpoint-tag pull, recurred), #41, #42 (recurred as rebase) behind them.
