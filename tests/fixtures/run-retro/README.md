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
| `calib.txt` | latest `docs/retros/calib/<date>.txt` CALIB block (`scripts/calibration-run.sh --run`) |

### The `calib.txt` CALIB grammar

Outside `--fixture` mode `run-retro.sh` resolves this substrate itself, newest-first by
filename date, from `docs/retros/calib/*.txt`. The block is one line per calibration
slate issue plus one total:

```
CALIB-ABORT reason=<no-pr|held|timeout>
CALIB issue=<n> path=<X> cost=<$> wall=<s> verdicts=<plan-eval/pr-eval> reftest=<pass|fail> unexpected-files=<n>
CALIB-TOTAL cost=<$> wall=<s> issues=<n> reftest-pass=<n>/<n>
```

`compute_calib()` reads three atoms off the `CALIB` lines only: `reftest=` (the
`weak-model pass` k/n), plus `cost=` filtered by `path=B` (the `median path b pr/usd`
median). A missing `calib.txt`, or one carrying no `CALIB ` rows, degrades to the
`n/a (...)` reasons instead of failing. An artifact that STARTS with a
`CALIB-ABORT` line — written only when the run did not finish — makes
`compute_calib()` render `weak-model pass` as `n/a (calibration run aborted: …)`
rather than a k/n over rows the run never reached. Grammar reference:
`docs/calibration.md`.

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

## Cycle-scope fields and the out-of-scope control rows (#1281)

`run-retro.sh` scopes the friction / escape rows to the cycle window, so both
JSON feeds carry the fields the window predicate reads:

| field | file | stands in for | why the fixture needs it |
|---|---|---|---|
| `createdAt` | `issues.json` | `gh issue list --json …,createdAt` | FALLBACK lower bound for the cycle window when a `Cycle N (…` tracker header carries no date. Cycle-0 issues are stamped `2026-09-05T…`, cycle-1 issues `2026-09-12T…` |
| `baseRefName` | `prs.json` | `gh pr list --json …,baseRefName` | a merged PR only counts toward a cycle when it landed on the base branch (`evolve`); a PR merged into `main` is out of scope no matter when it merged |

Issue `#1271` is the TRACKER row (`labels: ["tracker"]`). Its single comment is a
verbatim `## Cycle 0` cycle comment: the `- issues:` line, a `- verdicts:` line
carrying `#1272 confirmed · #1273 no-effect · #1281 regressed (reverted by PR #2104)
| pending: #1274 (retro next cycle)`, and THREE `HARNESS-FRICTION:` lines. It is
the substrate for two behaviours: the pending-verdict subtraction (a cycle-1 run
must drop `#1273`, keep `#1274`) and the cycle-N>0 comment window (a cycle-1 full
report counts and echoes those three lines). `#1271` appears in NO `## Cycle …`
block, so its friction lines cannot leak into a cycle-scoped issue-comment
harvest — the cycle-0 count stays 2.

### Out-of-scope control rows

Four rows exist only to be EXCLUDED; each fails a different half of the window
predicate, so a scope regression moves a pinned count:

| row | file | why it is out of scope |
|---|---|---|
| `#1990` (PR, head `feature/hotfix-990`, base `evolve`, merged `2026-08-01`) | `prs.json` | right base, but merged before every cycle window — a repo-wide `friction/hotfix` count picks it up |
| `#1991` (PR, head `feature/hotfix-991`, base `main`, label `manual-merge`, merged `2026-09-13`) | `prs.json` | inside the cycle-1 time range but WRONG base — pins both `friction/hotfix` and `friction/manual-merge` |
| `#1299` (issue, label `human`, created `2026-09-20`) | `issues.json` | in no cycle block — a repo-wide `friction/human` count picks it up |
| `#1271` (issue, label `tracker`) | `issues.json` | the tracker itself is in no cycle block — its 3 `HARNESS-FRICTION:` lines must not join a cycle-0 issue-comment harvest |

Neither `#1990` nor `#1991` closes an issue, so both land in the escape
computation's current-cycle PR set and inflate `escapes/hotfix` until the window
is applied. Their `files` are disjoint from every cycle-0 PR's, so
`escapes/later-fix` is unaffected either way.
