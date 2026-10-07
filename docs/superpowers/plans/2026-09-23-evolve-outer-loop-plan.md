# Evolve outer-loop plan (2026-09-23)

Operator-directed plan wrapped around the harness-evolve loop (tracker #1271), written after 17 cycles and the
independent review at `docs/retros/evolve-loop-review-2026-09-23.md`. The inner loop stays paused unless a step says otherwise.

Review verdict in one line: the loop shipped ~6 valuable harness changes out of 48, then spent cycles 10–17 mostly repairing its own
instruments (57% self-referential work overall), never measured $/PR, and never filed the two operator hypotheses (#11 superpowers
necessity, #12 guard-hook necessity).

## Step 1 — ship what is good (today)

- [ ] `/pipeline:evolve pause` from the evolve session → merge-back PR `evolve → staging` (cycles 13–17, ~15 PRs), `paused` label set.
- [ ] Operator validates staging in the main checkout (`pipe`): one real slate, watch the hard-deny hooks on non-evolve command shapes.
- [ ] Operator promotes `staging → main` per `docs/release-cadence.md`; release-please cuts the release.
- Exit: staging = evolve, main = staging, loop paused.

## Step 2 — retool (one directed cycle, ~2 h wall, run with plain `/pipeline:fullsend <ids>` — NOT the evolve loop)

File these as `evolve` issues (Context/Scope/Affected/Notes + `## Evolve` block) and run them as ONE wave:

- [ ] **Calibration prices itself** — `dev/calib/template/` ships the agent-cost logging hooks + `PIPELINE_LOGS_ENABLED=true` wiring so
      `CALIB-TOTAL cost=$<n>` is real (backlog #19, open since cycle 2); add 2–3 planted defects to the slate so gate yield can be non-zero;
      ingest stamps profile/model/date and renders `stale (N cycles)` past 3. Metric: first non-`$0` calibration total.
- [ ] **#1390** — launcher scrubs inherited `PIPELINE_*` (already filed).
- [ ] **Retro ordering** — `run-retro.sh --cycle N --write` dates its window from the prior cycle comment / issue `createdAt` when the
      `Cycle N` header does not exist yet; timestamp-granular window (backlog #80); delete `friction/compactions` (no substrate).
      Metric: non-`n/a` rows in the Step-1 retro (today 4 → ≥ 12).
- [ ] **Grader split + kill switch in code** — Step 2 verdicts resolved by a fresh agent (different model via `--model`) that sees only
      issue body + Metric line + retro data, never the dispatch prompts; Step 3 writes the Metric before any prompt exists; wrapper greps
      Step-4 prompts for pending-metric tokens and fails the cycle on a hit; diminishing-returns implemented in `evolve-loop.sh` with a test.
      Metric: confirm rate becomes informative (< ~60%); hedged verdicts → 0.
- [ ] **Wrapper blocks + yield line** — default `--cycles 3` with an operator checkpoint; emit `LOOP-YIELD cycle=N merged=k loc=+a/-b rows_moved=m tokens=t`
      per cycle; auto-append the retro index row to `docs/retros/README.md`.
- Also adopt (no issue needed): stop prose-drift sweeps (scanner every 5 cycles instead), freeze the guard-hook surface (no more FP
      tuning until Block A decides), route tooling repairs to the hotfix lane outside the 3-issue cap.

## Step 3 — run the operator's questions (3 blocks, ~6 priced calibration runs, ~$300–600, ~10% of a 5-h window each)

Each block = two `calibration-run.sh --run --profile strict --model sonnet` arms on the same slate with ONE variable flipped, launched
from a clean shell (never source `pipeline.config` in the launching call). Compare: $/PR, wall, reftest, unexpected-files, escapes.

- [x] **Block A — guard-hook necessity (#12)** — DONE 2026-09-25: run #9 (on) ≈$272/76.5M/4087 s vs run #10 (off) $301/86.1M/4011 s; reftest 5/6, planted caught, unexpected 1 in both → **no-effect; keep hooks, stop FP tuning** (tracker comment). Original spec: hooks registered vs hooks removed from the staged harness manifest.
      Decision rule: hooks off is not worse on reftest/escapes and cheaper → delete or gate per stage; else keep and stop tuning.
- [x] **Block B — superpowers necessity (#11)** — DONE 2026-09-26: run #11 (on) $301/84.8M/5994 s vs run #12 (off) $315/89.6M/5619 s; reftest 6/6, planted caught both; unexpected 2 → 0 → **no-effect; leave invocations, fallback makes them optional** (tracker comment). Original spec: inner skills (brainstorming / writing-plans / TDD / systematic-debugging / code-reviewer)
      on vs off (fallback-inline behaviour) for the sonnet executor. Decision rule: same as A, per stage.
- [x] **Block C — trust profile (#2 / #10)** — DONE 2026-09-26: run #13 lean+opus-single $300/88.6M/5184 s vs #11 $301/84.8M/5994 s; 6/6, planted caught, eval fixes 3 → 1 → **no-effect on cost, wall −14%, strict stays default** (tracker comment). Original spec: `lean` + `PIPELINE_PATH_B_MODEL_EXECUTE=opus` vs `strict` (backlog #28: without the opus
      executor `lean` only exercises the A/D plan-eval skip). Decision rule: pick the default profile; decide split-role gating.
- Optional Block D: same slate against the previous harness release tag as a control (holdout).

## Step 4 — decide the inner loop's fate

- If any block moves a PRICED $ or wall row (band 15% on calibration deltas, 30% on real work): restart the loop in 3-cycle blocks with a
  hard rule — ≥ 1 of 3 slate issues must originate from bomon-web / work-orchestrator / staging friction (Step 1b harvests hotfix /
  manual-merge / `human` / plan-round counts via `gh`), and add the outcome metric the loop cannot control: real-repo escapes per merged
  PR (trailing 30 days).
- If nothing moves after two blocks: stop the loop; remaining harness work goes on the ordinary staging slate; close #1271 with a
  final comment pointing at the review.

## Ownership

- Evolve session (`pipeLOOP`): Steps 1 (pause + PR), 2 (file + fullsend), 3 (launch arms, report per block with the numbers), 4 (bookkeeping).
- Operator: staging validation + main cut (Step 1), the decision after each block (Step 3), the Step-4 call.

## Standing rules carried forward

- Never source `pipeline.config` in the same Bash call that launches `calibration-run.sh` / `evolve-loop.sh` (run #6 abort).
- Every detached launch pairs with a persistent Monitor watcher + push notification on completion.
- No tracker-body edits while a headless cycle runs (fence 3 clobbers concurrent edits).
- Calibration runs stay operator-gated until Step 2 makes them priced and unattended.
