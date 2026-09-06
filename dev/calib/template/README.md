# calibctl

A tiny task ledger in bash. Add a task, list what is open, complete it, print a
report. No dependencies beyond coreutils.

```
bash bin/calibctl add "write the release notes" --priority high
bash bin/calibctl list --status open
bash bin/calibctl complete 1
bash bin/calibctl report
```

## Tests

```
bash tests/run.sh            # everything
bash tests/run.sh case-auth  # one case file
```

CI runs the same command on every push and pull request.

## Layout

| path            | what it is                                  |
|-----------------|---------------------------------------------|
| `bin/calibctl`  | the entrypoint: parse arguments, dispatch   |
| `lib/*.sh`      | store, locking, validation, auth, reporting |
| `tests/`        | the runner plus one file per `case-*`       |
| `docs/`         | usage guide and architecture notes          |

See [docs/usage.md](docs/usage.md) and [docs/architecture.md](docs/architecture.md).
