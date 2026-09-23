# Evolve-loop retros — per-cycle scorecard

One file per cycle, `cycle-<NN>.md` (zero-padded, e.g. `cycle-00.md`, `cycle-01.md`),
written by `scripts/run-retro.sh --cycle N --write docs/retros/cycle-<NN>.md`
(the `--write` path is chosen by the caller — `skills/evolve/SKILL.md`, #1273 —
not by `run-retro.sh` itself). Modelled on `docs/tokenomics/README.md`: this is
the human/machine-readable analysis layer for the harness-evolve loop
(spec: `docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md` §4/§7).

A file is never created by a bare `run-retro.sh --cycle N` run — only an
explicit `--write PATH` writes to disk, and only the evolve skill decides
when a cycle is complete enough to snapshot. Running without `--write` is
side-effect-free (see `tests/test-run-retro.sh` Scenario 16).

## What's in a `cycle-NN.md`

The FULL (untruncated) `run-retro.sh` report for that cycle, plus the
evolve skill's diagnose reasoning appended below it:

- `cycle-issues:` — the tracker's `## Cycle issues` bullets for this cycle.
- `delta <row>/<label> …` — signed diff between the `#1271` tracker baseline
  (decomposed into `<row>/<label>` sub-metrics) and this cycle's computed
  value, for every sub-metric present on both sides (an inner join — see
  `--dump-baseline` / `--dump-computed`). A baseline row with no computed
  counterpart is carried through verbatim (no delta, no `n/a` noise); a
  computed key with no baseline counterpart renders
  `n/a (baseline row not found: <key>)`.
- `friction: …` / `escapes: …` / `gate-yield: …` / `weak-model pass: …` /
  `usage: …` — the non-baseline rows from spec §7 (friction/denials,
  HARNESS-FRICTION harvest, hotfix/manual-merge/human operator escapes,
  hotfix/revert/later-fix escapes, plan-eval Revise rate, pr-eval Flagged
  rate, weak-model calibration pass, five-hour/seven-day usage snapshot).
  `friction/compactions` was removed (#1396): no code path ever populated it,
  so it always rendered the same `n/a (no transcript substrate)` literal.
- `prev-delta <row>/<label> …` — diff against the PREVIOUS cycle's own
  computed values (read from `docs/retros/cycle-<N-1>.md`), or
  `n/a (no previous cycle)` at cycle 0.
- `pending-verdicts:` — issues from the PREVIOUS cycle whose `## Evolve`
  block says `Measured by: retro (next cycle)`; this cycle's data is what
  resolves them.
- `## Diagnose` — appended by the evolve skill, not by `run-retro.sh`:
  which hypothesis-backlog rows moved, verdict decisions (confirmed /
  no-effect / regressed) for the pending verdicts above, and next-cycle
  candidates (this cycle's own `Measured by: retro (next cycle)` issues,
  surfaced via `run-retro.sh --post` as `verdict-candidates:`).

## Fixture substrate

`run-retro.sh` never calls `gh`/`git` directly in `--fixture DIR` mode; see
`tests/fixtures/run-retro/README.md` for the canonical fixture file names
(`tracker.md`, `rows.json`, `tool-use.log`, `usage-gate.jsonl`,
`cycle-<NN>.md`, `issues.json`, `prs.json`) and the numbers the test suite
pins.

## Calibration substrate

Calibration-run artifacts live beside the cycle files, in `docs/retros/calib/`,
one file per run named `<date>.txt` (e.g. `2026-09-12.txt`). Each is the teed
stdout of `bash scripts/calibration-run.sh --run` — one `CALIB issue=... ` line
per slate issue plus a final `CALIB-TOTAL ...` line. The directory is
harness-rooted on purpose: the artifact measures *this* harness version, while
the sandbox clone it came from is reset to `calib-base` on the next run. A
`<date>.log`, the headless session's own output, is written beside each
`<date>.txt`.

`run-retro.sh` ingests the newest `docs/retros/calib/*.txt` (by filename date)
into two spots in the cycle report:

- `weak-model pass:` — a `<pass>/<rows>` ratio counted over the `reftest=` atoms
  of the per-issue `CALIB` rows; the `CALIB-TOTAL` line is not parsed.
  `n/a (no calibration slate; ...)` when no artifact exists. An artifact whose
  first line is `CALIB-ABORT reason=...` renders as
  `n/a (calibration run aborted: ...)` rather than a ratio.
- `median path b pr/usd` — the median `cost=` across the `path=B` rows only
  (other paths are skipped), which is otherwise
  `n/a (no per-issue cost in rows JSON)`. Each `cost=` is
  apportioned from the run's priced total by token share, so the median is an
  estimate, not a measured per-issue charge.

The CALIB grammar carries no profile, model or date atom, so neither row can
state which `--profile`/`--model` produced it. The `weak-model pass:` row is
the exception on DATE: it reads the chosen artifact's own FILENAME (never a
CALIB atom) and renders `<value> (run <date>)` when that filename resolves a
`YYYY-MM-DD` date, or the bare `<value>` when it does not (the undated
`calib.txt` fallback). Once N ≥ 3 tracker `## Cycle <k>` comments have been
posted after that day, the row instead renders
`<value> (run <date>, stale N cycles)`. Ingest itself is still newest-wins and
does not expire, so a cycle with no fresh run keeps citing the last artifact —
the stale marker says so instead of the report staying silent. Full operator
guide (modes, knobs, cost band, triggers): `docs/calibration.md`.

## Index

Cycle-by-cycle index, regenerated by `run-retro.sh --index`.

| cycle | date | issues | verdicts | tokens |
|---|---|---|---|---|
| 00 | 2026-09-05 | #1272 #1273 #1274 | 3/0/0 | — |
| 01 | 2026-09-06 | #1280 #1281 #1282 | 1/0/0 | — |
| 02 | 2026-09-06 | #1285 #1286 #1287 | 1/0/0 | — |
| 03 | 2026-09-06 | #1291 #1292 #1293 | 2/0/0 | — |
| 04 | 2026-09-07 | #1298 #1299 #1300 | 1/1/0 | — |
| 05 | 2026-09-08 | #1303 #1304 #1305 | 3/0/1 | — |
| 06 | 2026-09-10 | #1294 #1282 #1306 | 4/0/0 | — |
| 07 | 2026-09-11 | #1315 #1316 #1317 | 1/1/0 | — |
| 08 | 2026-09-11 | #1321 #1322 #1323 | 4/0/0 | — |
| 09 | 2026-09-14 | #1327 #1328 #1329 | 1/2/0 | — |
| 10 | 2026-09-14 | #1333 #1334 #1335 | 3/0/0 | — |
| 11 | 2026-09-14 | #1339 #1340 #1341 | 2/1/0 | 34.0M |
| 12 | 2026-09-15 | #1342 #1346 #1347 | 3/0/0 | 11.4M |
| 13 | 2026-09-21 | #1360 #1361 #1362 | 3/0/0 | 15.2M |
| 14 | 2026-09-21 | #1366 #1367 #1368 | 3/0/0 | 19.9M |
| 15 | 2026-09-22 | #1372 #1373 #1374 | 3/0/0 | 18.4M |
| 16 | 2026-09-22 | #1380 #1381 #1382 | 3/0/0 | — |
| 17 | 2026-09-23 | #1387 #1388 #1389 | 2/0/0 | — |
