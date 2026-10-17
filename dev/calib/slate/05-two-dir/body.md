## Context

`calibctl report` prints raw counts and leaves the arithmetic to the reader:

```
Task report
===========
open       3
done       1
total      4
```

Three gaps have piled up around that command:

- Everyone who uses the report is computing done ÷ total in their head. It is
  the one number people actually quote in a standup, and it is the one number
  the report does not print.
- Scripts that want the counts have to scrape the human-readable text, which
  breaks the moment its alignment changes. There is no machine-readable form.
- The docs describe neither. `docs/architecture.md` enumerates the report's
  contents line by line, and `docs/usage.md` shows only the plain invocation.

## Scope

The three deliverables are independent — none reads another's output, and they
may land in any order. Each one lives in its own directory and carries its own
test file.

1. **Completion rate in `lib/report.sh`.** In `report_render`, print a line
   `completion  NN%` directly below `total`, using the same label/value
   alignment as the counts above it. `NN` is done ÷ total as a whole-number
   percentage, rounded to nearest. An empty ledger prints `completion   0%`
   rather than dividing by zero. Every existing line stays exactly as it is —
   the counts, the `by priority` block, and the `oldest open` line. Add
   assertions to `tests/case-report.sh` for an empty ledger, a partial ledger
   and a fully-completed ledger.
2. **A JSON form in `bin/calibctl`.** In `cmd_report`, accept `--json`:
   `calibctl report --json` prints `{"open":N,"done":N,"total":N}` with the keys
   in exactly that order, built with `printf`. Take the counts from the existing
   `report__count_status` helpers (which read through `store_rows`), so nothing
   under `lib/` changes for this item. The JSON carries the three counts only.
   An unrecognised `report` option exits 2 through `die_usage`, like the other
   commands. The help text for the command becomes `report [--json]`. Plain
   `calibctl report` output is unchanged. Add a new `tests/case-report-json.sh`
   covering an empty ledger, a partial ledger and the exit-2 case.
3. **Documentation in `docs/`.** In `docs/architecture.md`, extend the "The
   report" section so its list of what the report prints includes the
   completion rate (done ÷ total, rounded, `0%` on an empty ledger) and
   describes the `--json` form. In `docs/usage.md`, extend the "Reporting"
   section with a `calibctl report --json` example.

## Affected areas

Six files across three directories, two per deliverable:

- Deliverable 1: `lib/report.sh`, `tests/case-report.sh`
- Deliverable 2: `bin/calibctl`, `tests/case-report-json.sh`
- Deliverable 3: `docs/architecture.md`, `docs/usage.md`

## Notes

Keep the arithmetic in bash — no `bc`, no `python`, no `jq`. The tool has no
dependencies beyond coreutils today and that is worth preserving.

`calibctl list` and the store are untouched by this issue; every number the
report prints is read through `store_rows`, so neither the percentage nor the
JSON can disagree with `list` as long as they are derived the same way.
