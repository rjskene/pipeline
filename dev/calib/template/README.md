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

_Calibration slate issue `06-planted-defect` (title truncation in `list`)
intentionally ships unimplemented here — see `dev/calib/slate/06-planted-defect/`._

## Web view

`web/index.html` is a static, read-only view of a fixed task list
(`web/tasks.js`). Serve it and open it in a browser:

```
python3 -m http.server <port> --directory web
# then open http://localhost:<port>/
```

It also opens straight from disk (`file://`). `tests/case-web.sh` renders it in
a headless browser and skips when none is installed.

## Layout

| path            | what it is                                  |
|-----------------|---------------------------------------------|
| `bin/calibctl`  | the entrypoint: parse arguments, dispatch   |
| `lib/*.sh`      | store, locking, validation, auth, reporting |
| `tests/`        | the runner plus one file per `case-*`       |
| `docs/`         | usage guide and architecture notes          |
| `web/`          | the static ledger view and its task fixture |

See [docs/usage.md](docs/usage.md) and [docs/architecture.md](docs/architecture.md).
