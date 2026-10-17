# The calibration slate

Six canned issues, filed against the sandbox built from `dev/calib/template`,
chosen to cover the routing shapes a calibration run needs to distinguish.

| dir | shape | expected routing pressure | path |
|-----|-------|---------------------------|------|
| `01-doc-stale` | documentation only, no source or test change | PATH A | A |
| `02-quick-fix` | one-line source fix plus a regression assertion | PATH D | D |
| `03-feature`   | a new command that needs a new test case | single execute agent (test then code) | B |
| `04-race-auth` | a concurrency bug with an explicitly under-specified fix | high uncertainty | B |
| `05-two-dir`   | three independent deliverables in `lib/`, `bin/`, `docs/`, each with its own test | PATH C fan-out | C |
| `06-planted-defect` | a feature with a planted boundary defect the PR evaluator should catch | pr-eval gate yield | B |

`path` is the expected classification. `scripts/calibration-run.sh` reads this
column and appends `path-mismatch=<path>` to a `CALIB` line whose classified
path differs from it. Keep it a single letter (`A`–`D`) in the last cell of
the row.

## Per-issue files

| file | what it is |
|------|------------|
| `title.txt` | the issue title, conventional-commit style |
| `body.md` | the issue body: Context / Scope / Affected areas / Notes |
| `reference-test.sh` | the acceptance check, run inside the sandbox |
| `expected-files.txt` | sandbox-relative paths the fix is expected to touch |

`expected-files.txt` is an expectation, not a constraint — it is what the
calibration run scores the actual diff against.

## Running a reference test

Reference tests are run from the sandbox project root and take the sandbox root
as an optional argument:

```
cd /path/to/sandbox
bash /path/to/slate/03-feature/reference-test.sh
```

Every reference test **fails** against the untouched template and passes only
once its issue is fixed as specified. Each one also re-runs `bash tests/run.sh`,
so a fix that breaks the sandbox suite fails its reference test too.
