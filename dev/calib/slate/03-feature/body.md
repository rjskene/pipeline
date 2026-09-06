## Context

Once a ledger passes a few dozen entries there is no way to find a task
without piping `list --status all` through `grep` by hand. Every user ends up
writing the same one-liner, and the ids get lost because `grep` mangles the
column alignment when the terminal is narrow.

`list` already knows how to filter by status and priority; text is the obvious
third axis.

## Scope

Add a `search` command:

```
bash bin/calibctl search release
#1    open  high  write the release notes
```

Required behaviour:

- `calibctl search <term>` prints matching tasks in exactly the same row format
  as `list` (`#id`, status, priority, title)
- the match is a case-insensitive substring test against the **title** and the
  **tags**
- `search` looks at every task regardless of status — completed tasks are
  included (unlike `list`, which defaults to open)
- no match: print `no matching tasks` and exit 1, matching `list`
- no term: exit 2 with a usage error, like every other malformed invocation

The row-formatting helper already exists in `bin/calibctl`; the row selection
belongs next to the other query helpers in `lib/store.sh`.

## Affected areas

- `bin/calibctl` — dispatch, argument handling, `help` text
- `lib/store.sh` — the query helper
- `tests/case-search.sh` — new test case file for the new command

The suite discovers `tests/case-*.sh` by glob, so a new file is all it takes;
there is no registry to update.

## Notes

Out of scope for this issue: regular-expression search, `--status` /
`--priority` flags on `search`, and searching the created-at timestamp. Keep
the first cut to a plain substring so the behaviour is easy to describe.
