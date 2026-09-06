## Context

`calibctl report` prints raw counts and leaves the arithmetic to the reader:

```
Task report
===========
open       3
done       1
total      4
```

Everyone who uses the report is computing done ÷ total in their head. It is the
one number people actually quote in a standup, and it is the one number the
report does not print.

`docs/architecture.md` enumerates the report's contents line by line ("the
`open`, `done` and `total` counts", "a `by priority` breakdown", "the oldest
open task"). That list is the contract for this renderer, so it has to be
extended in the same change — otherwise the next reader cannot tell whether the
new line is intentional or a stray debug print.

## Scope

Add a completion rate to `report_render` and document it.

Output contract:

- a line `completion  NN%` directly below `total`, using the same label/value
  alignment as the counts above it
- `NN` is `done / total` as a whole-number percentage, rounded to nearest
- an empty ledger reports `completion   0%` rather than dividing by zero
- every existing line stays exactly as it is — the counts, the `by priority`
  block, and the `oldest open` line

Then update the report section of `docs/architecture.md` so its list of what
`report_render` prints includes the completion rate and says how it is derived.

## Affected areas

Two disjoint areas, both required:

- `lib/report.sh` — `report_render`
- `docs/architecture.md` — the "The report" section
- `tests/case-report.sh` — assertions for the new line (empty ledger, a partial
  ledger, a fully-completed ledger)

## Notes

Keep the arithmetic in bash — no `bc`, no `python`. The renderer has no
dependencies beyond coreutils today and that is worth preserving.

`calibctl list` and the store are untouched by this issue; the report reads
everything through `store_rows`, so the new number cannot disagree with `list`
as long as it is derived the same way.
