# create-issues path hint — design (resolves #758)

**Date:** 2026-06-01
**Issue:** #758 — brainstorm(create-classify): path hint from create-issues vs full create/classify merge
**Epic:** #760 — converge issue-creation + classification
**Unblocks:** #759 — make create-issues path-aware (emit a path hint)

## Decision

**Hint, not merge.** `create-issues` may emit an **advisory** path hint at filing time;
`classify-issue` remains the **universal, authoritative** path-deriver. This brainstorm
decides the *shape* so #759 can be built. We did **not** decide a create/classify merge,
so classify's role is unchanged (consistent with #760's "Out of scope" note).

### Why not merge

`classify-issue` is the universal path-authority — it runs on **every** issue, including
those filed outside `create-issues` (GitHub UI, bug template, outsider-suggested), and it
re-derives **fresh at dispatch** (freshness check vs issue `updatedAt`). A filing-time
guess folded into `create-issues` would (a) miss every externally-filed issue and (b) go
stale if the body is edited before execution. `create-issues` only sees what it creates.

## Two-tier marker model

| Marker | Emitter | classify treatment | Status |
|--------|---------|--------------------|--------|
| `<!-- pipeline:path=D -->` | create-issues (existing D backstop) / author | **Authoritative** — short-circuits the rule table (classify step 3c) | **Unchanged** |
| `<!-- pipeline:path-hint=A\|B\|C -->` | create-issues (new, #759) | **Advisory prior** — feeds classify step-4 score table, overridable | **New** |

### Rationale — the split tracks what classify can self-derive

- **D — authoritative.** classify *cannot* reliably self-derive D. Its only D-detection
  signal is the weak Blast-radius B→D prior (`fix(` + ≤2 non-test source files in a single
  module + no high-uncertainty signal), explicitly "a strong prior… never an override"
  (medium confidence), and it only fires for `fix(` work with a parseable `## Affected
  areas`. The skill states plainly that phrase heuristics "will not reliably flip a
  structured body to D" — the marker compensates by carrying author structural knowledge
  (e.g. "same shape as merged PR #X") that classify can't infer from prose. So D's marker
  stays authoritative; demoting it would regress D-routing.
- **A / B / C — advisory.** classify self-derives these well: A (`docs-only`) from file
  extensions / paths, B as the default, C (`multi-task`) from multiple-subsystem / rollout
  signals. A hint adds a prior but is not needed for correctness, so it never overrides.

**Invariant:** advisory hint vocabulary = `{A, B, C}` (every path classify can self-derive);
authoritative marker = `{D}` (the one it can't). A is included for vocabulary symmetry and
to avoid an unexplained gap, even though an A hint rarely changes classify's outcome
(docs-only is the most reliably auto-detected path).

## Hint semantics

- **Distinct syntax.** `path-hint=` (advisory) is deliberately different from `path=`
  (authoritative) so the two can never be confused. Letters: `A`, `B`, `C` only — `D` has
  its own authoritative `path=D` route and is never expressed as a hint.
- **Advisory only.** classify reads the hint as **one prior among many** in step 4's
  scoring. An explicit path label (step 4 row 1) and the authoritative `pipeline:path=D`
  marker (step 3c) both still outrank it. The hint never short-circuits the rule table.
- **Stale handling: none.** classify always re-reads the current body at dispatch; the
  advisory semantics *are* the staleness defense. No timestamps, no freshness check, no
  body mutation. When classify's verdict differs from the hint, it **records the override
  rationale in the `## Classification` comment** (e.g. "create-issues hinted B; classified
  C — multiple subsystems in Affected areas") for transparency.

## Where the hint is written

- `create-issues/SKILL.md` step 3 (scope-check). When the combined issue's discussion
  gives a clear A/B/C signal, append the advisory marker at filing time.
- **Path-agnostic by default.** Emit a hint only on a clear signal; silence = no hint =
  classify decides cold. This preserves create-issues' current default behavior — the
  motivating ambiguity (#760: a combined clustered unit that could be B or C) is where the
  hint earns its keep.

## Boundaries (unchanged)

- classify stays the **universal** authority — externally-filed issues that create-issues
  never sees are classified exactly as today.
- create-issues remains read-only / no-label; it writes a body marker, never a label.
- No change to classify's role beyond reading one new advisory prior.

## What #759 must build

1. **create-issues** (`skills/create-issues/SKILL.md` step 3): advisory marker format
   (`<!-- pipeline:path-hint=A|B|C -->`) + signal-gated emission logic. Path-agnostic
   default preserved.
2. **classify-issue** (`skills/classify-issue/SKILL.md` step 4): parse `path-hint`, fold
   into the score table as a prior, surface override rationale in the `## Classification`
   comment when the verdict differs.
3. **Tests:**
   - hint is parsed as a prior, never an override;
   - explicit label and `pipeline:path=D` still win over a conflicting hint;
   - override-with-rationale path (hint says X, classify decides Y, comment explains why);
   - `path-hint=D` is rejected / ignored (D is authoritative-only);
   - silence (no hint) leaves classify behavior unchanged.

## Out of scope

- Changing classify's role as the universal path-authority (no merge).
- Building stronger D-detection scaffolding into classify (would be the precondition for a
  single-tier all-advisory model; not pursued here).
- Measurement of impact — that is #757 (gates whether #759 ships), separate from this shape
  decision.
