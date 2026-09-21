# calibctl architecture

A deliberately small, deliberately boring bash project. The shape matters more
than the feature set: one entrypoint, a handful of single-responsibility
modules, a plain test runner, and a CI workflow that runs it.

```
bin/calibctl        argument parsing + command dispatch, nothing else
lib/store.sh        the file-backed record store
lib/lock.sh         advisory locking (mkdir-based)
lib/validate.sh     input validation for the CLI surface
lib/auth.sh         the API token helper
lib/report.sh       the `report` renderer
tests/run.sh        runs every tests/case-*.sh
tests/helper.sh     assertions shared by the case files
```

## Load order

`bin/calibctl` sources the modules in dependency order:

```
store.sh -> lock.sh -> validate.sh -> auth.sh -> report.sh
```

`lock.sh`, `auth.sh` and `report.sh` all call `store_home()`, so `store.sh`
must be sourced first. Nothing else has cross-module dependencies.

## The store

One tab-separated file, `$CALIB_HOME/tasks.tsv`, one record per line:

```
id <TAB> status <TAB> priority <TAB> created <TAB> tags <TAB> title
```

Appends are a single `>>` write, which is atomic for short lines. Anything
that has to read-modify-write the whole file (`store_set_status`) runs under
the `store` lock and stages its output through a temp file before `mv`.

Ids are allocated as `max(id) + 1`, computed under the same lock. Ids are
never reused, so a completed task keeps its number forever.

## Locking

`lock_acquire` creates `$CALIB_HOME/locks/<name>.lock` with `mkdir`, which is
atomic. On contention it retries every 100ms until `CALIB_LOCK_TIMEOUT`
seconds have elapsed and then returns rc 3.

A lock directory older than `CALIB_LOCK_STALE` seconds (default 30) is assumed
to belong to a crashed process and is reclaimed. That is the only recovery
mechanism: there is no lock daemon and no pid liveness check beyond the
`owner` file written for debugging.

## Auth tokens

`auth_issue_token` mints 32 hex characters and publishes them to
`$CALIB_HOME/auth.token`. `auth_read_token` reads the first line back.

`CALIB_AUTH_SLOW` is a test seam: set it to a number of seconds and the write
path pauses for that long in the middle of publishing a token. It exists so
tests can observe what a concurrent reader sees during a rotation without
depending on scheduler luck.

## The report

`report_render` prints, in order:

- the `open`, `done` and `total` counts
- a `by priority` breakdown (high, med, low)
- the oldest open task, when there is one

Every number comes from `store_rows`, so the report can never disagree with
`list`.

## Tests

`tests/run.sh` globs `tests/case-*.sh`, runs each one in its own bash process,
and exits non-zero if any of them fails. Each case file sources
`tests/helper.sh`, calls `t_setup` (which points `CALIB_HOME` at a fresh
scratch directory and registers a cleanup trap), and ends with `t_report`.

Adding a test means adding a file. There is no registry to update.
