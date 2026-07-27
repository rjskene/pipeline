# Stage-model pins — explicit per-stage model routing under a Fable-ceiling session

**Date:** 2026-07-27
**Status:** Draft — pending operator review
**Context:** Fable 5 / Opus 5 / Sonnet 5 all available. Operator session model moves to `fable` (`/model fable`). Today's model economy silently assumed the session model was the quality ceiling *and* the cost floor for every dispatched stage.

## Problem

Every quality-critical dispatch in the pipeline **inherits** the session model (passes no `model=` param):

- `plan-eval` and `pr-eval` have **zero explicit pins**. The load-bearing W3 property ("pr-eval always Opus") is an *inheritance side-effect*, not a pin — documented in 8+ places (`resolve-execute-dispatch.sh` header, fullsend Step 6, evaluate-issue-pr 2b) as "inherits the orchestrator's Opus."
- The execute resolver's protective carve-outs (W2 high-uncertainty, needs-browser) resolve to `MODEL=inherit` — i.e. "the strong safe model" *by assumption*.
- PATH C `tdd-implementer` leaves and PATH A execute dispatch with no `model=` at all (no `_MODEL_EXECUTE` knob exists for A/C).

With session = Fable, **every one of those "inherit" sites silently becomes Fable**:

1. **Cost:** Fable is $10/$50 per MTok — exactly 2× Opus 5 ($5/$25). pr-eval alone was 15.5% of window spend; evaluators + carve-outs + C-leaves upshifting to the ceiling doubles the most expensive lanes with no signal (same failure class as #1056's invisible-cost gap).
2. **Reliability:** Fable's cyber/bio safety classifiers can return `stop_reason: refusal` on security-adjacent content, and its documented bug-finding gains *explicitly exclude security-focused analysis*. The pipeline's W2 carve-out selects precisely the security/concurrency/auth issues — so the riskiest PRs would route onto the model most likely to refuse mid-gate. An auto-merge gate that can refuse mid-verdict on exactly the high-uncertainty PRs is a broken gate.
3. **Semantics:** the repo's prose ("inherits Opus") is now simply false.

## Design principles

1. **Explicit pins; `inherit` retired at dispatch sites.** Every dispatched `Agent(...)` carries an explicit `model=`. The session model is reserved for the orchestrator loop itself. "Opus is the downsample we want to make explicit" — the quality floor stops free-riding on the session model.
2. **Gate never below producer.** An evaluator stage must run at a tier ≥ the stage it gates (equal is fine — the evaluator's value is independent context; below is not, because plan approval and PR merge are auto-gates with no human behind them in fullsend).
3. **Fable is reserved for cross-unit meshing.** Its documented edge is long-horizon multi-agent coordination and sustained subagent communication — the orchestrator (free, via `/model`) and PATH C decomposition (leaf-boundary planning across worktrees, where a bad split is the pipeline's most expensive failure mode: N worktrees, N leaves, failed cherry-pick reassembly). Per-unit depth (PATH B plan, evaluators) is Opus 5 territory — a step-change over 4.8 at half Fable's cost, with review that "stays accurate at lower effort."

## Stage-model table (defaults)

| Stage | PATH A | PATH B | PATH C | PATH D | Mechanism |
|---|---|---|---|---|---|
| orchestrator | — | — | — | — | `/model fable` (session; no knob, no dispatch) |
| classify | inherit | inherit | inherit | inherit* | unchanged (see Open item 1) |
| plan | opus | opus | **fable** | inline* | `resolve-stage-model.sh` |
| plan-eval | opus | opus | **fable** | — | `resolve-stage-model.sh` (follows producer tier) |
| execute | opus | sonnet† | opus (leaves) | sonnet† | `resolve-execute-dispatch.sh` (B/D unchanged; A/C new) |
| pr-eval | opus | opus | opus | opus | `resolve-stage-model.sh` — W3 becomes a real pin |

\* PATH D classify+plan+execute run as one collapsed inline dispatch; that single Agent gets the resolved execute model (`sonnet` default, W2→opus), unchanged.
† #1042 Sonnet-on-execute default unchanged, including split-role `red:opus,green:sonnet` and all existing carve-outs.

**Invariant check:** plan-eval follows its path's plan producer (PATH C plan=fable → PATH C plan-eval=fable; else opus). pr-eval (opus) ≥ execute (sonnet/opus) everywhere. No pair violates gate≥producer.

## Carve-outs (all resolve to a NAMED model, never `inherit`)

- **W2 high-uncertainty → `opus`, now including PATH C plan/plan-eval.** For execute this is unchanged in effect (named instead of inherited). For PATH C plan it is a *downgrade* from fable, deliberately: security-vocab issues on Fable risk `stop_reason: refusal` mid-pipeline (cyber classifiers), and Fable's review gains exclude security analysis. Opus is the reliable lane for exactly this work. Same `_high-uncertainty-match.sh` regex, never redefined (#1039).
- **needs-browser → `opus`** (was `MODEL=inherit`). #960 semantics preserved; emission changes from `inherit` to the named model.
- **W3 → structural pin.** pr-eval is pinned `opus` in every configuration and never routed through the execute resolver (existing exit-2 guard stands). The prose "inherits the orchestrator's Opus" is replaced by "pinned opus via PIPELINE_STAGE_MODEL_PR_EVAL" everywhere it appears.

## Config surface (defaults-in-code at the read site, per #1052)

```bash
# --- per-stage model pins (#TBD: Fable-ceiling downsample) ---
# Defaults live at the read site (scripts/resolve-stage-model.sh); uncomment only to override.
#PIPELINE_STAGE_MODEL_PLAN_EVAL=opus     # evaluator floor; PATH C follows its plan model
#PIPELINE_STAGE_MODEL_PR_EVAL=opus       # W3 as an explicit pin — NEVER below execute tier
#PIPELINE_PATH_C_MODEL_PLAN=fable        # cross-unit meshing; W2 carve-out forces opus
#PIPELINE_PATH_A_MODEL_EXECUTE=opus      # docs-only execute; was silent inherit
#PIPELINE_PATH_C_MODEL_EXECUTE=opus      # tdd-implementer leaves; was silent inherit
```

Plus Fable pricing rows (tokenomics currently prices unknown models at Opus rates → under-reports Fable by 2×):

```bash
#PIPELINE_PRICE_CLAUDE_FABLE_5_INPUT=10
#PIPELINE_PRICE_CLAUDE_FABLE_5_OUTPUT=50
#PIPELINE_PRICE_CLAUDE_FABLE_5_CACHE_CREATION=12.50
#PIPELINE_PRICE_CLAUDE_FABLE_5_CACHE_READ=1.00
```

(`cost-latency-report.sh` gains matching baked defaults; the config lines are overrides, same shape as the existing Opus/Sonnet/Haiku blocks.)

## Mechanism

**New single-source resolver: `scripts/resolve-stage-model.sh <issue> <plan|plan-eval|pr-eval>`.** Mirrors `resolve-execute-dispatch.sh` (#1056 lesson: prose drifts, scripts don't). Emits one token per line, always exits 0 in normal operation:

```
ISSUE=<N>
STAGE=<plan|plan-eval|pr-eval>
PATH=<A|B|C|D>
MODEL=<fable|opus|sonnet|haiku>     # ALWAYS named; `inherit` is not a valid emission
REASON=<default-pin|path-c-fable|follows-producer|high-uncertainty|explicit-knob>
```

Routing rules encoded once:
- `pr-eval` → `PIPELINE_STAGE_MODEL_PR_EVAL` (unset ⇒ `opus`). No carve-outs can lower it; an explicit knob value below the resolved execute tier is honored but emits `REASON=explicit-knob` + a stderr WARN (operator override is allowed, silence is not).
- `plan` → PATH C ⇒ `PIPELINE_PATH_C_MODEL_PLAN` (unset ⇒ `fable`); A/B ⇒ `opus`. W2 high-uncertainty (via `_high-uncertainty-match.sh` against title+body+labels) ⇒ `opus` overrides the fable default.
- `plan-eval` → resolve the same issue's `plan` model first; emit `max(plan-model-tier, PIPELINE_STAGE_MODEL_PLAN_EVAL)` so the gate never lands below the producer.

**`resolve-execute-dispatch.sh` changes (minimal):**
- Carve-out branches emit `MODEL=opus` instead of `MODEL=inherit` (W2 already does; needs-browser and `scope-low-blast-gated` switch from `inherit`).
- Accepts `A`/`C` path letters: A ⇒ `PIPELINE_PATH_A_MODEL_EXECUTE` (unset ⇒ opus), C ⇒ `PIPELINE_PATH_C_MODEL_EXECUTE` (unset ⇒ opus) applied to every leaf dispatch. B/D routing byte-identical.
- Read-site rule simplifies: "always pass `model=$MODEL`" (the "pass NO model= when inherit" special case dies).

**Skill read-site updates:** fullsend Step 6 + Step 1b (classify/plan dispatch), evaluate-issue-plan, evaluate-issue-pr dispatch prompts consume the resolver's `MODEL=` verbatim. `--verify-dispatch` (#1056 WARN-level post-check) extends to the new stages.

## Explicitly unchanged

- #1042 Sonnet-on-execute default for B/D; split-role shape `red:opus,green:<model>`; split-role gate.
- Classify dispatch (still inherits; see Open item 1).
- `spawn-claude.sh` legacy transport model threading (dogfood runs inline; follow-up if `--spawn` lane needs the new knobs).
- Campaign mode (inherits fullsend Step 6 by reference — picks the resolver up for free).

## Cost model (window-2026-07-10 shape, directional)

- plan ($133.85/window) mostly PATH B ⇒ stays opus-priced; PATH C was 1/70 issues ⇒ fable premium negligible.
- plan-eval ($98.12) + pr-eval ($147.54): pinned opus — **avoids a ~$245→$490 doubling** that silent fable inheritance would have caused.
- Orchestrator ($337.01, 35.4%): moves to fable ⇒ roughly 2× that line is the *deliberate* spend this design buys — the one place fable's meshing edge applies.

## Open items

1. **Classify pin.** Left inheriting (operator choice: leave cheap stages alone). Under a fable session, classify (~4.8% of spend) roughly doubles. If that shows up in tokenomics, add `PIPELINE_STAGE_MODEL_CLASSIFY=opus` as a one-line follow-up — resolver already has the shape for it.
2. **Fable refusal handling.** If a fable-planned PATH C issue hits `stop_reason: refusal` despite the W2 carve-out (regex miss), the plan Agent fails and fullsend's existing FAILED-line handling applies. Acceptable for v1; a retry-on-opus fallback is a follow-up.
3. **Agent `model` enum.** The Agent tool accepts `sonnet|opus|haiku|fable`. Resolver emits those literals; if a host's tool build lacks `fable`, the dispatch errors loudly (fail-closed) — doctor check as follow-up.

## Test substrate

- `tests/test-resolve-stage-model.sh` — pin defaults, PATH C fable, W2 downgrade-to-opus, follows-producer for plan-eval, explicit-knob WARN, never-emits-inherit.
- Extend `tests/test-resolve-execute-dispatch*.sh` — needs-browser now `MODEL=opus`; A/C acceptance; B/D golden outputs unchanged.
- Config-drift guard: new `#PIPELINE_*` knobs get read-sites in the same PR (ORPHAN check stays green).
- Prose-drift regression: grep-guard that `skills/` no longer contains "inherits the orchestrator's Opus" (the retired assumption).
