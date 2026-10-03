# Scoped halt-and-report (closure sourced from `--emit-edges`)

If a wave-N PR fails to merge, fullsend does **not** blindly halt every later wave. First discriminate transient from hard blocks:

- **Transient (defer, do NOT halt):** a wave-N PR that lands `block-ci` or `pending` is NOT an immediate halt — let the existing **Step 6b** CI-fix loop run to terminal. If it resolves green, proceed. If it exhausts the red-retry budget (`red-budget-exhausted`, PR is `human`-flagged), only then treat it as a hard block.
- **Hard block (triggers a scoped halt):** `block-mergestate`, `block-mergeable`, `block-verdict`, `block-capability-refused`, `block-base-mismatch`, `block-cage-tests-diff`, or a CI failure whose retry budget is exhausted — unlike `block-ci`, a cage-tests diff never self-clears on retry and always needs an operator. When such a block leaves a wave-N issue's PR unmerged, compute its **dependency closure** and halt only that closure.

**Closure computation — from the `--emit-edges` edge map, NOT the human-readable `Wave N:` lines.** Seed the closure with `{blocked issue}`. Then walk the parsed `EDGE` map to a fixpoint: add any issue whose `blockers=` csv contains a current closure member, and add any issue whose `files=` csv shares a path with any closure member; repeat **transitively** until no new issue is added. The closure is computed from the **emitted edges**, **not** from the human-readable `Wave N:` lines — because multi-issue waves print **no per-issue reason** strings, so a grouped issue's blocker would be invisible there; `--emit-edges` emits every issue's edges regardless of wave grouping, which is why the closure is reliable even for multi-issue waves.

Then:

- Later-wave issues **in** the closure are reported `Skipped (depends on blocked #<N>)`.
- **Independent later-wave issues that are NOT in the closure MAY still proceed** off the current merged base — honoring the issue body's "don't over-serialize" constraint.
- Earlier-wave and this-wave issues that already merged are **preserved** — a scoped halt never rolls back merged work.

The Step 8 report names the issue that hard-blocked, its `block-*` reason token, and which downstream issues were skipped (with the dependency chain read from the edge map), so the operator can merge the blocker by hand and re-run `/pipeline:fullsend` for the remainder.
