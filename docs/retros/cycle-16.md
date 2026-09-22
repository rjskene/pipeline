cycle-issues: 
pending-verdicts: 1374 1373 1372
verdict-candidates: 

friction: denials = n/a (no cycle window)
friction: harness-friction-lines = 19
friction: harness-friction-window = tracker cycle 15 comment
friction: compactions = n/a (no transcript substrate)
friction: hotfix = n/a (no cycle window)
friction: manual-merge = n/a (no cycle window)
friction: human = 0

HARNESS-FRICTION: issue body Notes says `grep -nE 'code.-.?review' scripts/capture-agent-costs.sh` shows the pr-eval/review mapping | that regex matches nothing; the mapping lives at lines 132/183 as `\bcode[ -]?review\b` (executor should use `grep -nE 'code\[ -\]\?review'` or just `grep -n review`). (#1374 classify)
HARNESS-FRICTION: issue says `grep -l 'execute-issue-plan' tests/*.sh` is 33 files | it is 56 (fullsend set is 59; union with controls = 98) (#1374 plan)
HARNESS-FRICTION: issue Notes says the parser "already maps `code review #<N>` to stage=pr-eval" as if primary | the mapping is in the strictly-fallback table — only fires when no primary STAGE_PATTERNS token is present, which is exactly why the old description ("…approved plan") misfiled as `stage=plan` (#1374 plan)
HARNESS-FRICTION: issue Notes say `grep -nE 'code.-.?review' scripts/capture-agent-costs.sh` shows the mapping | returns nothing; literal is `code[ -]?review` (plan's line refs were correct) (#1374 plan-eval)
HARNESS-FRICTION: plan says `tests/test-sysprompt-payload.sh` "must stay green untouched" | fails 12/18 at HEAD on this host with no edits; CI green (#1374 plan-eval)
HARNESS-FRICTION: dispatch said `gh pr create --body "$(cat <<'EOF'…)"` inline per execute skill Step 9b | body names `/etc/passwd`/`cd /` test data, so it had to go via `--body-file` from `.claude/scratch/` to keep the paths out of Bash command text (#1372 execute)
HARNESS-FRICTION: issue budget "hooks ≤ +4 LOC" | a 3-line explanatory comment + 2 code lines is +5; trimmed the comment to 2 lines to fit, so LOC-vs-comment counting is ambiguous (#1372 execute)
HARNESS-FRICTION: `mktemp -d -p "$PWD/.claude/scratch"` / scratch-dir guidance assumes the dir exists | fresh worktree had no `.claude/scratch/`; first suite-log redirect failed until `mkdir -p` (dispatch prompt did warn of this; the skill body does not) (#1373 execute)
HARNESS-FRICTION: skill Step 8b names `subagent_type: "superpowers:code-reviewer"` | not a registered agent type in this session; used `general-purpose` per dispatch prompt (#1373 execute)
HARNESS-FRICTION: dispatch prompt Task 5(a) said `git grep 'superpowers:code-reviewer' -- skills docs` must return nothing | it returns 13 hits in `docs/retros/*` + `docs/superpowers/specs/*`, which the plan explicitly excludes (`':!docs/superpowers/specs' ':!docs/retros'`) and keeps as historical; the plan-form grep is empty (#1374 execute)
HARNESS-FRICTION: plan predicted docs net −31 | observed −25 (ceiling ≤ 0 still holds; the old §4 paragraph counted fewer words than the plan assumed) (#1374 execute)
HARNESS-FRICTION: dispatch prompt said `test-sysprompt-payload.sh` "fails 6–12/18" | it fails exactly 12/18 (6 pass) on both base and head; also `tests/test-spawn-claude-systemd-scope.sh` fails 12/25 on this host despite `systemd-run` being present — not mentioned anywhere as a known host failure (#1374 execute)
HARNESS-FRICTION: skill Step 1 says attachments live in `.claude/scratch/issue-<N>/` mirrored by `setup-worktree.sh` | fresh worktree had no `.claude/scratch/` at all (had to `mkdir -p` before redirecting test output there) (#1374 execute)
HARNESS-FRICTION: SKILL Step "Build a fixture … run the REAL artifact" | a bare `git show base:hooks/restrict_paths.py > scratch/x.py` is vacuous (sibling `_pipeline_config` / `subagent_log_utils` imports fail, rc=1); the whole `hooks/` dir must be mirrored to get a non-vacuous base RED (#1372 pr-eval)
HARNESS-FRICTION: `tests/test-restrict-paths-hook.sh` (via `env -i`) | ignores exported `PIPELINE_LOGS_ENABLED=false`, writes denial rows to the worktree log even under the evaluator's probe rule (#1372 pr-eval)
HARNESS-FRICTION: skill/issue say a direct hook probe "with a synthetic payload" denies | `enforce-base-branch.py` resolves `EXPECTED_BASE` from the fixture dir (config-less → `main`), so a `--base main` payload was silently allowed (exit 0 both arms) — the first probe was vacuous until the payload used `--base staging`. (#1373 pr-eval)
HARNESS-FRICTION: evolve Step 3 (#1367) says list every `docs/` + `tests/fixtures/` hit under Affected areas | `plan-waves.sh` body fallback reads each hit as an edit edge — a disjoint 1D+2A slate planned as 2 waves until #1372's line was rephrased with the `do not edit` cue; and the listed `docs/security-model.md` tripped `_high-uncertainty-match.sh` so the D ran on opus (orchestrator, backlog #87)
HARNESS-FRICTION: `run-retro.sh --post` `friction/denials` = 0 and observability.md says worktree denials land in the main log | the three worktrees' gitignored `.claude/logs/hook-denials.jsonl` held 136 + 1 + 2 rows (`test-restrict-paths-hook.sh` via `env -i` writes ~30 per run), none visible to the retro (orchestrator, backlog #85)
HARNESS-FRICTION: skill Step 1b says "dispatch classify in parallel, one Agent per issue" | the orchestrator emitted the two classify Agent calls in separate messages, so they ran sequentially — 1 min lost (orchestrator)

delta prose-pinning tests/grep claude.md n/a (baseline row not found: prose-pinning tests/grep claude.md)
delta harness mass/words 35 (baseline 56400 -> computed 56435)
delta harness mass/skills 0 (baseline 19 -> computed 19)
delta harness mass/tests loc n/a (baseline row not found: harness mass/tests loc)
delta harness mass/hooks loc n/a (baseline row not found: harness mass/hooks loc)
delta harness mass/scripts loc n/a (baseline row not found: harness mass/scripts loc)
delta harness mass/hooks 0 (baseline 15 -> computed 15)
delta issue-number archaeology in skill bodies/refs -3 (baseline 352 -> computed 349)
delta issue-number archaeology in skill bodies/distinct n/a (baseline row not found: issue-number archaeology in skill bodies/distinct)
delta harness mass/tests n/a (baseline row not found: harness mass/tests)
delta prose-pinning tests/grep skill.md 1 (baseline 187 -> computed 188)
delta harness mass/scripts 0 (baseline 92 -> computed 92)
stage cost share: execute 33% · orchestrator 19% · pr-eval 16% · plan 14% · plan-eval 14% · classify 4%
gates (plan-eval + pr-eval): 30% of spend, ≈$810
split-role red+green (19 issues): 24% of spend, ≈$650
B-over-D ceremony premium: ≈$728 foregone
median PATH B PR: 320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC
pr-eval yield (Jun→Sep, 3 repos, 56 evals): 0 Flagged (pilot era 2/30); evolve cycle 6: 1 real defect fixed pre-merge by the evaluator (#1282 scratchpad-segment boundary escape, CI green, cage test blind to it); cycle 8: 2 (#1323 CI-red placeholder-grep test the executor mis-classed as pre-existing; #1321 three fail-closed regressions — `\rm` alias bypass, `xargs`-wrapped rm, brace/glob tmp targets — CI green, cage tests blind to them); cycle 9: 1 (#1327 `command_mask` import not co-located in the phase2-coexistence sandbox copy — CI red, executor mis-classed the test as pre-existing, the #53 class again); cycle 10: 2 (#1334 CI-red head from a scanner guard its own `--changed-only` run skipped — the guard's regex began with `-c` and grep had parsed it as an option, dead code on every prior run; and the `${CLAUDE_PLUGIN_ROOT:-.}` form in the rewritten Step 6b diffing the MAIN tree under dogfood — a proven false green `selected=0/442`, fixed with a `$PWD` anchor); cycle 11: 1 (#1339 fixture scanner test self-tripped on its own `SCANNERMARK` grep — scenario 11's `RESULT=fail` discriminated only by glob order; CI green, fixed `177503c` pre-merge); cycle 12: 3 (#1342 executor pinned one of the issue's two comment-trust continuation shapes — the Step 1a `fetch-issue-attachments.sh` shape was unpinned, Case Y added `23da13e`; #1346 two `refute_sub` median controls went vacuous when the fixture grew to 10 records — re-pinned `02a9778`; #1347 `bp_drop_negated_lines` used `else if`, so `never edit X; you do not need…` kept `X` — B11 added `391226d`; all three CI green, tests blind)
plan-eval Revise-first rate: 35% pipeline · 21% bomon-web · 28% work-orchestrator
staging CI after merge: 2 red / 398 pushes, none since June
known escape class: issue 1199 — pr-eval Approved + CI green, 9 false-green assertions; 2 sibling suites likewise
doc/behaviour contradictions (one session): cycle 15: 1 new shape (the evolve Step 3 rule from #1367 — list every `docs/` + `tests/fixtures/` hit under Affected areas — is read by `plan-waves.sh` as edit edges unless the line carries a negation cue, serializing a disjoint slate into 2 waves until #1372's line was rephrased with `do not edit`; the same listing put `docs/security-model.md` in the body and the word-bound high-uncertainty match routed a cheap D to opus; backlog #87) · the cycle-14 "Step 4" shape: 0 lines (fixed by #1367) · Step 8b `superpowers:code-reviewer` (2 lines in cycle 14, 1 pre-merge line in cycle 15) fixed by #1374. cycle 14: 1 new shape (the evaluators' fixture bullet is labelled "Step 4" across issue #1362/#1366/#1367 bodies and backlog #73/#75 — it is the `## Executable verification` bullet at evaluate-issue-pr:65; the #1367 plan-evaluator's Revise caught the mislabel before it shipped into the evolve skill) · cycle-13 shapes (Case G pairing, Step 11.2 async-dispatch NOTE) fixed by #1366; "Step 4" pointer fixed by #1367 round 2. Cycle 13: 2 new shapes (evaluate-issue-pr Step 4 fixture bullet sits inside the Case G byte-identical block — a pr-eval-only edit can never pass, backlog #75; Step 11.2 prose does not name the new `NOTE: … async-dispatch` outcome, #66 standing) · both Step 8 / Step 11.2 shapes from cycle 12 fixed by #1362
weak-model pass (strict + sonnet, 5-issue calibration slate): strict: 3/5 reftest, 3516s (2026-09-06 run #2; #7 D + #8 B unrun — orchestrator held). lean + opus PATH B executor: 2/5 reftest, 4577s (2026-09-08 run #3; A merged with reftest=fail, D pass, B pass +1 unexpected file, B pr-open + B unrun — print-mode background ceiling killed the session mid-wave-2, #1306). Same-input docs issue: strict pass → lean fail. strict + sonnet run #4 (2026-09-11, `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`): 2/5 reftest, 4158s, 0 print-mode terminations (#1306 confirmed) — but run #3's stale sandbox PR survived `--reset` and superseded #23/#26/#27 (backlog #51); still no clean strict baseline. **strict + sonnet run #5 (2026-09-14, after #1333's `--reset` sweep): 5/5 executed, reftest 5/5, unexpected-files 0, 3622 s — the first clean strict baseline** (A 2489 s · D 2985 s · B 3580/2694/2573 s).
loop-own tokens/issue (median, all captured stages): 18.4M (cycle 15, instrument-true — #1372 9.0M D: exec ≈4.6M opus (43 tool uses / 400 s; `REASON=high-uncertainty` from a listed doc filename, #87) + pr-eval ≈3.9M (27 / 290 s) · #1373 18.4M A: classify 0.5M + plan ≈5.0M + 0.6M round 2 + plan-eval ≈3.7M + 0.4M round 2 + exec ≈2.7M (23 / 613 s) + review 0.4M + pr-eval ≈3.6M (20 / 227 s) · #1374 20.0M A: classify 0.3M + plan ≈4.0M + 1.2M round 2 + plan-eval ≈4.3M + 0.3M round 2 + exec ≈3.7M (26 / 417 s) + review 1.0M + pr-eval ≈3.6M (21 / 238 s); fullsend 37 min in ONE wave (1D+2A); A plan-evals 3.7M / 4.3M first round vs 7.6M / 5.8M in cycle 14 — the dispatch prompt scoped them to "the pins the edit could break, not the full battery" (#83 watch: coached this cycle)). Cycle 14: 19.9M (2A+1D). 19.9M (cycle 14, instrument-dedup'd — #1366 23.9M A: classify 0.5M + plan 5.0M + plan-eval 7.6M (49 tool uses, 706 s — full 67-file pin battery on a scratch copy) + exec 7.1M (47 / 890 s) + pr-eval 3.7M (24 / 345 s) · #1367 19.9M A: classify 0.5M + plan 2.4M + 0.7M round 2 + plan-eval 5.8M + 1.1M round 2 + exec 4.2M (37 / 484 s) + pr-eval 4.5M (29 / 292 s) · #1368 10.8M D collapsed: exec 7.8M sonnet (65 / 434 s) + pr-eval 3.0M (21 / 224 s); fullsend 51 min in ONE wave for a disjoint 2A+1D slate; the two A issues' plan-evals (13.4M) are 31 % of the cycle's agent spend vs the scorecard's 14 % plan-eval share). Cycle 13: 15.2M (1A+2D). Cycle 12: 11.4M (3D). Cycle 11: 17.0M; cycle 10: 23.4M; cycle 9: 29.6M; cycle 8: 18.6M; cycle 7: 37.4M; cycle 6: 19.6M; scorecard median PATH B PR 23M

escapes: hotfix = n/a (no cycle window)
escapes: revert = n/a (no cycle window)
escapes: later-fix = n/a (no cycle window)

gate-yield: Flagged/evals = 0/0
gate-yield: Revise/plans = 0/0

weak-model pass: 5/5

usage: five_hour=31% seven_day=47% threshold=85

prev-delta prose-pinning tests/grep claude.md 1 (previous 47 -> computed 48)
prev-delta harness mass/words 23 (previous 56412 -> computed 56435)
prev-delta harness mass/skills 0 (previous 19 -> computed 19)
prev-delta harness mass/tests loc 219 (previous 82082 -> computed 82301)
prev-delta harness mass/hooks loc 54 (previous 4621 -> computed 4675)
prev-delta harness mass/scripts loc 0 (previous 23613 -> computed 23613)
prev-delta harness mass/hooks 0 (previous 15 -> computed 15)
prev-delta issue-number archaeology in skill bodies/refs 2 (previous 347 -> computed 349)
prev-delta issue-number archaeology in skill bodies/distinct 1 (previous 138 -> computed 139)
prev-delta harness mass/tests 2 (previous 448 -> computed 450)
prev-delta prose-pinning tests/grep skill.md 1 (previous 187 -> computed 188)
prev-delta harness mass/scripts 0 (previous 92 -> computed 92)

## Diagnose

### Verdicts on cycle 15 (#1372 #1373 #1374)

All three PRs merged `2026-09-22T05:31Z` (#1375 / #1376 / #1377). Every row in
`.claude/logs/hook-denials.jsonl` and every `HARNESS-FRICTION:` line in the
cycle-15 tracker comment predates that timestamp, so **no post-merge measurement
window exists yet**. Each issue's `Measured by: retro (next cycle)` needs a cycle
whose executors and evaluators run the merged bodies with *uncoached* dispatch
prompts — cycle 15's prompts coached around all three frictions.

- **#1372 (restrict_paths lone `/`) — pending, unit half confirmed.** Direct probe
  at HEAD with `PIPELINE_LOGS_ENABLED=false`: the python-heredoc `Path("x") / "y"`
  shape is now allowed (rc=0) and the `cat /etc/passwd` negative control still
  denies (rc=2). The friction half (in-window deny rows ending `boundary: /` → 0)
  carries to cycle 17.
- **#1373 (evaluator probes under `PIPELINE_LOGS_ENABLED=false`) — pending.** The
  metric is explicitly "the first cycle whose evaluators run the merged skill
  body" = cycle 16.
- **#1374 (Step 8b `general-purpose` + `code review #<N>` attribution) — pending.**
  The metric needs an A/B issue on the next slate to produce a
  `stage=pr-eval role=review` cost row. Cycle 16's slate carries one PATH B.

No verdict is `regressed`; nothing to revert. The three stay in
`pending-verdicts` for cycle 17 step 2.

### Why this slate

Cycle 15's own retro surfaced the measuring instrument as broken: `run-retro.sh`
`friction/denials` printed 0 all cycle while the three merged worktrees' gitignored
logs held 136 + 1 + 2 rows. That row is the in-window signal *#1372's verdict
depends on*, so backlog #85 is ranked first — fix the instrument before spending
another cycle measuring with it. Backlog #87 is second because it cost real money
last cycle twice over (a disjoint 1D+2A slate serialized into 2 waves, and a cheap
PATH D routed to opus off a listed filename). Backlog #86 is third: three friction
lines across cycles 14–15 for a one-line `mkdir -p`.

Deferred: #88 (host-failing tests — docs-only, cheap, but the "fix the host cause"
half is open-ended), #92 (evaluator fixture recipe gaps — contradictions row only),
#79 / #80 (retro parse + window granularity — same file as #85, held back to keep
the slate disjoint and the waves at 1).

Slate: 2 × PATH D + 1 × PATH B, no PATH C. File sets are disjoint
(`hooks/_deny_log.py` · `scripts/_high-uncertainty-match.sh` +
`skills/evolve/SKILL.md` · `scripts/setup-worktree.sh`), so the slate should plan
as a single wave — itself a live check on #87's hypothesis.

## Post

### Slate outcome

All three merged, one wave-2 serialization, no reverts, no CI-red retries.

| issue | path | PR | merge | tokens | notes |
|---|---|---|---|---|---|
| #1380 | D | #1383 | `c2d2d44e` | 22.3M | exec 18.81M sonnet (111 tool uses / 1369 s) + pr-eval 3.50M |
| #1381 | B split-role | #1384 | `8c0667c` | 35.9M | 2 plan rounds; RED 5.84M + GREEN 4.69M + pr-eval 9.61M |
| #1382 | D | #1385 | `b71577d` | 11.4M | exec 7.16M sonnet + pr-eval 4.26M |

Median 22.3M/issue, up from 18.4M (cycle 15). Wall clock ~90 min across two waves.

### Cycle-15 verdicts

- **#1372 — confirmed.** 266 in-window denial rows, 32 of them `restrict_paths`, **0** ending
  `boundary: /` (cycle-14 baseline: 4 of 13). Direct probe at HEAD allows the pathlib-join
  heredoc shape (rc=0) with `cat /etc/passwd` still denying (rc=2). Zero friction lines naming
  pathlib or `'/'`.
- **#1373 — confirmed on substance, proxy dead.** The #1380 pr-evaluator ran four adversarial
  fail-open probe arms and measured the main log at **153 → 153 rows**, with zero stray
  `hook-denials.jsonl` under its worktree — a direct hook probe leaving no trace, which is the
  claim. But the issue's stated metric (`session=unknown` rows → 0) is **invalidated**: #1380
  shipped in the same cycle and routed worktree denials into the main log, and worktree agent
  processes carry no `CLAUDE_SESSION_ID`, so 262 of 266 in-window rows are now `session=unknown`
  by construction. The token no longer separates a probe from a live denial. New proxy needed —
  backlog #99.
- **#1374 — confirmed (mechanism), unexercised this cycle.** `stage=pr-eval role=review` rows
  landed for #1373 (0.50M) and #1374 (1.09M) from cycle 15's own executors running the patched
  Step 8b, and zero friction lines named `superpowers:code-reviewer`. Cycle 16's PATH B produced
  **no** review row — not a regression: the GREEN dispatch prompt never mentioned Step 8b, so the
  review never ran (backlog #94).

### Instrument state

The cycle's headline result is that the friction instrument came back. `friction/denials` read
`0` for all of cycle 15 while three worktrees held 139 invisible rows; this cycle it reads **266**
against a hand count, and the one worktree cut *before* #1380 merged (`wt-1381`) stranded 285 rows
locally while the worktree cut *after* (`wt-1382`) wrote none. That is #1380's hypothesis
confirmed in-flight.

Against that, the **cost** instrument broke — entirely on the orchestrator. Every cycle-16 cost row
landed with `issue=""` because the dispatch descriptions used bare integers (`execute 1380
collapsed D`) instead of the documented `#<N>` attribution key, so `run-retro.sh --post` reported
`cost: issue=#N n/a (no cost records)` for all three issues. The table above was reconstructed by
`agent_id`. One description also mis-staged (`verify plan revision 1381` → `stage=plan`; it was
plan-eval). Backlog #93.

### What the gates caught

The round-1 plan evaluator found a genuine fail-open in #1381's own fix: the planned call-site
shape piped a producer into `grep -iEq` under `pipefail`, so `grep -q` exiting early on a match
sent SIGPIPE to the producer and flipped the `if` to the else branch — **18/20 runs missed** on a
12KB body. That is the carve-out silently failing OPEN in the one predicate whose entire purpose is
to fail CLOSED, and none of the planned fixtures (all small single-line bodies) would have caught
it. Caught pre-merge, on a plan, by reading the two call sites' `set -` lines. Both pr-evals also
appended a missing `## Pre-existing failures` section rather than flagging — the same undocumented
fix-in-eval outcome, reached independently (backlog #97).

### Cycle 16 verdict candidates (deferred to cycle 17)

#1380, #1381, #1382 — `Measured by: retro (next cycle)` for all three. #1380 already has strong
in-flight evidence above; #1381's routing half needs an issue whose only carve-out hit is a path
token, and its wave half is already partly refuted (backlog #95); #1382 needs a fresh worktree
whose executor does not have to `mkdir -p`.
