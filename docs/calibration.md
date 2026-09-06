# Calibration slate

Real-work retros cannot isolate cause: every cycle's workload differs, so a cost or
latency delta between cycles says nothing about the harness. The calibration slate
holds the *inputs* fixed — same sandbox repo, same five issues, same base commit —
so the harness version under test is the only variable. It doubles as the
end-to-end regression suite the unit tests are not.

Spec: `docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md` section 8.

## Sandbox

- **Repo:** `rjskene/pipeline-calib` (private) — a small purpose-built consumer
  project (scripts, tests, docs, CI workflow, `pipeline.config`, seeded labels).
- **Clone location:** `${PIPELINE_CALIB_DIR:-$HOME/.claude/calib/pipeline-calib}` —
  inside the boundary `restrict_paths.py` already allows, so no hook change.
- **Slate:** five template issues committed at tag `calib-base`, each with a
  reference test and an expected-files list:

  | Issue | Path | Exercises |
  |---|---|---|
  | stale doc line | A | docs-only routing |
  | one-line script bug, failing test present | D | quick-fix lane |
  | small feature needing a new test | B | full lifecycle, split-role, pr-eval |
  | body with `race`/`auth` vocabulary | B + W2 | carve-out routing to opus |
  | two-directory change | C | per-leaf worktree fan-out, cherry-pick reassembly |

## Running

```
bash scripts/calibration-run.sh --bootstrap|--reset|--dry-run|--run \
    [--profile strict|lean] [--model sonnet|opus] [--harness <dir>]
```

| Mode | What it does | Costs money |
|---|---|---|
| `--bootstrap` | Clone the sandbox to the calib dir if absent; verify the `calib-base` tag and the slate templates are present. Idempotent. | no |
| `--reset` | Force-reset the sandbox default branch to `calib-base`, close/delete leftover run issues and PRs, recreate the five slate issues from their templates. | no |
| `--dry-run` | Print the exact `claude -p` launch (env, `--plugin-dir`, prompt, timeout) and the artifact path, then exit without launching. Use this to review a run before paying for it. | no |
| `--run` | `--reset`, then launch the headless run, wait, and emit the `CALIB` summary. | **yes** |

`--profile` selects the sandbox's evaluator strictness (`strict` for the weak-model
guarantee, `lean` otherwise). `--model` picks the executor model. `--harness <dir>`
points at the harness working tree under test — it defaults to this repo's root.

`--reset` is what makes a run comparable to the previous one: inputs are pinned to
the `calib-base` tag, so a delta between two `CALIB-TOTAL` lines is attributable to
the harness version, not to the workload.

The launch exports both `CLAUDE_PLUGIN_ROOT=<harness>` and passes
`--plugin-dir <harness>` to `claude -p`. Both are required: the env var is what
skill bodies resolve `${CLAUDE_PLUGIN_ROOT}` against, and `--plugin-dir` is what
makes the CLI load that tree's commands/skills instead of the installed plugin.
Set one without the other and the run silently exercises the wrong harness.

