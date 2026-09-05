# `tests/fixtures/run-retro/`

Fixture substrate for `scripts/run-retro.sh` (issue #1272). `run-retro.sh --fixture <dir>`
reads its inputs from `<dir>` instead of calling `gh` / `git` / `cost-latency-report.sh`,
so `tests/test-run-retro.sh` never touches live data.

## Canonical names the script reads

| file | stands in for |
|---|---|
| `tracker.md` | `gh issue view <tracker> --json body --jq .body` (issue #1271) |
| `rows.json` | `scripts/cost-latency-report.sh --emit-rows-json` |
| `tool-use.log` | `.claude/logs/tool-use.log` (5-field TSV, `hooks/log-tool-use.sh`) |
| `usage-gate.jsonl` | `.claude/logs/usage-gate.jsonl` (`scripts/usage-gate.sh` snapshot) |
| `cycle-<NN>.md` | `docs/retros/cycle-<NN>.md` (previous-cycle retro) |
| `issues.json` | `gh issue list --json number,labels,body,comments` |
| `prs.json` | `gh pr list --json number,title,headRefName,body,mergedAt,labels,files` |

## Variant files (the test copies these OVER a canonical name in a temp copy)

| file | exercises |
|---|---|
| `tracker-2cycle.md` | verbatim `tracker.md` + an appended `Cycle 1` block — cross-cycle tests (previous-cycle deltas, pending verdicts, later-fix escapes) |
| `tracker-nonnumeric.md` | a baseline cell with zero numeric atoms → `n/a (non-numeric baseline)` |
| `tracker-missing-row.md` | the `harness mass` baseline row deleted → `n/a (baseline row not found: <key>)` |
| `tracker-garbled.md` | no `## Scorecard baseline` section → `n/a (tracker body unreadable)` |
| `tool-use-summary-blocked.log` | records whose **field 5 summary** contains `BLOCKED` → the denial row must STILL be `n/a` (a whole-line `grep -c BLOCKED` would self-inflate) |
| `tool-use-denied.log` | field-2 `denied` records → the denial row renders a count (2 unbounded, 1 under `--since 2026-09-03`) |

## `tracker.md` is a VERBATIM byte copy of the live #1271 body

Do not hand-simplify it. The baseline table's cells are compound prose
(`320 LOC · 23M tokens · 44 min · ≈$55 · 67k tokens/LOC`); a fixture with bare-number
cells cannot exercise the sub-metric decomposition, which is the whole point of the
delta join. Refresh this file whenever the #1271 baseline table is edited.

## Numbers the test pins

`rows.json` carries two IN-cycle-0 issues (#1272, #1273) and one OUT-of-cycle issue
(#9999) chosen so that including it shifts every median:

| metric | median over {1272, 1273} | median if #9999 leaked in |
|---|---|---|
| `loc` | 300 | 400 |
| `tokens` | 22000000 | 32000000 |
| `tokens/loc` | 70000 | 80000 |
| `min` | 45 | 50 |

Cycle-0 issue #1274 has no row → `n/a (outside PR window)`.
