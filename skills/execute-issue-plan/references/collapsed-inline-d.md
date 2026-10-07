# Collapsed inline D contract

`skills/execute-issue-plan/SKILL.md` `### Collapsed inline D contract` points here.
Read it when the issue carries `quick-fix` — PATH D, invocation mode 3 (the
collapsed inline `tdd-implementer` that runs classify + plan + execute in one
session). On every other path this file is irrelevant.

When dispatched as the collapsed PATH D agent (mode 3), this agent is the PRODUCER of the classify + plan stages, not a downstream consumer of upstream-posted comments. It RUNS classify and plan inline FIRST — emitting the two stage records as inline side-effect checkpoints (see below) — and THEN carries that context straight into execution. So this agent **carries the classify+plan context forward** within its own single session and **does NOT re-read the plan comment** from GitHub: there is no separate plan-comment fetch (step 1's `gh issue view ... ## Implementation Plan` read is skipped on PATH D, and because the plan is already in-context the STOP-on-empty guard never fires). The two inline side-effect **checkpoints**, byte-shaped exactly as the standalone classify/plan stages would have posted them, are:

- a `## Classification` checkpoint carrying the recommended **path label** (`quick-fix` / PATH D);
- a `## Implementation Plan` checkpoint with the `plan-pending` marker.

**Escalation backstop.** The collapsed D agent runs inside D's small **envelope** (the `## Affected areas` prediction: one file, ≤ ~20 LOC, single precedent). If mid-run it discovers the change **exceeds D's envelope** — it touches more files than `## Affected areas` predicted, needs a real plan, or hits unforeseen coupling — it does NOT force a too-large change through the D lane. It **aborts up** / **escalates** to a **full PATH B run**: real planning plus a full execute session (per #748 PATH B execute now runs as an inline `Agent`, not a spawned `claude -p` worker). This is what makes a wrong B→D down-route cheap and recoverable — the backstop reverses it rather than shipping a too-large diff through D.
