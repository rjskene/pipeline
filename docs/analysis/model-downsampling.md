# Model Downsampling — Sonnet-on-Execute Pilot & Decision

**Date:** 2026-06-04 · **Status:** decision recorded — **WIDEN (staged)** · **Epic:** #450 (Axis B — cost posture)
**Issues:** spec #868 · decision #950 · routing-gate PR #951

This is the durable record of the bounded experiment that tested routing the pipeline's
**execute** stage to a cheaper model (Sonnet 4.6) instead of Opus 4.8, and the widen/kill
decision it produced. Companion to [cost-architecture.md](../cost-architecture.md) (the cost
analysis that motivated it). Sibling of the closed-loop "dogfood measure → intervene" program.

---

## TL;DR

- Sonnet 4.6 on EXECUTE held **first-pass eval-pr approval at 92.3% (12/13)** vs the **94% (16/17)
  Opus baseline** — a **1.7-pt drop, inside the acceptance band and statistically indistinguishable
  at this n** — at **−80.0% execute cost** (a model price-ratio lever on cached context).
- The **single Sonnet miss was a real, subtle edge-case defect** that the **Opus pr-eval backstop
  caught before any merge** — the exact safety property the design relies on.
- **Decision: WIDEN (staged)** — enable Sonnet execute for the **eligible low-blast lane only**
  (PATH D quick-fix + low-blast single-module PATH B), with **Opus pr-eval mandatory and never
  tier-dropped**, behind the **default-off `PIPELINE_PATH_{B,D}_MODEL_EXECUTE` gate** (PR #951).
  Do **not** widen to high-blast B / PATH C without a separate pilot.

---

## 1. The lever (post-#748 correction)

Closed diary #422 shelved adaptive model selection wholesale without ever separating the cheap
stages from the expensive one. The cost data shows the light stages (classify/plan/plan-eval) are
rounding error; **execute dominates spend**. After #748 flipped execute from the spawned `claude -p`
transport to inline `Agent` (retiring a ~39× output-token inflation), the residual execute cost is
**no longer an output-token problem** — it is a **pure model price-multiplier on the still-large
cached context** (cache_read + cache_creation ≈ 90% of execute cost; output ≈ 7%).

Sonnet 4.6 list price is a uniform **1/5 of Opus 4.8** across every token bucket
(input 3 vs 15, output 15 vs 75, cache_creation 3.75 vs 18.75, cache_read 0.30 vs 1.50 per MTok).
Because the lever is the price tier on cached traffic — not a behavior change — a Sonnet tier-drop
on execute cuts execute cost ~**80%** by construction. The open question was never "how much does it
save" (a price ratio) but **"how much quality does it cost?"** This pilot measured that.

## 2. Experiment design

**Containment (zero trunk impact).** The whole experiment ran in a throwaway sandbox branch
(`experiment/868-sonnet-pilot`, cut off staging) set as `PIPELINE_BASE_BRANCH` for the run, so all
three base-branch enforcement layers routed every worktree and PR to the sandbox. **Evaluate-don't-merge:**
each fixture went Sonnet execute → PR (base = sandbox) → **Opus** pr-eval → **STOP at the verdict**.
Nothing merged; every metric was read from the eval comment + cost log. This makes the
"post-merge defect reaches main" failure mode *structurally impossible* rather than merely backstopped.
The sandbox, fixtures, and PRs were all torn down after harvest.

**Fixtures (n = 13).** Throwaway issues sized to the eligibility gate (§4 below), following the
`[THROWAWAY]` NOOP pattern (#892/#894):
- **10 PATH-D NOOP helpers** — a single shell function + colocated test per fixture (greet, add,
  upper, reverse, repeat, clamp, slugify, is-even, word-count, trim).
- **3 disposable-but-realistic PATH-B helpers**, chosen to stress *judgment* (the actual tier
  differentiator), each with a classic edge-case trap:
  - `kv_get` — config reader (last-assignment-wins, ignore comments, trim, absent→non-zero, split-on-first-`=`).
  - `semver_cmp` — numeric-vs-lexical field compare (`1.2.0 < 1.10.0`), `v`-prefix strip.
  - `dedup_preserve_order` — first-occurrence order preserved (the `sort -u` reorders trap).

**Routing.** Execute was dispatched with the harness `Agent` `model='sonnet'` override (PATH D as the
collapsed `tdd-implementer`; PATH B as `general-purpose`); pr-eval was dispatched on inherited **Opus**.
The orchestrator pinned the model directly at each dispatch — equivalent to the shipped routing gate,
and robust to dogfood skill-body caching.

**Eligibility gate (§4).** PATH D (quick-fix) **or** low-blast single-source-module PATH B:
≤ 1 source module (excl. tests/docs), ≤ 150 added LOC, ≤ 6 files, no security/migration/auth/concurrency
signal. The high-blast multi-module executes are excluded **by construction**.

**Baseline (§3).** The current inline-regime Opus baseline: **16/17 = 94%** first-pass eval-pr approval,
**1 commit-after-eval across 17 PRs**. The lone baseline miss (#757) was a genuine design-gap escalation.

## 3. Data

### 3.1 Per-fixture results

| Issue | PR | Path | Fixture | First-pass verdict | Defects |
|------:|---:|:----:|---------|--------------------|:-------:|
| 924 | 937 | D | d01-greet   | Approved | 0 |
| 925 | 941 | D | d02-add     | Approved | 0 |
| 926 | 939 | D | d03-upper   | Approved | 0 |
| 927 | 943 | D | d04-reverse | Approved | 0 |
| 928 | 938 | D | d05-repeat  | Approved | 0 |
| 929 | 940 | D | d06-clamp   | Approved | 0 |
| 930 | 942 | D | d07-slugify | Approved | 0 |
| 931 | 946 | D | d08-iseven  | Approved | 0 |
| 932 | 945 | D | d09-wc      | Approved | 0 |
| 933 | 944 | D | d10-trim    | Approved | 0 |
| 934 | 948 | B | b01-parsekv | **Changes requested** | 2 |
| 935 | 947 | B | b02-semver  | Approved | 0 |
| 936 | 949 | B | b03-dedup   | Approved | 0 |

### 3.2 Metrics vs baseline / acceptance band

| Metric | Opus baseline (§3) | Sonnet pilot | Δ | Band / kill | Verdict |
|---|---|---|---|---|---|
| First-pass approval | 94% (16/17) | **92.3% (12/13)** | −1.7 pts | drop < 10 pt; kill < 75% | ✅ PASS |
| Rework (commits-after-eval\*) | 0.059/PR (1/17) | 0.077/PR (1/13) | +0.018/PR | rise < 0.3/PR | ✅ PASS |
| Eval re-runs | — | 0/13 = 0 | — | kill > 0.5/PR | ✅ PASS |
| PATH-D escalation | ~0 | 0 | 0 | not elevated | ✅ PASS |
| Post-merge regressions | 0 | 0 (structurally impossible) | 0 | zero | ✅ PASS |
| Cost / execute | $0.896 (Opus, this traffic) | **$0.179 (Sonnet)** | **−80.0%** | — | strong lever |

\* Evaluate-don't-merge makes no actual fix commits (we STOP at the verdict); the rework analog is the
count of non-Approved verdicts that would require a fix commit before merge = 1 (#934).

### 3.3 The one miss — why it strengthens the case (#934 / `kv_get`)

Sonnet's `kv_get` used the literal-space glob `[! ]` instead of `[![:space:]]`, so **tab-indented
comment lines leak into the keyspace** (`\t#SECRET=…` not skipped) and **tab-padded `K\t=\tv` fails to
trim**. Sonnet's own test under-covered (space-only whitespace), so it went green — but the independent
Opus pr-evaluator **constructed adversarial tab cases, reproduced both defects, and returned
`Changes requested` pre-merge.** This is precisely the tier-differentiating judgment gap (cf. the lone
Opus-baseline miss #757) and a **live demonstration that the evaluate-on-Opus backstop catches a Sonnet
execute regression before it can ship.** The ~8% defect rate (1/13) is real → the backstop is
load-bearing and must remain Opus, always.

### 3.4 Cost delta

Priced over the 13 Sonnet execute records (deduped on `agent_id`; resolved model id
`claude-sonnet-4-6` captured from transcripts — measurement substrate validated end-to-end):

- Token mix: cache_read **3.57M**, cache_creation **239k**, output **24k**, input **0.3k** — cache-dominated.
- **@Sonnet: $2.33 total / $0.179 per execute.**
- **@Opus (same tokens, counterfactual): $11.64 total / $0.896 per execute.**
- **Reduction: 80.0%** (the invariant price ratio).

The pilot fixtures are tiny, so the absolute per-execute $ is far below the §1-corrected real-Opus
baseline of **$11.68/execute** — but the **ratio** is the lever, and it reproduces exactly. Note: the
*eligible low-blast lane's own* dollar savings are thin; the expensive executes are the high-blast
B/C the gate excludes. **The pilot's value is de-risking the eligible lane, not the subset's direct
savings.**

## 4. Decision & scope

**WIDEN (staged).** All acceptance-band conditions hold and no kill condition tripped.

- **Enable Sonnet execute for the eligible §4 lane** (PATH D + low-blast single-module PATH B) via the
  host flag.
- **Opus pr-eval stays the mandatory, non-tier-dropped backstop** — the property that makes this safe.
- **Ship the gate default-off;** production opt-in is the operator setting the gitignored host flag.
- **Do NOT** widen to high-blast B or PATH C — distinct, higher-stakes; needs its own pilot.
- **Kill switch** is unsetting the flag (instant revert to Opus, zero code change); trip it on any
  §5 kill condition.

## 5. Infra delivered

1. **Price vars (#770)** — Sonnet/Haiku `PIPELINE_PRICE_*` keys (host `pipeline.config`); example
   already seeded; verified by `tests/test-tokenomics-pricing-config.sh`.
2. **Measurement substrate** — forward/retroactive **dedup on `agent_id`** (#880, `cost-latency-report.sh`)
   and **resolved-model-id capture** (`capture-agent-costs.sh` transcript-summing) were **already
   landed**; verified green (`tests/test-cost-dedup-agent-id.sh`) and validated end-to-end here.
3. **Routing gate (net-new, PR #951)** — `PIPELINE_PATH_{B,D}_MODEL_EXECUTE`, **default empty = inherit
   Opus = byte-for-byte current behavior**; conditional `model=` at the fullsend execute dispatch;
   pr-eval **never** gated; documented commented-out in `pipeline.config.example`; regression guard
   `tests/test-path-model-execute-routing.sh` (9/9).

## 6. Methodology caveats

- **n = 13** (small, like the n=17 baseline). 10/13 are NOOP helpers — the judgment signal concentrates
  in the 3 realistic B fixtures, and that is exactly where the miss landed.
- Pilot pr-evals are **fixture-scoped adversarial evals** (same verdict vocabulary + rigor as
  `evaluate-issue-pr`), not full-suite evaluator runs — comparable on first-pass approval, the primary
  metric, but not identical machinery.
- Throwaway sandbox; everything torn down. Evidence PRs #937–#949 are closed/unmerged.

## 7. Further testing (open questions)

Tracked as action items on **#950**:

1. **Live opt-in window** — flip the host flag on real eligible traffic (not throwaway fixtures) for a
   bounded period and re-measure the same metrics; this is the n-and-realism upgrade the sandbox can't give.
2. **Widening past the low-blast gate** — a separate, higher-stakes pilot for high-blast multi-module
   PATH B and PATH C before any tier-drop there.
3. **pr-eval-on-Sonnet** — a distinct experiment; the backstop must be validated independently before its
   tier is ever dropped.
4. **Haiku floor** — whether the cheapest tier is viable for the most trivial PATH-D shapes.
5. **Full-evaluator parity check** — run a subset through the real `evaluate-issue-pr` to confirm the
   fixture-scoped eval didn't over- or under-approve relative to production machinery.

## Appendix — provenance

- Sandbox: `experiment/868-sonnet-pilot` (deleted at teardown).
- Fixtures #924–#936; evaluated sandbox PRs #937–#949 (closed, unmerged).
- Decision issue #950; routing-gate PR #951.
