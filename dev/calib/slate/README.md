# The calibration slate

Nine canned issues, filed against the sandbox built from `dev/calib/template`,
chosen to cover the routing shapes a calibration run needs to distinguish.

| dir | shape | expected routing pressure | path |
|-----|-------|---------------------------|------|
| `01-doc-stale` | documentation only, no source or test change | PATH A | A |
| `02-quick-fix` | one-line source fix plus a regression assertion | PATH D | D |
| `03-feature`   | a new command that needs a new test case | single execute agent (test then code) | B |
| `04-race-auth` | a concurrency bug with an explicitly under-specified fix | high uncertainty | B |
| `05-two-dir`   | three independent deliverables in `lib/`, `bin/`, `docs/`, each with its own test | PATH C fan-out | C |
| `06-planted-defect` | a feature with a planted boundary defect the PR evaluator should catch | pr-eval gate yield | B |
| `07-planted-regression` | a small filter whose natural implementation silently changes untested existing behaviour | pr-eval reviewer yield | B |
| `08-underspecified-convention` | an output format fixed only by the codebase's documented conventions | planner reads the codebase | B |
| `09-flaky-root-cause` | an intermittent test whose cause is a real race | executor fixes the cause, not the test | B |

**Slate v3** (#1531) is rows 07–09: nine issues from calibration run 38 on, so
run totals are not comparable with v2 (six-issue) runs — compare against v2
through rows 01–06, which are unchanged. `planted=` grades every `*planted*`
row (06 and 07): `missed` if any missed, `caught` only when all were caught.
The template's `tests/case-ids.sh` is 09's deliberately flaky case; it stays
red about one run in five until 09 is fixed.

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
