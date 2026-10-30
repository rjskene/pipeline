## Context

A CI job fans out one `calibctl add` per failing check, all at once. On busy
machines it sometimes ends up with two tasks sharing an id, and with fewer
ledger rows than adds. It reproduces locally, though not on every run:

```
export CALIB_HOME="$(mktemp -d)"
for i in $(seq 10); do bash bin/calibctl add "task $i" >> ids.txt & done; wait
sort -u ids.txt | grep -c ''            # sometimes 9, not 10
grep -c '' "$CALIB_HOME/tasks.tsv"      # rows in the ledger
```

Two tasks with the same id is a real data bug: `complete` and `list` address
tasks by id, so a duplicate means `complete 4` can mark the wrong task done.

## Scope

Find out why concurrent adds can mint the same id, and fix the cause so the
behaviour is deterministic: any number of concurrent `calibctl add` calls must
each get a distinct id and write exactly one ledger row.

- Add `tests/case-ids.sh`, a regression case that starts at least ten
  concurrent `calibctl add` calls and asserts the ids are distinct, there is
  one ledger row per add, and the ledger ids are distinct.
- The case must not sleep, retry, skip, or lower the concurrency until the
  failure stops showing up — that would hide the bug, not catch it.

## Affected areas

- `lib/store.sh` — wherever the cause turns out to be
- `tests/case-ids.sh` — new regression case

## Notes

Out of scope for this issue: changing the record format, or replacing the
`mkdir`-based lock in `lib/lock.sh` with a different locking mechanism.
