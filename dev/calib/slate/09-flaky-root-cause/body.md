## Context

`tests/case-ids.sh` is flaky in CI. It starts ten `calibctl add` calls at once
and checks that every one of them gets its own task id and its own ledger row.
Most runs pass; roughly one in five fails with two tasks sharing an id:

```
RUN  case-ids
    NOT OK - 10 concurrent adds return 10 distinct ids (expected '10', got '9')
```

Two tasks with the same id is a real data bug, not a test artefact: `complete`
and `list` address tasks by id, so a duplicate means `complete 4` can mark the
wrong task done. Scripts that add tasks in parallel (a CI job fanning out
`calibctl add` per failing check) hit it on busy machines.

## Scope

Find out why concurrent adds can mint the same id, and fix the cause so the
behaviour is deterministic: any number of concurrent `calibctl add` calls must
each get a distinct id and write exactly one ledger row.

- `tests/case-ids.sh` stays, and keeps asserting that concurrent adds get
  distinct ids.
- Retrying the test, adding sleeps to it, skipping it, or lowering it to a
  level of concurrency where the failure stops showing up is not a fix — the
  bug would still be there.

## Affected areas

- `lib/store.sh` — wherever the cause turns out to be
- `tests/case-ids.sh` — the existing case; only touch it if it is wrong

## Notes

Out of scope for this issue: changing the record format, or replacing the
`mkdir`-based lock in `lib/lock.sh` with a different locking mechanism.
