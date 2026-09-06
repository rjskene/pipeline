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
CALIB issue=<n> path=<X> cost=<$> wall=<s> verdicts=<plan-eval/pr-eval> reftest=<pass|fail> unexpected-files=<n>
CALIB-TOTAL cost=<$> wall=<s> issues=<n> reftest-pass=<n>/<n>
```

- `path` — the PATH letter the harness actually routed to (compare against the
  slate's expected path; a mismatch is a routing regression).
- `verdicts` — plan-eval and pr-eval verdicts, slash-separated.
- `reftest` — the sandbox issue's reference test after the PR lands.
- `unexpected-files` — files touched beyond the issue's expected-files list.

The tee target is **harness-rooted**, not sandbox-rooted:

```
$HARNESS/docs/retros/calib/<date>.txt
```

The artifact belongs to the harness whose behaviour it measures, so it is committed
alongside the retro that cites it. The sandbox clone is disposable — `--reset`
destroys its history every run.

## Retro ingest

`scripts/run-retro.sh` reads the **newest** `docs/retros/calib/*.txt` by filename
date and feeds two places in the cycle report:

- **`weak-model pass:`** — the spec section 7 row. Without an artifact it reports
  `n/a (no calibration slate; ...)`; with one it reports the `reftest-pass=<n>/<n>`
  ratio from `CALIB-TOTAL` plus the profile/model the run used.
- **`median path b pr/usd`** — the computed value that is otherwise
  `n/a (no per-issue cost in rows JSON)`, because ordinary rows JSON carries no
  per-issue dollar cost. The median of the `cost=` fields on the `CALIB` lines whose
  `path=B` supplies it, and the baseline delta then joins as normal.

Because ingest is newest-artifact-wins, a stale artifact keeps being reported until
a newer run replaces it — the report names the artifact's date so the reader can
see how old the calibration evidence is. See `docs/retros/README.md` for the
retro-file layout.
