# Collapsed inline D contract

Read when the issue carries `quick-fix` (PATH D, invocation mode 3: one inline `tdd-implementer` session runs classify + plan + execute).

The collapsed agent is CONSUME-or-PRODUCE:

- **CONSUME** — a trusted `## Classification` and/or `## Implementation Plan` comment is already posted (`plan-issue` classifies inline and posts both). Use them when they exist: read them via the Step 1 fetch and do NOT re-post the checkpoints.
- **PRODUCE** — only when absent (pre-labelled `quick-fix` or a `<!-- pipeline:path=D -->` body marker). Run classify (`skills/plan-issue/references/classification.md`) and plan inline FIRST, posting the two checkpoints below, then execute. The agent **carries the classify+plan context forward** in its own session and **does NOT re-read the plan comment**: Step 1's fetch is skipped.

PRODUCE-mode **checkpoints**, shaped exactly as the standalone stages post them:

- a `## Classification` checkpoint carrying the recommended **path label** (`quick-fix` / PATH D);
- a `## Implementation Plan` checkpoint with the `plan-pending` marker.

**Escalation backstop.** D's envelope is the `## Affected areas` prediction: one file, ≤ ~20 LOC, single precedent. If the change **exceeds D's envelope** — more files, a real plan needed, unforeseen coupling — do not force it through: **abort up** and escalate to a **full PATH B run**: real planning plus a full execute session (an inline `Agent`, not a spawned `claude -p` worker).
