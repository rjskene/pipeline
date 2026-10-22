## Context

`calibctl add --tag` has stored tags since 0.3, but nothing reads them back:
there is no way to ask for "everything tagged `urgent`" short of opening
`.calib/tasks.tsv` by hand. Tags are only useful if you can filter on them.

## Scope

Add a `--tag <t>` option to `calibctl list`:

```
bash bin/calibctl list --tag urgent
bash bin/calibctl list --tag urgent --priority high
bash bin/calibctl list --tag urgent --status all
```

- a task matches when `<t>` is exactly one of its tags — tags are stored as a
  comma-separated list, so `--tag urgent` matches a task tagged `ops,urgent`
  but not one tagged `not-urgent`
- `--tag` composes with `--status` and `--priority`: all given filters must
  match
- the output is the usual `list` rows; no match prints `no matching tasks` and
  exits 1, as `list` already does
- mention `--tag` in the `help` text

The row selection belongs with the existing filters in `store_rows`
(`lib/store.sh`); `bin/calibctl` parses the option and passes it through.

## Affected areas

- `bin/calibctl` — `list` option parsing, `help` text
- `lib/store.sh` — `store_rows`
- `tests/case-list-tag.sh` — new test case file for the filter

The suite discovers `tests/case-*.sh` by glob, so a new file is all it takes;
there is no registry to update.

## Notes

Out of scope for this issue: filtering on several tags at once, tag
wildcards, and a `--tag` option on any command other than `list`.
