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
the sandbox clone it came from is reset to `calib-base` on the next run.

`run-retro.sh` ingests the newest `docs/retros/calib/*.txt` (by filename date)
into two spots in the cycle report:

- `weak-model pass:` — the `reftest-pass=<n>/<n>` ratio from `CALIB-TOTAL`,
  with the profile/model of the run; `n/a (no calibration slate; ...)` when no
  artifact exists.
- `median path b pr/usd` — the median `cost=` across the `path=B` `CALIB`
  lines, which is otherwise `n/a (no per-issue cost in rows JSON)`.

Ingest is newest-wins and does not expire: a cycle with no fresh run keeps
citing the last artifact, so the report names its date. Full operator guide
(modes, knobs, cost band, triggers): `docs/calibration.md`.

## Index

No cycles have been posted yet (issue #1272 is the cycle-0 tooling
deliverable). Add a row here as each `cycle-NN.md` lands:

- _(none yet)_
