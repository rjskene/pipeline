## Context

`calibctl list` prints one row per task, and the title is the last column. A
handful of tasks with long titles blow the row width out, and once the
terminal wraps, the id/status/priority columns no longer line up — the whole
point of the fixed-width columns `print_row` already uses for the other three
fields.

## Scope

Add a small helper to `lib/store.sh`:

```
store_truncate_title <title> <width>
```

Wire it into the row formatter in `bin/calibctl` so `list` renders every title
through it:

- default width: 40
- `calibctl list --width N` overrides the default for that invocation
- long titles are shortened with a trailing `...` so rows stay aligned
- short titles render exactly as typed — no padding, no truncation

## Affected areas

- `lib/store.sh` — the `store_truncate_title` helper
- `bin/calibctl` — `list`'s row formatter, plus the `--width` flag
- `tests/case-truncate.sh` — new test case file covering the helper and the
  `list --width` flag

The suite discovers `tests/case-*.sh` by glob, so a new file is all it takes;
there is no registry to update.

## Notes

Out of scope for this issue: truncating anything other than the title column,
and a `report`/`auth` equivalent. Keep the change scoped to `list`.
