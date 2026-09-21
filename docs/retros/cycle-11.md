cycle-issues: 
pending-verdicts: 1335 1334
verdict-candidates: 

friction: denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
friction: harness-friction-lines = 19
friction: harness-friction-window = tracker cycle 10 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: fullsend Step 1a prescribes a direct `fetch-issue-attachments.sh` call per slate issue | `enforce-comment-trust.py` hard-denies it (orchestrator, #46 fifth cycle)
HARNESS-FRICTION: the pr-eval #1334 dispatch prompt said the #1335 `.claude/scratch/<sub>` carve-out was live after merge | the live hook is the main checkout's copy, still at 1e4cd4e — #39 did not recur this cycle, so nothing had pulled it (orchestrator)
HARNESS-FRICTION: plan-issue SKILL Step 3b prescribes `bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh <N>"` | `enforce-comment-trust.py` hard-denies any direct `fetch-issue-attachments.sh` call (#1334 plan)
HARNESS-FRICTION: issue #1334 says `grep -rlF -e '--chunk 1/4' tests/` finds the prose pins to update | it finds only `tests/test-run-test-suite-chunked.sh` (a header comment, no assertion); the real 6b pin is `tests/test-dispatch-no-background-test-run.sh` (#1334 plan)
HARNESS-FRICTION: issue #1334 specifies `<dir>/` prefix needles as the selection rule | on the real corpus that rule selects 87% of tests on this PR's own diff, defeating the stated cost hypothesis (#1334 plan)
HARNESS-FRICTION: restrict_paths.py resolves `cd ..` against the initial cwd, not the shell's current dir after an earlier `cd tests` in the same command | blocked as "outside project boundary" (#1334 plan)
HARNESS-FRICTION: skill Boot fence + caller say `mktemp -d` fixtures under `.claude/scratch` | `mktemp -d -p .claude/scratch` returns a RELATIVE path, so `git remote add origin "$WORK/origin.git"` + `git -C "$R" fetch` fails (URL resolves relative to the repo dir) — must prefix `$PWD` (#1334 plan-eval)
HARNESS-FRICTION: plan ledger says scenario 10 red because 6b lacks `base CI is green` | that phrase already exists in Step 6b L128 (#1322 text); only `--changed-only` / `CHANGED-ONLY:` are missing (#1334 plan-eval)
HARNESS-FRICTION: none observed — Boot fence resolved `CLAUDE_PLUGIN_ROOT` to the worktree, no hook denials (heredoc `rm -rf` trap line was masked as documented for #1321), all paths existed (#1334 RED)
HARNESS-FRICTION: attempted `rm -rf .claude/scratch/<literal-name>` cleanup of my own test-output scratch dir, expecting the new carve-out to allow it | the running PreToolUse hook resolves to the main checkout's `hooks/block_deletions.py`, not this worktree's edited copy, so the fix isn't live for my own session until merged — denied as expected under the pre-fix hook, not a defect (#1335 execute)
HARNESS-FRICTION: issue #1333 scope item 4 said "A `--dry-run --reset` control asserts the remote still carries `feature/stale`" | as shipped, `--dry-run` and `--reset` were separate mutually-exclusive MODEs (verified empirically: `--dry-run --reset` exited 2, "mutually exclusive") — the combo test the issue asked for was not actually invocable, so this fix also had to add a small mode-parsing relaxation (`--reset`+`--dry-run`, either order, compose into `MODE=reset,DRY=1`) to make that test possible without a false-pass (#1333 execute)
HARNESS-FRICTION: skill Step 11.2 — capability-refusal arm resolves `SOURCES=resolved` and is expected to check leaf output | gate printed `WARN: capability-refusal check unproven (no-leaf-output SCANNED=2 WITH_OUTPUT=0)` — the resolved log dir had subagent entries but none with output, so the arm was effectively dormant despite `resolved` (#1335 pr-eval)
HARNESS-FRICTION: skill Step 8 says "If PIPELINE_BASE_BRANCH has advanced, git rebase" | PR was already MERGEABLE/CLEAN under the merge-commit strategy; the rebase forced a second ~4-min CI watch for no functional change (#1333 pr-eval)
HARNESS-FRICTION: auto-merge-gate emits `WARN: capability-refusal check unproven (REASON=no-leaf-output SCANNED=2 WITH_OUTPUT=0)` even with `SOURCES=resolved` | inline-Agent evals leave no leaf output in `.claude/logs/subagents`, so the arm is always "unproven" on this dispatch shape (#1333 pr-eval)
HARNESS-FRICTION: `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh"` (the exact form the new Step 6b prose instructs) resolved `CLAUDE_PLUGIN_ROOT` to the main checkout, not this worktree, because `CLAUDE_PLUGIN_ROOT` was already set in the inherited shell env before I ever sourced this worktree's `pipeline.config` — it silently ran the *old* unpatched script from the main tree and misparsed `--changed-only` as a positional tests-dir. Had to invoke `bash scripts/run-test-suite.sh --changed-only` (worktree-relative) instead to get the patched script under test (#1334 GREEN)
HARNESS-FRICTION: touching `pipeline.config.example` (a single-comment-line addition) pulled ~90/443 tests into the `--changed-only` selection, purely because that file is referenced by dozens of unrelated `pipeline.config.example documents X` doc-presence tests. Two of those (`test-resolve-plugin-root.sh`, `test-spawn-claude-systemd-scope.sh`) intermittently failed only inside that large batch (100% green standalone, and re-running the identical selection was non-deterministic) — sandbox/systemd batch flakiness, not a regression, but it cost significant verification time to rule out (#1334 GREEN)
HARNESS-FRICTION: task prompt said the deletion hook (#1335 merged) allows `rm -rf .claude/scratch/<literal-sub>` | the hook runs from the MAIN checkout, which is still at `1e4cd4e` (pre-#1336), so both compound and bare literal forms were BLOCKED; cleaned via `python3 shutil.rmtree` (#1334 pr-eval)
HARNESS-FRICTION: Step 6b prose (as merged before my fix) prescribed `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/run-test-suite.sh" --changed-only` | under dogfood that runs the main checkout's script (today: pre-PR version, `tests dir not found: …/--changed-only` rc 1; post-merge: diffs the main tree → `selected=0 RESULT=pass` false green) (#1334 pr-eval)
HARNESS-FRICTION: PR body diagnosed `test-resolve-plugin-root.sh` / `test-spawn-claude-systemd-scope.sh` as "sandbox/systemd batch flakiness" | they fail deterministically whenever `pipeline.config` (`set -a`) is sourced into the running shell; pass 100% with the knobs unset (#1334 pr-eval)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words -7 (baseline 56400 -> computed 56393)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc -21 (baseline 80600 -> computed 80579)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 14 -> computed 14)
delta issue-number archaeology in skill bodies/refs 0 (baseline 352 -> computed 352)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 0 (baseline 187 -> computed 187)
delta harness mass/scripts 0 (baseline 91 -> computed 91)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it); cycle 8: 2 (#1323 CI-red placeholder-grep test the executor mis-classed as pre-existing; #1321 three fail-closed regressions — `\rm` alias bypass, `xargs`-wrapped rm, brace/glob tmp targets — CI green, cage tests blind to them); cycle 9: 1 (#1327 `command_mask` import not co-located in the phase2-coexistence sandbox copy — CI red, executor mis-classed the test as pre-existing, the #53 class again); cycle 10: 2 (#1334 CI-red head from a scanner guard its own `--changed-only` run skipped — the guard's regex began with `-c` and grep had parsed it as an option, dead code on every prior run; and the `${CLAUDE_PLUGIN_ROOT:-.}` form in the rewritten Step 6b diffing the MAIN tree under dogfood — a proven false green `selected=0/442`, fixed with a `$PWD` anchor)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): 4
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline.
loop-own tokens/issue (median, all captured stages): 23.4M (cycle 10: #1335 16.4M D collapsed, 78 tool uses · #1333 23.4M D collapsed, 99 tool uses · #1334 50.9M B 1 round, GREEN 80, pr-eval 64; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M)

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=20% seven_day=55% threshold=85


## Diagnose

Verdicts at Step 2 — `run-retro.sh` printed `pending-verdicts: 1335 1334`; #1333 is measured by calibration run #5, not the retro.

- **#1333** (`calibration-run.sh --reset` sweeps sandbox PRs + remote branches) — **confirmed**: run #5 (strict + sonnet, 2026-09-14 19:35 → 20:37 UTC, `docs/retros/calib/2026-09-14.txt`) executed 5/5 issues with no `superseded` deferral, reftest 5/5, `unexpected-files=0`, total wall 3622 s — the first clean strict baseline (run #4: 2/5 behind a stale PR). Scorecard `weak-model pass` row → `strict + sonnet run #5: 5/5 reftest, 3622 s`. Residual gap seen at launch: the local-branch prune errors `cannot delete branch … used by worktree` for 10 stale sandbox worktrees (runs #1–#4) — non-fatal, backlog #69.
- **#1334** (`run-test-suite.sh --changed-only` + Step 6b) and **#1335** (`block_deletions` literal `.claude/scratch/<sub>` carve-out) both merged in cycle 10 but were live for NO cycle-10 agent: the cycle-10 comment says so per line (the #1335 execute and #1334 pr-eval `rm -rf` denials ran under the main checkout's pre-5c50477 hook — "#39 did not recur, so nothing had pulled it"; the #1334 GREEN ran the pre-merge runner from the main tree). Cycle 11 is the first cycle in which every agent runs under both from Step 0 (fresh `claude -p` at 2c5cca3). Criteria, resolved in `## Post` with cycle-11 data (the cycle-9/10 pattern):
  - **#1334** — criterion: PATH B GREEN tool uses 80 (cycle 10) / 66 (cycle 9) → ≤ 40, D executor 99/78 → ≤ 40, execute-stage tokens on the B row −30 % vs 50.9M; quality arm: CI-red heads caused by a test `--changed-only` skipped → 0 (cycle 10: 1, the scanner class #65 fixes this cycle). Tool-use/tokens come from the Step 5 `cost:` rows (cost verdict per spec §7 — if the rows are ambiguous the verdict defers to cycle 12).
  - **#1335** — criterion: `block_deletions.py` false-positive lines 2 (cycle 10, both "fix not live") / 5 (cycle 9) → 0; fixtures left behind under `/tmp` and `.claude/scratch/` by planners/evaluators 6 → 0 (checked after the run); cage 7/7 on every head. Dispatch prompts this cycle carry NO fixture-cleanup coaching so the prose is measured as read.

Backlog re-rank (friction 19 lines in cycle 10, 48 in cycle 9; every mass budget met; classes among the 19: inherited-`CLAUDE_PLUGIN_ROOT`-runs-the-main-tree 3, hook-fix-not-live 3, `fetch-issue-attachments.sh` hard-denied 2 (#46, fifth cycle), capability-refusal `WARN … unproven` 2 (#67), issue-text-wrong 3, Step 8 rebase on a MERGEABLE PR 1, relative `mktemp -p` breaking a remote URL 1, `restrict_paths` `cd` chain 1, `pipeline.config.example` over-selection + batch flake 1, `none` 1):

1. **#65 → D** — `--changed-only` misses scanner/sweep tests (`tests/test-guard-*`, anything that globs `tests/*.sh`): the one CI-red head of cycle 10 was exactly this, and it is the quality arm of #1334, which is on verdict this cycle. Bounded script change + one test.
2. **#46 → D** — attachment ingestion dead in the autonomous lane for five cycles (2 TP lines per cycle): fullsend Step 1a and plan-issue Step 3b prescribe a direct `fetch-issue-attachments.sh` call that `enforce-comment-trust.py` hard-denies. The script already applies the trust filter (`is-trusted-author`), so the fix is a sanctioned entry — `filter-trusted-comments.sh fetch-attachments <N>` (the hook's allow-by-presence key, Case H) — and the two fences rewritten to it. Hook + cage unchanged.
3. **#66 → A** — prose-vs-runtime sweep fed by the cycle-10 class-(3) lines: evaluate-issue-pr Step 8 "rebase if the base advanced" → rebase only when the PR is not MERGEABLE/CLEAN (merge-commit strategy tolerates an advanced base; the rebase cost a needless 4-min CI re-watch); `mktemp -d -p .claude/scratch` in both eval skills → `$PWD`-anchored (relative paths break `git remote add` URLs) while cleanup stays a literal `.claude/scratch/<name>` (the #1335 carve-out shape); execute Step 6b / fullsend Step 6 dispatch: name the fact that the session-inherited `CLAUDE_PLUGIN_ROOT` is the MAIN checkout under dogfood, so the Boot fence must run in the same Bash call as any `${CLAUDE_PLUGIN_ROOT}/scripts/…` call (3 lines). ≤ 0 net words.
4. #67 (D, capability-refusal WARN on every inline eval → `skip reason=inline-dispatch`), #68 (D, `setup-worktree.sh` crashes under `set -u` when `PIPELINE_SYNC_*` are unset — calib run #5 worked around it inline on every dispatch), #69 (D, `--reset` leaves stale sandbox worktrees), #61 env half (D — the Boot fence already re-points under `PIPELINE_USE_LOCAL_PLUGIN=true`; the prompt sentence is in #66), #63, #62, #39.

Slate for cycle 11 — 2 D + 1 A, 0 C. File sets: `scripts/run-test-suite.sh` + test · `scripts/filter-trusted-comments.sh` + fullsend Step 1a + plan-issue Step 3b + comment-trust tests · evaluate-issue-pr / evaluate-issue-plan / execute-issue-plan / fullsend Step 6 prose — #46 and #66 share fullsend/plan-issue, so plan-waves may put #66 in wave 2.

Why this slate: #65 closes the only quality escape of the #1334 mechanism before its verdict; #46 is the longest-recurring TP friction line and D-sized; #66 is the cheapest way to zero five cycle-10 friction lines and is the standing-sweep shape the backlog asked for. #1334 / #1335 are measured, not touched.

Dispatch discipline this cycle: no fixture-cleanup or hook-workaround coaching (#1335 measures the hook as met); no "skip the proof" coaching (#1334 measures Step 6b as read); dispatch prompts say "resolve `CLAUDE_PLUGIN_ROOT` from the worktree via the Boot fence in the same call", never a value; `git merge --ff-only origin/evolve` in the main checkout after the wave (before Step 5) so the retro reads the merged tree; prune merged worktrees before Step 5.

## Post

Cycle 11 — wrapper-driven (`claude -p` PID 3928570, launched by the calib-#5 → cycle-11 chain), 2026-09-14 20:37 → 22:05 UTC (≈ 88 min loop / ≈ 69 min fullsend, 20:48 → 21:57). 3/3 merged, all auto-merged by the evaluator: #1339 D → PR #1343 `59668fb` (evaluator fix `177503c`) · #1340 D → PR #1344 `5c3e67b` · #1341 A → PR #1345 `5282b6c`. Three serial waves (plan-waves serialized #1339 → #1340 on a glob-expanded `tests/*.sh` literal — #54 recurred; #1340 → #1341 on fullsend, real).

### Step 5 output (`run-retro.sh --post`)

COMPUTED prose-pinning tests/grep claude.md = 46
COMPUTED harness mass/words = 56347
COMPUTED harness mass/skills = 19
COMPUTED harness mass/tests loc = 80720
COMPUTED harness mass/hooks loc = 4466
COMPUTED harness mass/scripts loc = 23272
COMPUTED harness mass/hooks = 14
COMPUTED issue-number archaeology in skill bodies/refs = 352
COMPUTED issue-number archaeology in skill bodies/distinct = 137
COMPUTED harness mass/tests = 444
COMPUTED prose-pinning tests/grep skill.md = 187
COMPUTED harness mass/scripts = 91
COMPUTED escapes/hotfix = 0
COMPUTED escapes/revert = 0
COMPUTED friction/harness-friction-lines = 0
COMPUTED friction/human = 0
COMPUTED friction/hotfix = 0
COMPUTED escapes/later-fix = 2
COMPUTED friction/manual-merge = 0
COMPUTED friction/compactions = n/a (no transcript substrate)
COMPUTED friction/harness-friction-window = cycle 11 issue comments
COMPUTED friction/denials = n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)
cost: issue=#1339 tokens=29883836 stages=2
cost: issue=#1340 tokens=34010624 stages=2
cost: issue=#1341 tokens=42636337 stages=5
cost: loop-own tokens/issue median = 34010624
cost: backfill = ran
verdict-candidates: 1341 1340 1339

Cost rows are 2× (backlog #70): every stage this cycle has a `source=forward` row (synchronous `Agent`, the PostToolUse hook saw usage) AND a `source=retroactive` backfill row for the same `agent_id`. Dedup'd by agent_id: #1339 14.9M (exec 10.5M / 58 tool uses / 540 s, pr-eval 4.4M / 24 / 674 s) · #1340 17.0M (exec 12.7M / 66 / 369 s, pr-eval 4.3M / 23 / 426 s) · #1341 21.2M (classify 0.5M / 6, plan 7.5M / 45 / 608 s, plan-eval 4.0M / 28 / 347 s, exec 5.6M / 35 / 567 s, pr-eval 3.7M / 23 / 261 s) → **loop-own median 17.0M** (cycle 10 dedup'd 23.4M; cycle 9 29.6M).

Mass: words 56393 → 56347 (−46; #1341 −72 words across four skills, all ≤ 0 per file, +1 token/site from #1340) · scripts 91 (+~60 LOC) · hooks 14 / 4466 LOC (+0) · tests 444 (+141 LOC, no new files) — every prose budget met. Escapes: hotfix 0, revert 0, `later-fix` 2 = #1339 (fixes #1334's scanner blind spot, the class the cycle-10 evaluator caught) and #1341 (fixes #1335's relative `mktemp -p` and #1334's `${CLAUDE_PLUGIN_ROOT:-.}` clause) — both by-design follow-ups, counted against #1334/#1335 below. Gate yield: 1 real defect fixed pre-merge (#1339's fixture scanner test self-tripped on its own marker grep — CI green, would have discriminated only by glob order). Weak-model pass: 5/5 (calib run #5). Fixtures left behind: 0 under `.claude/scratch/` and `/tmp` (only the sanctioned `plan-drafts/`).

Suite runs (from the subagent transcripts): 3/3 executors ran `--changed-only "$PWD/tests"` exactly once, 0 `--chunk` runs; the #1341 executor's selection was 113/444 (`pipeline.config.example`-style over-selection did not recur; `test-path-b-default-split-role.sh` flaked-then-recovered twice). Hook denials (real, from transcripts): 5 — `block_deletions` 2 (both `rm -rf "$S"` variable shape, denied by design; the literal form then succeeded), `restrict_paths` 2 (a `/tmp` literal inside heredoc prose; a `"$S"/` trailing-slash form), `enforce-comment-trust` 1 (plan-issue Step 3b, the #46 line — fixed by #1340 after that dispatch).

### Verdicts

- **#1333 — confirmed.** Calibration run #5 (strict + sonnet): 5/5 executed, no `superseded`, reftest 5/5, unexpected-files 0, 3622 s — first clean strict baseline. Scorecard `weak-model pass` row updated. Residual: 10 stale sandbox worktrees survive `--reset` (backlog #69).
- **#1335 — confirmed.** `block_deletions.py` false-positive lines 2 (cycle 10, fix-not-live) / 5 (cycle 9) → **0** (the two `$VAR` denials are the designed arm; each agent then used the literal `.claude/scratch/<name>` form and cleaned up); fixtures left behind 6 → **0**; cage green on every head (CI). Friction residue: the deny message does not hint that a literal path is allowed (pr-eval #1339) — a one-line hook message tweak, not a hypothesis change.
- **#1334 — no-effect.** D executor (collapsed, sonnet) tokens median 16.0M → 11.6M (−27 %), tool uses 88.5 → 62 (−29.9 %) — both under the spec's 30 % band; the ≤ 40 target was missed (58 / 66); no PATH B this cycle so the B GREEN arm is unmeasured (cycle 10's B row was itself doubled: 43.2M real). Mechanism adopted 3/3 with zero chunk runs, and the quality arm held (0 CI-red heads after #1339 landed the scanner class). Per Step 6 the backlog entry (#57) moves to the bottom; the mechanism stays (cheap, adopted, and #1339 closed its only escape).
- Pending (retro next cycle): #1339 (CI-red heads from a skipped scanner 1 → 0), #1340 (comment-trust TP lines 2 → 0 — the plan-issue dispatch this cycle ran BEFORE #1340 merged), #1341 (rebase / relative-mktemp / inherited-root classes 6 → 0; contradictions row 5 → ≤ 2).

### Friction (20 lines; cycle 10: 19)

Classes: prose-vs-plan drift 6 (#1341 execute: unlisted byte-identical pin test, 14640 vs 14641 baseline ×2, L238/L239, ambiguous `**Friction capture:**` anchor, `superpowers:code-reviewer` unregistered) · orchestrator-observed harness defects 4 (fullsend Step 1a continuation defeats `command_mask` — #1342; plan-waves glob expansion — #54; cost double-count — #70; evolve SKILL "async → no usage" claim — #70) · hook-message/prose residue 4 (block message no literal hint; relative `mktemp -p` ×1 — fixed by #1341; `≤ 0 words` unsatisfiable as a token count; Step 11.2 over-warns) · known TP 1 (Step 3b — fixed by #1340) · restrict_paths FP 1 · `fetch-issue-attachments.sh` PROJECT_ROOT guard vacuous 1 · flake 1 · leaf report omitted the tail 1 (#71) · `none` 2.

New this cycle, filed: **#1342** — `ENV=x \⏎ gh pr create --base main` and `ENV=x \⏎ gh issue view --json body,comments` bypass `enforce-base-branch.py` / `enforce-comment-trust.py` (rc 0; single-line forms rc 2; `block_deletions` unaffected) because `command_mask.segments()` keeps the continuation as the head word. Cycle-12 slate candidate #1.

### Cycle-12 candidates

#1342 (D, guard bypass) · #70 (D, cost dedup — the scorecard's cost rows are untrustworthy until then) · #67 (D, capability-refusal WARN) · #68 (D, `setup-worktree.sh` `PIPELINE_SYNC_*` under `set -u`) · #54 (D, plan-waves glob/negated mentions — recurred) · #6 (A, `superpowers:code-reviewer` ref — surfaced again) · #71 (A, leaf report tail).
