## Context

`docs/usage.md` documents a `--all` flag for `calibctl list` that the CLI does
not implement:

```
bash bin/calibctl list --all
calibctl: unknown option for list: --all
```

The "Listing tasks" section also claims that `list` "shows every task in the
ledger" by default. That is wrong twice over: the default is `--status open`,
and completed tasks are included via `--status all`, not `--all`.

New users hit this on their first session — the copy-pasteable example in the
docs errors out.

## Scope

Correct the "Listing tasks" section of `docs/usage.md` so it matches
`bin/calibctl`:

- drop every mention of `--all`
- document `--status open|done|all`
- say plainly that the default is `--status open`, i.e. completed tasks are
  hidden unless you ask for them

The behaviour is correct as implemented — do **not** add a `--all` alias to the
CLI to make the documentation true. This is a documentation correction only.

## Affected areas

- `docs/usage.md` (the "Listing tasks" section)

No source file, no test, and no other document needs to change. The test suite
is green today and must stay green.

## Notes

Cross-check the rest of the section while you are in there: the exit-code
sentence ("`list` exits 1 when nothing matches") is accurate and should be
kept.
