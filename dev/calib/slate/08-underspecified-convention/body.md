## Context

People keep scraping `calibctl list --status all` into spreadsheets. The `list`
table is built for a terminal — fixed-width columns, a `#` in front of the id —
so every scraper is a fragile pile of `cut` and `sed`, and none of them agree
with each other.

Give them a proper export instead.

## Scope

Add an `export` command:

```
bash bin/calibctl export > tasks.csv
```

- `calibctl export` writes every task in the ledger — open and done alike — to
  stdout as CSV
- it takes no options for now
- add it to the `help` text

## Affected areas

- `bin/calibctl` — dispatch, the `export` command, `help` text
- `tests/case-export.sh` — new test case file for the new command

The suite discovers `tests/case-*.sh` by glob, so a new file is all it takes;
there is no registry to update.

## Notes

Out of scope for this issue: importing CSV, filtering the export, and any
other output format.
