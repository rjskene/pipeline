# Harness-evolve loop — independent review (cycles 0–16)

Reviewed 2026-09-23. Sources: loop spec, `skills/evolve/SKILL.md`, `scripts/{evolve-loop,run-retro,evolve-projection,calibration-run}.sh`,
`docs/retros/cycle-00..16.md`, `docs/retros/calib/*`, tracker #1271 (body + 17 cycle comments), 46 merged PRs into `evolve`,
`.claude/logs/agent-costs.jsonl` (697 rows). Cycle 17 is in flight and excluded from the tables.

> **Live finding, flag first.** Calibration run #6 (this morning, `docs/retros/calib/2026-09-23.log`) **aborted in ~61 s**. It handed
> `/pipeline:fullsend 40 41 42 43 44` five **CLOSED** issues whose titles ("epic tracker (web-PR self-verification)", "remote-control-tmux
> mode", "run-queue queue-complete emit fix"…) are **not** the five slate titles in `dev/calib/slate/*/title.txt`. No `.txt` artifact was
> written, so `run-retro` will keep citing the 2026-09-14 run as current. That is the **4th of 6 calibration runs to grade the instrument
> instead of the harness**.

---

## 1. Per-cycle table

Verdict columns = verdicts **resolved in** that cycle (about cycle N−1's issues). `medM` = loop-own median tokens/issue (M).
`fric` = HARNESS-FRICTION lines in the cycle comment. `den` = `friction/denials`. `Δ5h/Δ7d` = usage-gate deltas (pp).

| cyc | date | issues | paths | merged | conf | no-eff | regr | medM | fullsend min | fric | den | Δ5h | Δ7d | a/b/c |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | 09-05 | 1272/1273/1274 | BBB | 3/3 | 3 | 0 | 0 | n/a | n/a | 67 | n/a | −1 | +10 | 0/3/0 |
| 1 | 09-06 | 1280/1281/1282 | C,B,human | 2/3 | 1 | 0 | 0 | n/a | n/a | 54 | n/a | +33 | +9 | 1/2/0 |
| 2 | 09-06 | 1285/1286/1287 | C,B,B | 3/3 | 1 | 0 | 0 | n/a | n/a | 47 | n/a | +29 | +6 | 1/1/1 |
| 3 | 09-06 | 1291/1292/1293 | C,B,B | 3/3 | 2 | 0 | 0 | 40.0 | (13 h cycle) | 42 | n/a | −1 | +9 | 1/1/1 |
| 4 | 09-07 | 1298/1299/1300 | BBB | 2/3 | 1 | 1 | 0 | 47.8 | n/a | 25 | n/a | +16 | +3 | 2/1/0 |
| 5 | 09-08 | 1303/1304/1305 | B,B,D | 3/3 | 3 | 0 | **1** | 64.6 | n/a | 45 | n/a | +58 | +10 | 1/2/0 |
| 6 | 09-10 | 1294/1282/1306 | B,B,D | 3/3 | 4 | 0 | 0 | 19.6 | ~90 | 22 | n/a | +27 | +5 | 2/1/0 |
| 7 | 09-11 | 1315/1316/1317 | B,B,A | 3/3 | 1 | 1 | 0 | 37.4 | ~77 | 51 | n/a | +27 | +3 | 3/0/0 |
| 8 | 09-11 | 1321/1322/1323 | B,A,D | 3/3 | 4 | 0 | 0 | 18.6 | ~106 | 42 | n/a | +27 | +5 | 2/0/1 |
| 9 | 09-14 | 1327/1328/1329 | D,A,B | 3/3 | 1 | 2 | 0 | 29.6 | ~72 | 48 | n/a | +16 | +3 | 3/0/0 |
| 10 | 09-14 | 1333/1334/1335 | D,B,D | 3/3 | 3 | 0 | 0 | 23.4 | 51 | 19 | n/a | +20 | +2 | 2/1/0 |
| 11 | 09-14 | 1339/1340/1341 | D,D,A | 3/3 | 2 | 1 | 0 | 17.0 | 69 | 21 | n/a | −12* | +2 | 3/0/0 |
| 12 | 09-15 | 1342/1346/1347 | DDD | 3/3 | 3 | 0 | 0 | 11.4 | 24 | 12 | n/a | +9 | +2 | 2/1/0 |
| 13 | 09-21 | 1360/1361/1362 | D,D,A | 3/3 | 3 | 0 | 0 | 15.2 | 50 | 19 | 3 | +20 | +3 | 2/1/0 |
| 14 | 09-21 | 1366/1367/1368 | A,A,D | 3/3 | 3 | 0 | 0 | 19.9 | 51 | 18 | 16 (5 real) | −46* | +2 | 2/1/0 |
| 15 | 09-22 | 1372/1373/1374 | D,A,A | 3/3 | 3 | 0 | 0 | 18.4 | 37 | 19 | 0 (139 lost) | +39 | +6 | 2/0/1 |
| 16 | 09-22 | 1380/1381/1382 | D,B,D | 3/3 | 3 | 0 | 0 | 22.3 | ~90 | 15 | 266 (262 probes) | +16 | +2 | 1/0/2 |

\* 5-hour window reset mid-cycle; delta unusable.

**Totals** — 51 issue-slots, 48 merged (1 `human`, 1 withdrawn at plan time, 1 re-run). Verdicts **41 confirmed · 5 no-effect · 1 regressed** (87 % confirm rate).
Classification **(a) consumer-facing 30 · (b) loop instrumentation 15 · (c) loop-inflicted friction 6**.
(b)+(c) share: cycles 0–5 **67 %** → 6–11 **17 %** → 12–16 **40 %** (cycle 16 alone 2/3).
Add the 8 `(a)`-classed repairs to the PreToolUse guard surface the loop itself armed in cycle 6 (#1294) and **29/51 = 57 %** of all work is self-referential or self-inflicted.

**Path drift:** B 21 · D 17 · A 9 · C 3 · human 1. PATH C last run in **cycle 3**. PATH B: 11/18 in cycles 0–5 → 1/15 in cycles 12–16. The slate migrated to the cheap lanes without a decision.

**Output collapse** (merged additions/day into `evolve`): 09-05→09-08 ≈ 3.1k–7.3k LOC/day → 09-21/22 **329 / 411 LOC/day** — ~10–20× less change per cycle at roughly flat cost (~55–65 M attributed tokens/cycle; 4.08 B deduped tokens over the whole loop).

---

## 2. What actually moved on the scorecard

| Row | Baseline (c0) | Now (c16) | Moved? |
|---|---|---|---|
| stage cost share · gates $810 · split-role $650 · B-over-D $728 · median PATH B PR ($55/23 M/44 min) · plan-eval Revise 35/21/28 % · staging CI 2/398 | — | **byte-identical text, reprinted in all 18 retros** | **never recomputed, any of them** |
| pr-eval yield | 0 Flagged / 56 | 0 Flagged; 10 pre-merge evaluator fixes annotated | annotation only |
| harness mass — words | 55 000 | 56 412 | **up** |
| — skills / scripts / tests | 18 / 84 / 405 | 19 / 92 / 451 | **up** |
| — tests LOC | 69 k | 82.1 k (+19 %) | **up** |
| — hooks LOC | 5 000 | 4 621 | down — all of it cycle 0's self-audit deletion |
| prose-pinning tests | 165 / 38 | **188 / 48** | **up 14 % / 26 %** (backlog #8 wanted down) |
| issue-number archaeology | 351 / 130 | 347 / 138 | flat |
| doc/behaviour contradictions | 4 in one session | *"a RATE, not a backlog"* (#66); 1–2 new shapes/cycle | flat |
| weak-model pass | n/a | **5/5** | **moved — the one real win** |
| loop-own tokens/issue | (new row) | 11.4–64.6 M, no trend | slate-shape noise |

**Two rows moved the right way in 17 cycles.** Every mass row moved the wrong way; every dollar row is frozen baseline text.

**Calibration — the anti-mirror — shows no speed gain and has never priced anything:**

| run | date | cycle | profile | reftest | wall | cost |
|---|---|---|---|---|---|---|
| #2 | 09-06 | 2 | strict+sonnet | 3/5 | 3516 s | `$0` |
| #3 | 09-08 | 5 | lean+opus | 2/5 | 4577 s | `$0` |
| #4 | 09-11 | 7 | strict+sonnet | 2/5 | 4158 s | `$0` |
| #5 | 09-14 | 11 | strict+sonnet | **5/5** | 3622 s | `$0` |
| #6 | 09-23 | 17 | — | **aborted 61 s** | — | — |

Wall clock **3516 → 3622 s (+3 %)** across 11 cycles of "improvement". Root cause of `$0`: `issue_cost()` needs `PRICING_TOTAL` from
`cost-latency-report.sh --emit-pricing-json --capture-log $SANDBOX/.claude/logs/agent-costs.jsonl`, and **the sandbox template ships no
cost-logging hooks**, so that log never exists. Backlog **#19 named this in cycle 2 and it was never slated.** Consequence: `$/PR` and
`tokens/LOC` — the two headline hypotheses of the entire loop — have **never once been measured**. Ingest is newest-**by-filename**, never
expires, so cycles 12–16 all cite a run that is now 9 days and 6 cycles stale.

---

## 3. The retro's `n/a` rows are a one-line ordering defect, not missing substrate

This is the single most consequential finding and the loop never found it in 100 backlog entries.

`run-retro.sh --cycle N` runs at **evolve Step 1 (observe)**, but Step 3 — which appends the `Cycle N (<date>):` block to the tracker — runs
**after** it. So at retro time `parse_cycle_issues` finds no header → `CUR_ISSUES=""` → `cycle_window` has nothing to date from →
`CYCLE_SINCE=""` → and every window-scoped row prints its `n/a` string:

- `escapes: hotfix / revert / later-fix` — `n/a (no cycle window)` in **15 of 17** retros
- `friction: hotfix / manual-merge` — `n/a (no cycle window)` in **15 of 17**
- `friction: denials` — `n/a` in **14 of 17**
- `gate-yield: Flagged/evals` and `Revise/plans` — `0/0` in **16 of 17** (scans the current cycle's issues, which do not exist yet)
- `median path b pr/*` — falls through to the verbatim frozen baseline

Re-running `run-retro.sh --cycle 16` against today's tracker body yields `cycle-issues: 1380 1381 1382`, `friction: hotfix = 0`,
`manual-merge = 0` — **real numbers**. The only difference is tracker timing. Separately, `friction: compactions` is a hard-coded literal
with no code path that could ever set it, and the cycle window is **date-granular** (lexicographic `YYYY-MM-DD` compares), so two cycles on
one day double-count (backlog #80, cycles 13/14 and 15/16).

Net: **the loop has been steering on 4 live rows (mass, friction-lines, denials-in-`--post`, loop-own tokens) and 11 dead ones for 17
cycles**, and those 4 live rows are exactly the self-referential ones.

---

## 4. Verdict — has the loop run its course?

**Yes, in its current form.** Not because it stopped working — 3/3 merged every cycle, one regression in 51 issues, zero reverts — but
because what it now optimises is itself.

1. **Yield collapsed** ~10–20× (3.1k–7.3k → ~350 LOC/day) at flat cost; slate drifted B/C → A/D.
2. **Self-referential share is rising again**: 17 % (c6–11) → 40 % (c12–16) → 67 % (c16). Cycle 16's own Diagnose: *"fix the instrument before spending another cycle measuring with it."*
3. **Backlog is 88 % self-generated** — 12 seeded hypotheses vs 88 loop-friction entries. Of the 12, **#3 fullsend diet, #5 pr-eval retarget, #8 prose-pin retirement, #9 B→D routing, #10 split-role gating, #11 superpowers necessity, #12 guard-hook necessity have never been filed in 17 cycles.** #11 and #12 are operator asks dated 2026-09-05. #2 (trust profile) is the only cost lever tried; it `regressed` on a contaminated run and was switched off by un-flipping a knob.
4. **Verdict quality is weak.** 41/47 confirmed. ~20 of the 41 measure an internal counter only. Three of the last six are hedged in the loop's own words: *"confirmed on substance, proxy dead"* (#1373), *"confirmed (mechanism), unexercised"* (#1374), *"confirmed (unit half)"* (#1368).
5. **Friction is 100 % self-sourced.** Zero HARNESS-FRICTION lines in 17 cycles came from bomon-web / work-orchestrator / staging; the only mention of those repos in any retro is the frozen baseline line. Cycle 16's 15 lines are all about the loop's own skill prose, issue bodies and dispatch prompts.
6. **The denial data does not show what the loop thinks.** Cycle 14 audit: 13 rows, **5 real**, the rest evaluator negative-control probes. Cycle 16: 266 rows, **262 `session=unknown` by construction**.
7. **The kill switch cannot fire.** Diminishing returns is **prose only** — one sentence at `skills/evolve/SKILL.md:126`, no script, no test (`grep -rl diminishing tests/` → nothing). `evolve-loop.sh` has no notion of it; it stops only on the `paused` label, `--cycles`, `--max-resumes`(2), `--max-pauses`(6), `halt-7d`. And the same session files, coaches and grades, so `confirmed` is near-guaranteed.

**Counterweight, fairly stated.** The loop produced real value: **#1294** (four PreToolUse guards exited 1 and had **never blocked anything
in production**), **#1317** plan-round binding (rounds 3–4 → 1; loop-own median 64.6 → 19.6 M), **#1334/#1339** `--changed-only`,
**#1316** worktree-leak guard, **#1286** headless contract, **#1321/#1327/#1342** hook argument-position matching. ~6 genuinely valuable
changes out of 48. Cycles 6–9 were the productive era; 12–16 are maintenance of the measuring apparatus.

---

## 5. Structural weaknesses (tested, not assumed)

| # | Weakness | Evidence |
|---|---|---|
| W1 | **One session files, ranks, coaches and grades.** Step 2 ranks; Step 3 writes the issue *and its own Metric line*; Step 4 authors the dispatch prompts; Step 2 next cycle grades. | Cycle 15 admits it: *"all three need UNCOACHED prompts — every cycle-15 dispatch named the `PIPELINE_LOGS_ENABLED=false` prefix, the `Path.joinpath` workaround and the `code review #<N>` shape."* |
| W2 | **11 of 15 scorecard rows are structurally dead** — §3. The loop optimises the 4 that live, all self-referential. | verified by re-run |
| W3 | **30 % band + n=1 makes cost/latency unfalsifiable.** Medians swing 11.4→64.6 M on slate shape alone. | Cycle 13: fullsend 69→50 min (−27 %) logged as *"under the 30 % latency band on its own."* |
| W4 | **Calibration is too small, too easy, unpriced, stale-tolerant, operator-gated.** 5 issues, **no planted defects** (spec §8 promised one; never built), `cost=$n/a` always, newest-by-filename ingest with no expiry, run ~once per 5 cycles. Run #6 aborted today. | 6 runs / 17 cycles; 4 graded the instrument |
| W5 | **The loop armed a guard surface, then spent ~18 % of capacity de-burring it.** #1294 flipped four guards inert→blocking; #1282/#1321/#1323/#1327/#1335/#1342/#1372/#1380 then repaired the FPs. | Backlog **#12** — *"a hook with zero true positives over N cycles is a deletion candidate"* — never slated. Nine issues on a surface whose value was never tested. Note the loop's own sessions run `--dangerously-skip-permissions`, so these hooks are its only safety rail — all the more reason to test them, not tune them. |
| W6 | **Prose drift is a treadmill.** Backlog #66: the #1328 sweep zeroed five classes and four new ones appeared the same cycle. | 6 sweep issues; contradictions row flat; prose-pins up 14 % |
| W7 | **Pending-verdict lag.** Cycle 16: all three c15 PRs merged at 05:31Z so *"no post-merge measurement window exists yet"* — a whole cycle produced zero verdicts on its own work. #1285/#1286 waited 3 cycles; #1368's calibration half is 3 cycles unresolved. | steering on a 1–3 cycle delay |
| W8 | **Plan-eval ceremony is a known, unslated cost.** Cycle 14: two PATH A plan-evals = 13.4 M = **31 % of cycle spend** vs a 14 % baseline share. | Backlog #83 filed; "fixed" in c15 by *coaching the dispatch prompt*, i.e. not in the harness |
| W9 | **Wrapper cadence vs operator gating point the wrong way.** `evolve-loop.sh` runs `--cycles 0` unbounded, 3 h/session, auto-sleeps on `pause-5h`, one operator checkpoint only (the `paused` label). Calibration — the one anti-mirror measurement — is operator-gated. | So the cheap mirror runs free and the expensive truth runs rarely |
| W10 | **The wrapper cannot tell success from failure.** It discards `claude`'s exit code entirely (`dispatch \| tee "$LOG"`, no `PIPESTATUS`), so a `timeout` rc 124 or a crash is indistinguishable from a clean exit; the *only* success criterion is the tracker Mode line reading `step done`. Nothing about PRs, CI, tests, verdicts or the retro. | `evolve-loop.sh:333, 391` |
| W11 | **The loop's own artifacts rot.** `docs/retros/README.md` index still says *"No cycles have been posted yet … _(none yet)_"* after 17 cycles, while the loop files issues about others' doc drift. | — |

---

## 6. Ranked changes to the loop itself

### 1. Fix the retro ordering — 11 dead rows come back for ~one line of work
- **Change:** move the Step-3 tracker `Cycle N (<date>):` append **before** the Step-1 retro (or have `run-retro.sh --cycle N` date its window from the issues' `createdAt` / the prior cycle comment when no header exists). Make the window **timestamp-granular**, not date-granular (backlog #80). Delete `friction/compactions` (hard-coded, no substrate).
- **Effect:** `escapes/*`, `friction/hotfix`, `friction/manual-merge`, `friction/denials`, both `gate-yield` rows and `median path b pr/*` start rendering for the first time — the loop gets an outcome signal it has never had.
- **Cost:** hours. **Measured by:** count of non-`n/a` rows in the next retro (today 4 → target 12+).

### 2. Split the filer from the grader; ban coached metrics
- **Change:** Step 2 verdict resolution runs as a **separate fresh agent** (`evolve-loop.sh` already has `--model`, so use a different model) that sees only (issue body, Metric line, retro data) and never the dispatch prompts. Step 3 must write the Metric line before prompts exist; add a grep guard in the wrapper that fails a cycle whose Step-4 prompts name any token from a pending metric.
- **Effect:** kills the contamination the loop already documented; the 87 % confirm rate becomes informative; the diminishing-returns rule becomes reachable. Also **implement that rule in `evolve-loop.sh`** (it is prose-only and untested today) and add a test.
- **Cost:** ~1 cycle. **Measured by:** confirm rate falls below ~60 %; hedged verdicts → 0.

### 3. Stop doing four things (frees ~1.5 of 3 slate slots, costs nothing)
- **Prose-drift sweeps** — backlog #66 proves it is a rate. Replace with a scanner run once per 5 cycles; file only what it finds.
- **Guard-hook FP whack-a-mole** — freeze the surface; run backlog #12 instead.
- **Instrument-repair issues on the slate** — route `run-retro` / `calibration-run` / `capture-agent-costs` fixes to a hotfix lane outside the 3-issue cap. They are tooling, not hypotheses, and they currently eat 1–2 of 3 slots.
- **Permanently-`n/a` rows** — after change #1, delete whatever still cannot compute. A dead row makes the scorecard look fuller than it is.

### 4. Run the two necessity experiments — backlog #12, then #11/#2/#10
- **Change:** run them as **A/B calibration arms**, not code edits: hooks on/off, superpowers on/off, `strict` vs `lean` **paired with `PIPELINE_PATH_B_MODEL_EXECUTE=opus`** (backlog #28 — without it `lean` only exercises the A/D plan-eval skip, which is why the cycle-5 `regressed` verdict is not trustworthy).
- **Effect:** the only levers with real headroom (gates 30 % + split-role 24 % of baseline spend ≈ $1,460/window) are currently untested; a guard set with ~zero true positives over 17 cycles is a deletion candidate worth 4.6 k LOC.
- **Cost:** 2 cycles + 4–6 calibration runs (~$300–600). **Measured by:** priced calibration cost per arm; reftest 5/5 held; escapes not up over 3 following cycles.

### 5. Make calibration price itself, bite, and run every cycle
- **Change:** (a) ship the agent-cost logging hooks in `dev/calib/template/` so `cost=` is real (backlog #19, open since cycle 2) — without this no $ hypothesis is testable; (b) fix the run-#6 slate-id defect (it dispatched five closed, unrelated issues); (c) add **2–3 planted defects** so `gate yield` can be non-zero; (d) grow to 8 issues and re-include a **PATH C** (unexercised since cycle 3); (e) **expire the ingest** — stamp profile/model/date and render `stale (N cycles)` past 3; (f) run it **every cycle, unattended**.
- **Cost:** 1–2 cycles, then ~$80–150/cycle. **Measured by:** a `CALIB-TOTAL cost=$<n>` that is not `$0`; a wall-clock series with ≥8 points; non-zero gate yield.

### 6. Three-cycle blocks with a holdout; tighten the band
- **Change:** fix the slate path-mix across a 3-cycle block, change one harness variable per block, compare block medians. Band **15 %** on calibration deltas (fixed inputs), keep 30 % for real-work. Every 4th cycle, run the **previous harness tag** against the calibration slate as a control.
- **Effect:** the first falsifiable cost/latency verdict in the loop's history (it has produced zero). **Cost:** ~1 cycle + the holdout runs.

### 7. Feed real-repo friction; quota it
- **Change:** Step 1b harvests friction/denial/hotfix/manual-merge/plan-round data from **bomon-web, work-orchestrator and staging's nightly `40-pipeline`**, ranked *above* loop-internal lines. Hard rule: **≥1 of 3 slate issues must originate outside the evolve clone.**
- **Effect:** breaks the mirror. The clone-only classes (#1292 Boot fence, #1323 base token, #1381 evolve Step 3 listing) would never have outranked real consumer friction. **Cost:** ~1 cycle; a `gh`-only harvest of hotfix/manual-merge/`human` counts is enough to start.

### 8. A/B by model and trust profile — worth it, and nearly free
- Both `evolve-loop.sh` and `calibration-run.sh` already take `--model` (the wrapper currently pins nothing and uses the account default). Alternate arms per block. Cheapest experiment available; combine with #4/#5.

### 9. Wrapper/automation
- Invert the gating: calibration unattended every cycle; the cheap loop in **`--cycles 3` blocks with an operator checkpoint** instead of `--cycles 0`.
- Check `PIPESTATUS` so a `timeout`/crash is not read as success (W10); require **a verdict was produced**, not just `step done`.
- Emit a per-cycle `LOOP-YIELD` line (issues merged, LOC delta, non-`n/a` rows moved, tokens spent) so the yield trend is visible without reading 17 retros.
- Auto-append the retro index row to `docs/retros/README.md` (stale since cycle 0).

### 10. Shrink the metric set; add one outcome metric the loop does not control
- Keep: mass, real denials, loop-own tokens, calibration cost/wall/reftest. **Add: real-repo escapes per merged PR** (hotfix/revert/later-fix across bomon-web + work-orchestrator + staging, trailing 30 days). It is the only number a consumer would notice.

---

## 7. Recommendation

**Pause the cadence and redirect — do not continue as is, and do not kill it.** The loop did its job: it bootstrapped its own
instrumentation, found a genuinely serious production defect (four PreToolUse guards that had never blocked anything), cut plan-round
ceremony ~70 %, and produced one clean weak-model calibration baseline. But it has now spent five cycles at 40–67 % self-referential work,
drifted to the cheap A/D lanes, and fallen from ~5 k to ~350 LOC/day of harness change at flat cost — while its two headline metrics, `$/PR`
and `tokens/LOC`, have **never once been measured** because the sandbox template still ships no cost hooks (backlog #19, open since cycle 2),
and 11 of its 15 scorecard rows have been silently blank for 17 cycles because the retro runs one step too early. Seven of the twelve seeded
consumer-value hypotheses — including both operator asks (#11 superpowers necessity, #12 guard-hook necessity) — have never reached a slate.
Concretely: let cycle 17 finish, stop the wrapper, and spend one operator-directed cycle on changes **1, 2, 3, 5 and 9** (fix the retro
ordering; split filer from grader and implement the kill switch in code; stop the sweeps and guard whack-a-mole; make calibration price
itself, bite, and run unattended; make the wrapper able to tell success from failure). Then restart in **3-cycle blocks with a hard
≥1-of-3 real-repo-friction quota**, and make the first two blocks the necessity experiments (#12, then #11/#2/#10). If after two blocks no
cost or latency row has moved on a *priced* calibration run, the loop has genuinely run its course and the remaining harness work belongs on
the ordinary staging slate.
