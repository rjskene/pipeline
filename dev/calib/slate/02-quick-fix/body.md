## Context

`validate_id` in `lib/validate.sh` is supposed to accept a positive integer and
reject everything else. It uses an unanchored pattern, so any string that
*contains* a digit slips through:

```
$ bash bin/calibctl complete 1x
calibctl: no such task: 1x
$ echo $?
4
```

The user typo'd an id. The expected response is the validation error (rc 2,
`invalid id`); instead the value reaches the store and comes back as
`no such task`, which sends people hunting for a task that never existed. The
same applies to `12abc`, `id=3` and `" 3"`.

Purely alphabetic ids (`abc`) are rejected correctly today, which is why the
existing suite does not catch this.

## Scope

Anchor the pattern in `validate_id` so it matches a whole positive integer and
nothing else, and add a regression assertion to `tests/case-validate.sh`
covering the mixed-input case (`1x` / `12abc`).

This is a quick-fix: the production change is one line.

Two behaviours must not change:

- a syntactically valid but unknown id (`calibctl complete 99`) keeps returning
  rc 4 with `no such task` — do not turn "unknown" into "invalid"
- a valid id still completes normally

## Affected areas

- `lib/validate.sh` — the `validate_id` pattern
- `tests/case-validate.sh` — the regression assertion

## Notes

`validate_id` is the only caller-facing id check; `bin/calibctl` calls it
before touching the store, so no other call site needs auditing.
