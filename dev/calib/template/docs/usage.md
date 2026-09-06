# Using calibctl

`calibctl` is a single-file bash entrypoint. Nothing to install: clone the
repo and run it.

```
bash bin/calibctl help
```

State lives under `./.calib` by default. Point `CALIB_HOME` somewhere else to
keep several ledgers side by side:

```
CALIB_HOME=~/.calib-work bash bin/calibctl list
```

## Adding tasks

```
bash bin/calibctl add "write the release notes"
bash bin/calibctl add "fix the flaky lock test" --priority high
bash bin/calibctl add "prune stale branches" --priority low --tag chore,ops
```

`add` prints the id of the new task. Priorities are `low`, `med` (the default)
and `high`. Tags are a comma-separated list with no spaces.

Titles are trimmed and must be at most 120 characters.

## Listing tasks

```
bash bin/calibctl list
bash bin/calibctl list --priority high
bash bin/calibctl list --all
```

By default `list` shows every task in the ledger. Pass `--all` to include the
tasks you have already completed. `list` exits 1 when nothing matches, which
makes it easy to use in a shell conditional:

```
if bash bin/calibctl list --priority high >/dev/null; then
  echo "there is high-priority work outstanding"
fi
```

## Completing tasks

```
bash bin/calibctl complete 3
```

Ids are positive integers. Completing an unknown id exits 4; completing a task
that is already done is a no-op that still exits 0.

## Reporting

```
bash bin/calibctl report
```

Prints the open/done/total counts, a breakdown by priority, and the oldest
open task.

## The API token

```
bash bin/calibctl auth issue
bash bin/calibctl auth show
bash bin/calibctl auth revoke
```

Tokens are 32 hex characters and live in `$CALIB_HOME/auth.token`. `show` and
`revoke` exit 6 when no token has been issued.

## Exit codes

| code | meaning                         |
|------|---------------------------------|
| 0    | success                         |
| 1    | no matching records             |
| 2    | usage or validation error       |
| 3    | could not acquire a lock        |
| 4    | no such task                    |
| 6    | auth token missing              |
