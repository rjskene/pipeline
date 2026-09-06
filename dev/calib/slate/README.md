# The calibration slate

Five canned issues, filed against the sandbox built from `dev/calib/template`,
chosen to cover the routing shapes a calibration run needs to distinguish.

| dir | shape | expected routing pressure |
|-----|-------|---------------------------|
| `01-doc-stale` | documentation only, no source or test change | PATH A |
| `02-quick-fix` | one-line source fix plus a regression assertion | PATH D |
| `03-feature`   | a new command that needs a new test case | split-role (test then code) |
| `04-race-auth` | a concurrency bug with an explicitly under-specified fix | high uncertainty |
| `05-two-dir`   | edits required in two disjoint directories | PATH C fan-out |

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
