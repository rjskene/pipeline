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

Prints the open/done/total counts, a breakdown by priority, the oldest open
task, and the next task to pick up (the oldest open high-priority one).

## The API token

```
bash bin/calibctl auth issue
bash bin/calibctl auth show
bash bin/calibctl auth revoke
```

Tokens are 32 hex characters and live in `$CALIB_HOME/auth.token`. `show` and
`revoke` exit 6 when no token has been issued.

## Output conventions

`list` and `report` are for people. Anything that writes tabular,
machine-readable output is for scripts, and follows these conventions so a
script can rely on them:

- one record per task, in id order
- columns appear in the order `list` shows them: `id`, `status`, `priority`,
  `title`
- values are raw: the id is a bare integer (no `#`, no padding); status and
  priority are written exactly as stored
- fields follow RFC 4180: a field containing a comma, a double quote or a line
  break is wrapped in double quotes, and any double quote inside it is
  doubled (`a "b", c` is written `"a ""b"", c"`); every other field is
  written bare
- every record, the header included, ends in `\n`
- a header row naming the columns (`id,status,priority,title`) is always the
  first line, even when the ledger is empty

## Exit codes

| code | meaning                         |
|------|---------------------------------|
| 0    | success                         |
| 1    | no matching records             |
| 2    | usage or validation error       |
| 3    | could not acquire a lock        |
| 4    | no such task                    |
| 6    | auth token missing              |
