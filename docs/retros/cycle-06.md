cycle-issues: 
pending-verdicts: 1304 1303
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 45
friction: harness-friction-window = tracker cycle 5 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: pipeline.config header says the closing set +a sits "at the end of this file" | live file had set +a at line 78 with 8 hand-appended knobs below it (calib block, USE_LOCAL_PLUGIN, PROJECT_ROOT, TRUST_PROFILE) — none exported; resolvers ran strict under a lean config (→ #1305)
HARNESS-FRICTION: evolve/fullsend Boot fence says "source pipeline.config so PIPELINE_* are available for the rest of this skill" | only knobs inside the set -a block reach child scripts; _resolve-config.sh early-returns once REPO+BASE are set and never re-reads late knobs
HARNESS-FRICTION: Claude Code docs: /reload-plugins reloads skills, agents and hooks without restart | it is a built-in CLI command the model cannot invoke — the loop cannot self-refresh from inside a session (→ #1303)
HARNESS-FRICTION: run-retro pending-verdicts: 1300 | cycle-4 comment lists pending #1300 #1292 #1291 #1285 #1286 (backlog #31, one-cycle span)
HARNESS-FRICTION: classify-issue steps 2 and 7 prescribe `gh issue view --json comments` for the cache-check timestamp and post-verification | the comment-trust hook warns on `--json comments`; the agent used `gh api repos/<repo>/issues/1303` (`.comments`) and `.../issues/1303/comments` instead (#1303 classify)
HARNESS-FRICTION: orchestrator brief said "an explicit path-hint marker in the body takes precedence over the heuristic" | classify skill step 3d treats `path-hint=` as an overridable advisory prior with vocabulary {A,B,C} only — `path-hint=D` is rejected to empty; only `<!-- pipeline:path=D -->` is authoritative (#1305 classify; heuristic reached D anyway)
HARNESS-FRICTION: classify-issue step 2 cache-check reads `gh issue view --json comments` for the freshness timestamp | the comment-trust hook flags `--json comments`; the skill's own prose contradicts the "only via filter-trusted-comments.sh" rule (#1305 classify)
HARNESS-FRICTION: classify-issue steps 2/7 say fetch comments via `gh issue view --json comments` | used `filter-trusted-comments.sh` + `gh api .../issues/N/comments` instead — worked, but the skill prose contradicts the hook (#1304 classify)
HARNESS-FRICTION: classify-issue Paths table says PATH B = "spawned worker session" | CLAUDE.md says A/B/D run as inline `Agent`; `--spawn` is the legacy transport (stale prose, not hit at runtime) (#1304 classify)
HARNESS-FRICTION: plan-issue Boot fence says `source pipeline.config` makes PIPELINE_* available to later Bash calls | Bash shell state does not persist across calls, so every call needing $PIPELINE_REPO re-sourced or passed it inline (#1305 plan)
HARNESS-FRICTION: issue #1303 scope says usage-gate.sh is "stubbed by PATH shim" | the wrapper resolves it as <clone>/scripts/usage-gate.sh, an absolute path no PATH shim can intercept — plan adds an EVOLVE_LOOP_USAGE_GATE env seam instead (#1303 plan)
HARNESS-FRICTION: issue #1303 scope prescribes `HEADLESS-DEFAULT: usage-pause decision=exit-for-wrapper resume_at=<ts>` | fullsend `## Headless contract` grammar requires `reason=<why>` — plan inserts `reason=wrapper-owns-the-sleep` (#1303 plan)
HARNESS-FRICTION: issue #1303 sets a ≤80-word budget for skills/evolve/SKILL.md | tests/test-evolve-skill-budget.sh leaves ~85 words of headroom (2137 words ≈ 2884/3000 tokens) — plan drafts ~45 words (#1303 plan)
HARNESS-FRICTION: issue #1304 Scope says block_deletions denies `git push --force` | verified live — no such pattern in the hook's BLOCKED list; it exits 0. `git reset --hard` is the real pattern (#1304 plan)
HARNESS-FRICTION: issue #1304 Scope says all seven hooks are driven with "PreToolUse JSON on stdin" | enforce-ci-wait.py is registered on Stop (matcher *), and enforce-path-c-delegation.py on PreToolUse Edit/Write (reads tool_input.file_path), not Bash (#1304 plan)
HARNESS-FRICTION: spec §6 names restrict_paths.py as cage-protected alongside the #1294 four | restrict_paths.py, enforce-ci-wait.py and enforce-path-c-delegation.py already exit 2; only block_deletions, enforce-base-branch, check-ci-skip-markers, enforce-comment-trust exit 1 (#1304 plan)
HARNESS-FRICTION: .claude-plugin/plugin.json is the stated hook registry | enforce-comment-trust.py is registered only in the dogfood consumer settings file, not in the plugin manifest (#1304 plan)
HARNESS-FRICTION: restrict_paths.py guards writes to protected control files | it blocked a read-only Bash call whose command string merely contained a protected path as text (the #1282 false-positive family) — cost one tool call (#1304 plan)
HARNESS-FRICTION: evaluate-issue-plan Step 1 prescribes `gh issue view --json comments` + select-plan-comment.sh | comment-trust hook warns on `--json comments`; filter-trusted-comments.sh returns flat text, not the {comments:[...]} JSON select-plan-comment.sh expects (#1303 plan-eval; session-cached skill body — #1300 merged 2026-09-07 addressed this prose)
HARNESS-FRICTION: issue #1304 Scope names `git push --force` as a block_deletions deny case | not in hooks/block_deletions.py:19-37; observed rc=0 (allowed); plan substituted `git reset --hard` (#1304 plan-eval)
HARNESS-FRICTION: restrict_paths.py blocked a plain `python3 -c` read of .claude/settings.json as "Bash command targets a protected control file" | the command only read the file; worked once the path was passed via argv (the #1282 false-positive class) (#1304 plan-eval)
HARNESS-FRICTION: orchestrator brief said to key the ADDED-exemption on GitHub files[].status / changes with additions<changes | `gh pr view --json files` exposes only additions, deletions, path, changeType (PatchStatus ADDED/CHANGED/COPIED/DELETED/MODIFIED/RENAMED); plan uses changeType (#1304 re-plan)
HARNESS-FRICTION: orchestrator note said "pass the path via argv" avoids restrict_paths.py on .claude/settings.json | restrict_paths scans the whole Bash command string, so the literal in argv still blocked; only runtime string assembly worked (#1304 plan-eval r2)
HARNESS-FRICTION: evaluate-issue-plan Step 1 plan-selection returns the plan on stdout for inline use | a 32KB plan truncates in Bash and the Read tool refuses the scratchpad path (outside project boundary) — paged with awk line ranges (#1304 plan-eval r2)
HARNESS-FRICTION: evaluate-issue-plan Step 1 prescribes a literal COMMENTS_JSON=$(gh issue view <N> --json comments) before the trust filter | the enforce-comment-trust hook warns on `--json comments`, so the prescribed block trips the guard it claims to satisfy (#1303 plan-eval r3)
HARNESS-FRICTION: orchestrator brief said the fail-closed shim update touches "both the new test and capability-refusal.sh" (2 files) | against a patched gate, fail-closed turns 8 gate tests red because every shim `*)` arm exits 1 on the unhandled `pulls/<pr>/files` call; 9 files now in the scripts/ leaf (#1304 re-plan r3)
HARNESS-FRICTION: calibration-run.sh/spec §8 treat a headless `claude -p "/pipeline:fullsend …"` run as one complete pass | Claude Code print mode terminates after 600 s of waiting on background tasks ("Background tasks still running after 600s; terminating. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0") — run #3's orchestrator ended mid-wave-2 ("Still waiting on #18's evaluator — will act on notification"): #18 left pr-open, #16 never executed, graded 2/5
HARNESS-FRICTION: #1305 plan's literal awk snippet (`END{exit !found}` as the function return) | inverted the clean/dirty polarity needed by check_tail_clean's caller contract — rewritten to capture output (#1305 execute)
HARNESS-FRICTION: #1305 plan's literal c1 fixture (`PIPELINE_BOGUS_KNOB`) | the literal in a tracked tests/*.sh file is swept by check-config-drift.sh as undocumented drift, breaking 5 unrelated tests until reworked (#1305 execute)
HARNESS-FRICTION: evaluate-issue-pr Step 8 says to `git rebase origin/$PIPELINE_BASE_BRANCH` whenever the base has advanced | base had advanced one commit but mergeStateStatus was already CLEAN; rebasing a pushed branch would need the forbidden force-push — directive should be gated on a non-CLEAN merge state (#1305 pr-eval)
HARNESS-FRICTION: evaluate-issue-pr Step 11.2 documents three capability-refusal resolver states and treats `resolved` as arming the check | resolver returned `resolved`, then the gate printed `WARN: capability-refusal check unproven (REASON=no-leaf-output SCANNED=4 WITH_OUTPUT=0)` — a fourth, silently-dormant outcome the prose does not describe (#1305 pr-eval)
HARNESS-FRICTION: execute-issue-plan Step 4 orders the `plan-approved → in-progress` flip before implementation | applied just before PR creation and nothing detected the out-of-order state, so the label misreported the issue for the whole execute window (#1303 execute)
HARNESS-FRICTION: execute-issue-plan Step 8 says the review loop runs BEFORE `gh pr create`, Step 12 says stop the moment `pr-open` is applied | with an async reviewer these conflict; the executor opened the PR first and folded the review must-fixes in afterwards — the review caught an unbounded-relaunch bug, so "open first" was the risky order (#1303 execute)
HARNESS-FRICTION: evaluate-issue-pr Step 4 dedup guard says the full $PIPELINE_TEST_CMD runs "at most once per eval" | the PR head advanced mid-eval (f6db9fd → 869fc72), so a sound verdict needed a second full sweep; the guard has no re-baseline clause (#1303 pr-eval)
HARNESS-FRICTION: evaluate-issue-pr Step 5b treats one bounded `gh pr checks --watch` as settling CI | a commit landing mid-eval invalidates the settled rollup; Step 5 has no "head changed, re-watch" path (#1303 pr-eval)
HARNESS-FRICTION: fullsend dispatch contract says never attribute state to a hypothesised concurrent writer | the executor really was folding review fixes into the worktree during the eval; the skill offers the evaluator no protocol for an in-flight head (#1303 pr-eval)
HARNESS-FRICTION: orchestrator leaf brief said commit subject `docs(spec): …` | the plan slice mandated the verbatim subject `docs(evolve): spec §6 — cage invariants replace the hook human-lane`; the leaf used the plan (#1304 docs leaf)
HARNESS-FRICTION: #1304 plan measured evolve SKILL.md HEAD at 2137 words/2884 tokens with 89 headroom after the edit | HEAD 16df628 (after #1303's bullet) measured 2182/2945, so post-edit is 2972 with 28 tokens headroom — the ceiling holds but the margin is a third of the claim (#1304 skills leaf)
HARNESS-FRICTION: orchestrator leaf brief said "four skill files" under target=skills/ | only three exist; the fourth Files-to-change entry is the spec, owned by the docs leaf (#1304 skills leaf)
HARNESS-FRICTION: #1304 plan estimated ≈63 words for the fullsend/evaluate-issue-pr sites | actual 78 — the mandated wave-halt rationale clause was prescribed in prose but not counted; no guard covers those sites (#1304 skills leaf)
HARNESS-FRICTION: hooks/restrict_paths.py docstring says heredoc bodies are masked as stdin DATA when the command word is not an interpreter | masking is scoped to the cd gate and protected-write scan only, so `git commit -F -` with a body merely naming `/etc` was hard-blocked; landed only after rewording (#1304 tests leaf)
HARNESS-FRICTION: #1304 round-3 plan claimed skills/evolve/SKILL.md would keep 89 tokens of headroom after the edit | measured 28 (2972/3000) — the base drifted 2137→2182 words between plan time and the feature base (#1304 code review)
HARNESS-FRICTION: system prompt mandates the session scratchpad dir under /tmp for all temp files | hooks/restrict_paths.py BLOCKED every Write there as "path outside project boundary"; evaluator fixtures relocated to <worktree>/.claude/scratch/ (#1304 pr-eval)
HARNESS-FRICTION: evaluate-issue-pr Step 1 prescribes `gh issue view --json comments` piped through select-plan-comment.sh | the comment-trust hook flags that fetch and filter-trusted-comments.sh emits flat text with no comment boundaries, so select-plan-comment.sh cannot be fed — plan selected by hand off the last `## Implementation Plan` heading (#1304 pr-eval)
HARNESS-FRICTION: run-test-suite.sh is hermetic (tests write only under mktemp) | a suite run from a linked worktree left nine real worktrees + branches in the repo (wt-1-wave1…wt-5-wave5, wt-100-bar, wt-101-baz, wt-102-qux, wt-4242-foo): test-label-base-routing / test-setup-worktree-base-defaulting / test-setup-worktree-base-tip-per-wave drive setup-worktree.sh against the live checkout (backlog #36)

delta prose-pinning tests/grep claude.md 8 (baseline 38 -> computed 46)
delta harness mass/words 1401 (baseline 55000 -> computed 56401)
delta harness mass/skills 1 (baseline 18 -> computed 19)
delta harness mass/tests loc 10488 (baseline 69000 -> computed 79488)
delta harness mass/hooks loc -1446 (baseline 5000 -> computed 3554)
delta harness mass/scripts loc 2978 (baseline 20000 -> computed 22978)
delta harness mass/hooks -1 (baseline 14 -> computed 13)
delta issue-number archaeology in skill bodies/refs 10 (baseline 351 -> computed 361)
delta issue-number archaeology in skill bodies/distinct 7 (baseline 130 -> computed 137)
delta harness mass/tests 34 (baseline 405 -> computed 439)
delta prose-pinning tests/grep skill.md 17 (baseline 165 -> computed 182)
delta harness mass/scripts 7 (baseline 84 -> computed 91)
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
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail.
loop-own tokens/issue (median, all captured stages): 64.6M (cycle 5: #1303 76.4M incl. 4 plan rounds · #1304 64.6M PATH C 5 leaves + review · #1305 15.5M D; cycle 4: 47.8M; scorecard median PATH B PR 23M)

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 2/5

usage: five_hour=1% seven_day=0% threshold=85


## Diagnose

Verdicts carried from cycle 5:
- #1303 (session-per-cycle wrapper) — **confirmed**. Cycle 6 is the first wrapper-driven cycle: the `evolve-loop.sh` launcher armed 2026-09-08 fired at 06:05Z, ran usage-gate + projection (`proceed`), launched a fresh `claude -p` (ancestry verified: evolve-loop.sh → timeout → claude -p) with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`, and that process loaded the post-#1303/#1304 evolve skill body (HEADLESS-DEFAULT branch, `block-cage-tests-diff` guardrail) with no operator `/reload-plugins`. Backlog #24 closed.
- #1304 (cage invariants replace the human lane) — **confirmed** (provisional): `friction: human = 0` over the cycle-5 window; #1294/#1282 relabelled `evolve` and are this cycle's slate; the seven cage tests pin the deny contract and SKIP `KNOWN-RED #1294` for the four exit-1 hooks. Re-checked at Step 5: a hook PR that needs `human` or trips `block-cage-tests-diff` flips this to regressed.
- #1300 (prose-drift bundle), #1292 (Boot fence anchor) — still pending, resolved at Step 5 of THIS cycle, the first window whose agents load the merged bodies. Measure: HARNESS-FRICTION lines naming `--json comments` / sweep-vacuity / one-test-file prose (#1300; cycle 5: 7 lines) and Boot-fence resolver failure (#1292; cycle 5: 0 lines, cycle 1: 8).
- `run-retro.sh` printed `pending-verdicts: 1304 1303` while the cycle-5 comment lists four (backlog #31, still open) — union done by hand above.

Slate rationale: friction is the row with signal (45 lines in cycle 5; the restrict_paths path-shaped-text class recurred 5×, the `--json comments` class 7×) and the #1304 lane has never carried a hook edit — so two hook PATH B issues exercise it: #1294 (four guards exit 2; cage tests flip SKIP→green, denials become real) and #1282 (restrict_paths false positives). #1306 shrinks to the calibration launcher (the evolve-loop half shipped inside #1303 — launch line + `test-evolve-loop.sh` assertion) and goes PATH D via the authoritative `pipeline:path=D` marker (classify rejects `path-hint=D`); it unblocks every calibration-sourced verdict (run #4 needs an operator go — not launched from this headless cycle). Caps: 2 B + 1 D, 0 C. Backlog #31 (pending-verdicts union) and #38 (plan-round cap) deferred to cycle 7. Clone runs `strict`; `ALLOW_ORCHESTRATOR_EDIT` is unset in the wrapper session (delegation hook live).

Forward-sync: `origin/staging` (release 0.23.25 + #1310's allow-list entry) merged with one conflict in `tests/config-drift-allowlist.txt` (staging's `PIPELINE_TRUST_PROFILE` spec-only exemption vs evolve's #1291/#1272/#1281/#1293 entries) — resolved keep-both, `check-config-drift.sh` ok, pushed as ef1529c.

## Post

**Merged 3/3.** #1306 (D collapsed, sonnet) PR #1313 → 4137d18 · #1294 (B split-role red:opus/green:sonnet, 2 plan rounds) PR #1312 → bce8bd5 · #1282 (B split-role, 2 plan rounds) PR #1314 → 1a4b4c6. One wave (no shared files); `BASE=ok`; clean-main `untracked-only` throughout; `DISPATCH=match` ×3.

**First wrapper-driven cycle.** Launched by `scripts/evolve-loop.sh` at 06:05Z as a fresh `claude -p` with the print-mode ceiling disabled; every background-agent notification arrived in-process; no operator action. Wall clock 06:05 → 07:35Z (≈90 min).

**Cost rows (Step 5, backfill ran):** #1294 19.6M stages=5 · #1282 45.2M stages=5 (incl. the evaluator's fix round) · #1306 12.1M stages=2. Loop-own median 19.6M (cycle 5: 64.6M, −70%; cycle 4: 47.8M) — driven by the plan-round binding discipline applied by hand (round-2 planner applies the evaluator's prescribed fix verbatim, round-2 evaluator checks only that; 2 rounds each vs 3–4 in cycle 5; backlog #43) and the sonnet GREEN.

**Gate yield:** pr-eval #1282 found a boundary hole the CI-green tree had open (the new POSIX call site fed a real path into `_is_session_scratchpad`, whose Windows arm is a bare substring test, so any path containing a scratchpad-shaped segment became in-boundary) and fixed it pre-merge (bece1be, 18-case probe) — the first real pr-eval catch since the pilot era; shipped unpinned because the dispatch barred `tests/**` (backlog #41). Plan-eval: 2/2 first-round Revise, each on one concrete defect (a superseded twin assertion the planner missed), both fixes prototype-verified.

**Orchestrator error:** the Step 0 forward-sync conflict in `tests/config-drift-allowlist.txt` was resolved keep-both, which broke `test-pipeline-config-trust-profile-knob.sh` on the base; CI went red on all three PRs until 10a6cda peeled the entry. PATH B branches were rebased (not merged — the split-role gate's two-dot diff would sweep base-side test edits, backlog #42), #1313 was merged forward. Cost: one extra CI round per PR and two evaluator detours.

**Escapes:** hotfix 0 · revert 0 · later-fix 0. Host: nine leaked test worktrees/branches again (#36 → #44), cleaned in-cycle before the last pr-eval; concurrent suites from linked worktrees produced ~20 "pre-existing" failures per GREEN. `create-checkpoint-tag.sh` fast-forwarded the main checkout mid-wave (#39), so the exit-2 hooks went live in this session before the cycle ended — and `block_deletions` then hard-blocked this retro's own commit once, on the recursive-rm / hard-reset spellings inside the Post heredoc (text-scan false positive, backlog #45): the first live denial of the newly real guard.

**Mass:** words 56401 → 56402 · hooks 13 / 3554 → 3907 LOC (+353: restrict_paths three-class fix + docstring section) · tests 439 (79488 → 79491 LOC) · scripts 91 (22978 → 22979) · prose-pinning 182/46 unchanged · archaeology 361/137 unchanged · fullsend `## Headless contract` +26 words, four lines trimmed to stay under its 200-word ceiling.

**Friction:** 22 `HARNESS-FRICTION:` lines (cycle 5: 45). Classes: `--json comments` prescriptions (3 — now hard-denied → #40, cycle-7 slate), suite contamination from linked worktrees (3 → #44), Boot-fence home-prefix literal (1), forward-sync CI-red-from-base (2, orchestrator), checkpoint-tag pull (1 → #39), split-role rebase (1 → #42), capability-refusal dormant state (1, recurring), typecheck no-op (1, #18), issue-body inaccuracies found by planners (3), spec §6 `path-hint=D` vs classify vocabulary (1), pending-verdicts one-cycle span (1, #31), Step 0 conflict silence (1), block_deletions heredoc false positive (1 → #45).

**Verdicts:** #1303 confirmed (the wrapper drove the cycle end-to-end on fresh skill bodies, no `/reload-plugins`) · #1304 confirmed (human=0; two hook PRs through the evolve lane; cage SKIP 4 → 0; `block-cage-tests-diff` never fired) · #1300 confirmed (0 friction lines on its four claims in the first fresh-session window) · #1292 confirmed (Boot-fence lines 8 → 1; the residual is the restrict_paths class #1282 fixes) · pending: #1294 (denials column, retro next cycle — first denial already observed), #1282 (friction-class count, retro next cycle), #1306 (calibration run #4 — operator go required; not launched headless).

**Usage:** start five_hour=1 seven_day=0 → end five_hour=28 seven_day=5 (27 five-hour points, under the EST5=29 projection).

**Hand-off:** cycle-7 slate candidates #40 (`--json comments` sweep, B), #43 (plan-round binding rule, A/B), #44 (suite worktree leak, B); D-sized #39/#41/#42/#45 behind them. The exit-2 hooks are live in the clone: `gh issue view --json comments`, recursive `rm` and hard `git reset` spellings now hard-block — even inside heredoc prose. Calibration run #4 wanted for the #1306/#1291 verdicts.