The session is launched with `env -u ALLOW_ORCHESTRATOR_EDIT`, so the loop
session's orchestrator-edit override cannot leak in and switch off the
delegation hook the measured run exists to exercise, and with
`PIPELINE_HEADLESS=true` — the seam the fullsend headless contract (#1286) will
read. Nothing consumes that marker yet.

## Harness staging

`hooks/restrict_paths.py` allows only the session's own project dir and
`~/.claude`, so a harness tree living anywhere else has its scripts blocked
inside the sandbox session (run #1 died that way, in 87 seconds).

`--run` therefore stages the harness before launching: its committed HEAD is
checked out as a detached git worktree at `$HOME/.claude/calib/harness` — the
`calib/harness` sibling of the sandbox clone — refreshed to HEAD every run,
with `pipeline.config` copied in, since that file is gitignored and host-specific.
Consequences:

- **Uncommitted harness edits are not under test.** The stage tracks HEAD;
  commit before you pay for a run.
- `--dry-run` computes and prints the staged path but never creates it.
- A stage directory that is a checkout of some other repo is a hard error
  naming the directory, never an automatic delete.
- Only the launch moves. Artifacts still land in the ORIGINAL harness, so a
  run's evidence is committed beside the retro that cites it.

## Knobs

| Variable | Default | Meaning |
|---|---|---|
| `PIPELINE_CALIB_DIR` | `$HOME/.claude/calib/pipeline-calib` | Where the sandbox clone lives. |
| `PIPELINE_CALIB_TIMEOUT` | see `pipeline.config.example` | Wall-clock ceiling (seconds) for the headless run before it is killed and the partial summary emitted. |
| `PIPELINE_CALIB_REPO` | `rjskene/pipeline-calib` | `owner/name` of the sandbox repo, for forks or a re-homed sandbox. |

## Cost

A full `--run` costs **≈$60–120** and takes hours. The `claude -p` launch is a
headless session that **bills the operator's account** exactly like an interactive
one — it consumes the same five-hour and weekly usage budget, and it will not stop
to ask. Consequences:

- The **first paid `--run` requires an explicit operator go.** Never launch one
  because a plan step said so; `--dry-run` first and hand the launch command to the
  operator.
- Check the usage gate before launching. A run that trips the weekly cap mid-slate
  produces a partial, non-comparable result and still bills for what it used.
- `--bootstrap`, `--reset` and `--dry-run` are free — use them freely.

Only the run total is a priced figure. The per-issue `cost=` on each `CALIB`
line is apportioned out of that total by token share (see Output), so any
per-issue dollar number — including the retro's path-B median — is approximate.

## When to run

Two triggers, and only these two:

1. An issue whose `## Evolve` block says `Measured by: calibration run` — the
   change it makes is not observable in ordinary per-cycle retro data.
2. **Once per seven cycles** under `--profile strict --model sonnet`, for the
   weak-model guarantee: the harness must carry a weak executor through the slate.

Not every cycle. At ≈$60–120 a run, a per-cycle cadence would dominate the loop's
own budget.

## Output

One `CALIB` line per slate issue, then one total, both on stdout and teed to the
artifact:

```
CALIB-ABORT reason=<no-pr|held|timeout>
CALIB issue=<n> path=<X> cost=<$> wall=<s> verdicts=<plan-eval/pr-eval> reftest=<pass|fail> unexpected-files=<n>
CALIB-TOTAL cost=<$> wall=<s> issues=<n> reftest-pass=<n>/<n>
```

The `CALIB-ABORT` line is written only when the run did not finish, and is then
the first line of the block.

- `path` — the PATH letter the harness routed to, read from the issue's
  `## Classification` comment; `?` means it was never classified. Labels are
  never consulted — after a merge they say only that. Compare against the
  slate's expected path; a mismatch is a routing regression.
- `wall` — the issue's `createdAt` to the merging PR's `mergedAt`, in seconds;
  `n/a` when nothing merged for that issue or when `date -d` is unavailable.
- `cost` — the issue's **apportioned** share of the run's priced total, split by
  that issue's share of the run's total tokens. The rows JSON carries no
  per-issue dollar figure, so this is an estimate, not a measured per-issue charge.
  Only `CALIB-TOTAL cost` is a real priced number.
- `verdicts` — plan-eval and pr-eval verdicts, slash-separated.
- `reftest` — the sandbox issue's reference test after the PR lands.
- `unexpected-files` — files touched beyond the issue's expected-files list.
- `reason` — why an aborted run stopped: `no-pr` (the session opened no pull
  request at all), `held` (its final message ends on a question nobody was
  there to answer) or `timeout` (the wall-clock ceiling killed it); `timeout`
  wins over `held`, which wins over `no-pr`. Issues the run never reached read
  `reftest=n/a` and the total reads `reftest-pass=n/a`, so a failed start can
  never be graded `0/5`.

The tee target is **harness-rooted**, not sandbox-rooted:

```
$HARNESS/docs/retros/calib/<date>.txt
```

The artifact belongs to the harness whose behaviour it measures, so it is committed
alongside the retro that cites it. The sandbox clone is disposable — `--reset`
destroys its history every run.

`--run` also writes `<date>.log` beside it: the headless session's own output,
truncated per run like the `.txt`. That is where the question a `held` run
stopped on is visible.

## Retro ingest

`scripts/run-retro.sh` reads the **newest** `docs/retros/calib/*.txt` by filename
date and feeds two places in the cycle report:

- **`weak-model pass:`** — the spec section 7 row, counted over the `reftest=`
  atoms of the per-issue `CALIB` rows: the rows reading `reftest=pass`, over the
  number of `CALIB` rows read. The `CALIB-TOTAL` line is not parsed at all; its
  `reftest-pass` field is a convenience for human readers that happens to count
  the same rows. Without an artifact the row reports
  `n/a (no calibration slate; ...)`.
- **`median path b pr/usd`** — the computed value that is otherwise
  `n/a (no per-issue cost in rows JSON)`. It is the median of the `cost=` atoms
  of the `path=B` rows only — rows on every other path are skipped — and the
  baseline delta then joins as normal. Because `cost=` is apportioned, that
  median is approximate: it estimates the typical path-B share of the run, not a
  billed per-PR amount.

Both rows render as bare values. The CALIB grammar carries no profile, model or
run-date atom, so the cycle report cannot state which `--profile`/`--model`
produced a ratio, or when. Ingest is newest-artifact-wins and never expires, so
a stale artifact keeps being cited until a newer run replaces it, and nothing in
the report says how old it is — read the filenames under `docs/retros/calib/` to
date the evidence yourself. Surfacing provenance in the row would mean adding
atoms to the CALIB grammar; that is a follow-up, not current behaviour. See
`docs/retros/README.md` for the retro-file layout.

## Lessons from runs #1 and #2

- **Run #1** pointed `--harness` at a tree outside `~/.claude`; the sandbox
  session could not read its own harness scripts and died in 87 seconds. The
  empty result was then graded `0/5` instead of being called a failed start.
  Harness staging and `CALIB-ABORT` are the two fixes.
- **Run #2** merged wave 1, then stopped to ask the operator about the sandbox
  template's inert auto-merge line and its "a human closes the loop" comment;
  both are gone from the template. The docs-only issue graded `path=B` off its
  post-merge labels, and `cost=`/`wall=` came back `n/a` because the sandbox
  registered no cost-capture hooks.
