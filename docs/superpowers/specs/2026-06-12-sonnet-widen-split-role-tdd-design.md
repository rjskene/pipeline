# Sonnet-on-B Widening + Split-Role TDD — Two-Phase Design

**Issue:** #881 (brainstorm → actionable on approval of this spec)
**Date:** 2026-06-12
**Status:** Approved design, pending implementation plan
**Relates:** #953 (testing program — this is its "widen past the low-blast
gate" item), #950/#951/#952 (the eligibility gate this widens), #868 (the
investigation), epic #450 Axis B (cost posture).

## Problem

`PIPELINE_PATH_B_MODEL_EXECUTE=sonnet` (#953 live opt-in) routes Sonnet only
to PATH B issues that pass `path-b-execute-eligible.sh` (low-blast:
single-module, ≤2 files). Live window evidence (below) shows that gate
filters out **essentially all real B traffic** — the Sonnet-B lane is empty
(n=0) while every actual B execute runs Opus at $10–60/issue. The cost lever
(#868: ~80%) sits on the high-blast B population the gate excludes. #881
asked for the widening pilot; this spec decides its mechanism.

A second, independent goal (operator-stated): **structural TDD compliance.**
Single-agent TDD is honor-system — nothing proves the test preceded the
implementation. Splitting test-authorship from implementation makes
test-first a property of the commit graph instead of a behavior.

## Evidence

**Dogfood window (this repo, #953 live since ~2026-06-05):**

- B-on-Sonnet **n=0** — every live B issue (e.g. #1016, #1017) failed the
  low-blast gate and executed on Opus. The "safe subset" lane carries no
  traffic, confirming #881's prediction.
- D-on-Sonnet n=4 (#995, #996, #1006 + 1) — all first-pass approved/merged,
  ~$0.6–2/issue.
- B-on-Opus ≈ 13 executes at **$10–60/issue**, cache-dominated (cache_read +
  cache_creation ≫ output cost).

**work-orchestrator all-Sonnet session (orchDO, 017ad61a, 2026-06-08):**
one deliberate full-pipeline pass with plan, plan-eval, execute, AND pr-eval
all pinned `model=sonnet`:

| Slate | Paths | Outcome |
|---|---|---|
| #335 #338 #340 #346 #347 #352 | 6× PATH B (`feat(`, real features) | merged, PR-eval first-pass Approved |
| #336 #342 #345 | 3× PATH C (multi-task) | merged, first-pass Approved |
| #339 | 1× PATH D | merged |

- 10/10 merged, zero PR-eval re-runs. Plan-eval Revise→Approved loops fired
  on #340 (×1) and #347 (×2) — Sonnet plan-eval caught Sonnet plan defects
  upstream; the machinery, not the tier, carried quality.
- Post-merge (4-day window): one plausible defect candidate (#518, mailroom
  `.msg SaveAs` COM edge case on forwarded mail, likely from #342) — an
  external-API edge of the kind any tier misses; plus #537 (evaluator
  committed a screenshot artifact — process litter, not impl quality).
- Caveats: Sonnet judged Sonnet (weaker backstop than this design retains);
  n=10; Python app repo vs this meta-repo's bash/skill-prose character.

**Prior:** #868 sandbox pilot n=13: 92.3% first-pass vs 94% Opus baseline,
−80% execute cost, the one Sonnet defect caught pre-merge by Opus eval.

**Reading:** approved-plan + TDD + eval gates squeeze judgment out of the
execute stage by construction; execute is the most commoditized stage. Tier
still shows in mid-impl surprises, edge-case blindness, and **test
integrity** — the one residue plan quality cannot fix, which is what Phase 2
closes.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| W1 | Phase 1 — widen | High-blast PATH B routes Sonnet on execute via `PIPELINE_PATH_B_ELIGIBLE_SCOPE="all"` (new knob; default `low-blast` = today's behavior). `path-b-execute-eligible.sh` itself is UNCHANGED — its verdict becomes advisory under `all` scope; the scope var is read at fullsend's dispatch site. Kill switch = unset the var (instant revert to low-blast). |
| W2 | Permanent Opus carve-outs | Regardless of scope: high-uncertainty vocabulary (`concurrency`/`race`/`lock`/`deadlock`/`security`/`auth`/`crypto`/`migration`/`data-loss` — same list as classify's carve-out) and `needs-browser` (#960 precedent) execute on Opus. These never widen. |
| W3 | pr-eval tier | **Opus, always, both phases.** The independent backstop is the property that makes execute-downsampling safe (#953's own framing). pr-eval-on-Sonnet remains a separate #953 experiment, out of scope here. |
| W4 | Metrics + kill bands | Mirror #953: first-pass approval <75%, eval re-runs >0.5/PR, or any tier-traceable post-merge defect → revert the scope var. Measurement substrate: `agent-costs.jsonl` already records model per execute; no new capture needed. |
| W5 | Phase 2 — split-role TDD | Opus authors the failing suite; Sonnet implements to green. Triggered by: (a) Phase-1 kill condition fires but the cost goal stands, OR (b) operator adoption for structural TDD compliance independent of cost. Mechanics in `## Split-role TDD (Phase 2)`. |
| W6 | Granularity (Phase 2) | **Per-issue batched** — one Opus red commit, then Sonnet greens test-by-test with per-test commits. Interleaved/hybrid documented as fallback if batched suites fail live; no knob until the signal appears. |
| W7 | Enforcement (Phase 2) | **Eval-time git invariant, script-decides:** `scripts/split-role-gate.sh` asserts the red commit exists and `git diff <red-sha>..HEAD --diff-filter=MD -- <test paths>` is empty (locked tests never modified/deleted; additions allowed). Write-time hook block is defense-in-depth only — Bash-level writes leak (#964/#965 class), the git invariant does not. Hook denials in the tool-use log = measured cheat-attempt rate. |
| W8 | Plan/plan-eval tiers | Unchanged (Opus). orchDO hints Sonnet-plan + iterate works; that is a separate experiment, not bundled here. |

## Phase 1 — widen (zero new machinery)

- `pipeline.config.example`: add commented `#PIPELINE_PATH_B_ELIGIBLE_SCOPE="low-blast"`
  with the `all` widening documented (satisfies `check-config-drift.sh`).
- `skills/fullsend/SKILL.md` execute-dispatch prose: when scope=`all` and the
  issue is PATH B without a W2 carve-out, pin `model=sonnet` even on a
  high-blast eligibility verdict. The eligibility line is still relayed in
  the run log (audit trail of what the gate *would* have done).
- Dogfood rollout: set `PIPELINE_PATH_B_ELIGIBLE_SCOPE="all"` in the live
  (gitignored) `pipeline.config`; run ≥10 high-blast B issues through the
  normal lifecycle; score against W4 bands; confirm/kill.

## Split-role TDD (Phase 2)

Dispatch shape (batched per W6), within the existing PATH B worktree flow:

1. **Opus test-author** agent: reads the approved plan, authors the complete
   failing suite, runs each test and verifies it fails **for the right
   reason** (assertion, not import/scaffold error), commits once with the
   `[split-role-red]` marker in the commit subject. That commit's SHA is the
   deterministic anchor.
2. **Sonnet implementer** (tdd-implementer discipline): greens the suite
   test-by-test, per-test commits. Test writes are **additive-only** — may
   add new tests, must never modify/delete locked ones. **Escalation
   valve:** if it concludes a locked test is wrong, it STOPs and reports
   (same shape as the PATH D escalation backstop); the orchestrator returns
   the test to Opus to adjudicate. No silent contortion.
3. **Eval:** existing Opus pr-eval, plus `split-role-gate.sh` (W7) emitting
   one decision line the eval prose obeys (the `auto-merge-gate.sh`
   pattern).

Commit-graph contract: `[split-role-red]` (Opus) strictly precedes all green
commits (Sonnet) — TDD compliance becomes auditable structure, with the W7
invariant guarding the suite's integrity in between. The W7 diff-filter
locks **every** test file that exists at the red SHA (pre-existing ones
included), so any legitimate update to an existing test (golden-file
refresh, changed contract) must be part of the Opus red commit itself; a
mid-impl need to touch one is an escalation-valve case, never a Sonnet edit.

**Honesty bounds (recorded, accepted):**
- Sonnet's *additive* tests are self-authored — honor-system returns for
  that slice. The locked floor is structural; new-increment coverage is not.
- The lock is anti-drift, not adversarial-grade at write time; the
  eval-time git invariant is the actual gate.
- Split-role costs more than plain all-Sonnet (extra Opus phase + second
  agent boot). Estimated ~50% saving vs all-Opus B (cache-dominated costs;
  Sonnet cache rates 5× cheaper) vs ~80% for plain widening — the premium
  buys the test-integrity floor.

**Graduation (start-A → goal-B):** start as the lane for whatever Phase 1
excludes or degrades; promote toward default-for-B after ≥10 split-role
issues with first-pass approval ≥85%, zero unrecovered lock violations, and
cost ≤60% of the Opus baseline. W2 carve-outs stay Opus-execute even at
goal-B.

## Testing

- Phase 1: config-drift coverage for the new var (example-file entry);
  fullsend prose change covered by the existing skill-contract test
  substrate; `tests/test-path-b-execute-eligible.sh` untouched (script
  unchanged).
- Phase 2: `tests/test-split-role-gate.sh` golden tests — red-SHA missing /
  modified locked test / deleted locked test / additive-only pass / suite
  state; token-leak N/A (no credentials surface).

## Alternatives considered

- **Literal tests embedded in plans + eval fidelity check** — cheaper (no
  extra dispatch), weaker: no authored-and-verified red commit; transcription
  drift between plan text and committed tests is exactly the honor-system
  gap again. Rejected as the compliance mechanism; plans already carry test
  specs as input to Phase 2's test-author.
- **Opus mid-flight diff review** — cheaper Opus involvement but no
  structural test-first guarantee; redundant with Opus pr-eval.
- **Interleaved/hybrid granularity** — see W6; fallback, not default.

## Out of scope

- pr-eval-on-Sonnet and the Haiku floor (#953 items, separate experiments).
- PATH C widening — orchDO's C n=3 first-pass evidence is suggestive but C
  has its own per-leaf dispatch machinery; file separately when Phase 1
  confirms.
- Plan/plan-eval tier changes (W8).
- Mid-impl model escalation (Sonnet hands a stuck task to Opus) — the
  existing PATH D→B escalation precedent could extend here; deferred.

## Issue hygiene

On spec approval:

- Retitle #881 → `feat(dynamic-effort): widen Sonnet to high-blast PATH B
  (phase 1) + split-role TDD lane (phase 2)`; replace body with the
  actionable two-phase shape referencing this spec; drop `brainstorm`.
- Cross-comment on #953: item "live opt-in window" → B-lane n=0 finding
  (the low-blast gate filters all real B traffic — the window cannot
  confirm/kill without this widening); item "widen past the low-blast gate"
  → mechanism decided here.
- #737 already closed (2026-06-12) with the routing-gate validation that
  feeds this spec's premise.

## Related

- #881 — the brainstorm this spec actions. #953 — the testing program it
  advances. #950/#951/#952 — eligibility gate + analysis substrate.
- `docs/analysis/model-downsampling.md` — #868 data.
- `scripts/auto-merge-gate.sh` — the script-decides pattern W7 follows.
- orchDO evidence: work-orchestrator session `017ad61a` (2026-06-08).
