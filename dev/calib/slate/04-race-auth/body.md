## Context

Rotating the API token can leave every concurrent reader without one: there is
a race between the publish path and any reader, and a second race between two
publishers.

`auth_issue_token` in `lib/auth.sh` publishes in place: it truncates
`$CALIB_HOME/auth.token`, then appends the new value. Between those two
operations the file exists but is empty, so `auth_read_token` returns rc 6 and
`calibctl auth show` prints `no token issued` — for a token that was valid a
moment earlier and will be valid a moment later.

Reproduced with the `CALIB_AUTH_SLOW` seam, which widens the same window that
exists on a loaded machine:

```
$ bash bin/calibctl auth issue >/dev/null            # a token exists
$ CALIB_AUTH_SLOW=1 bash bin/calibctl auth issue &   # rotate, slowly
$ sleep 0.4; bash bin/calibctl auth show
calibctl: no token issued
$ echo $?
6
```

Two callers rotating at once is worse: both truncate, both append, and the file
can end up with two lines, of which `auth_read_token` silently returns the
first.

The store has the same read-modify-write hazard and solved it: `store.sh`
stages through a temp file and takes the `store` lock. The token helper does
neither — it never calls into `lib/lock.sh` at all.

## Scope

Make token publication atomic:

- write the new token to a temp file in the same directory, then rename it over
  `auth.token`, so a reader sees either the old token or the new one and never
  an empty file
- serialise issuance through the existing lock helper so two rotations cannot
  interleave
- keep the file mode at 600 and keep the `CALIB_AUTH_SLOW` seam working — the
  seam must still delay the *middle* of the publish, or the regression test
  stops proving anything

Reader-side retry is not an acceptable fix: `auth.token` itself must never be
observable as empty.

## Affected areas

- `lib/auth.sh` — `auth_issue_token`
- `tests/case-auth.sh` — a regression case for rotation

## Notes

`docs/architecture.md` already documents the intended invariant ("`auth_read_token`
reads the first line back", the seam, the store's temp-file + lock pattern), so
no documentation change should be needed.

Unclear how far to take this: it may be enough to reuse `with_lock auth`, or the
lock may need a dedicated name so a rotation cannot block ordinary ledger
writes. Whoever picks this up should decide and say why in the PR.
