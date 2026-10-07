# Skills API reference

The exhaustive catalogue of pipeline slash commands — invocation form, args/flags, and interaction surfaces (labels, config knobs, body markers). For the curated "start here" set, see the [Canonical entry points](../README.md#canonical-entry-points) table in the README.

> **Source of truth is each `skills/<name>/SKILL.md`.** This reference *summarizes* the argv surface — it does not redefine behavior. When a flag changes, edit the SKILL.md (authoritative) and then this one line. Each subsection links its SKILL.md.

## Master table

| Command | Args / flags | Summary |
|---|---|---|
| [`/pipeline:status`](../skills/status/SKILL.md) | `[--table] [--analyze] [--keep-trees] [--label <l>]...` | Read-only status table + housekeeping; advances nothing. |
| [`/pipeline:run`](../skills/run/SKILL.md) | (none) | Deprecated alias forwarding to `/pipeline:status`. |
| [`/pipeline:fullsend`](../skills/fullsend/SKILL.md) | `[issue_numbers...] [--manual-merge] [--spawn] [--campaign] [--debug-first]` | Autonomous end-to-end run; flags position-independent. |
| [`/pipeline:campaign`](../skills/campaign/SKILL.md) | `[issue_numbers...] [--manual-merge] [--spawn] [--max-bc=N] [--max-ad=N]` | Standalone coordinated-leg campaign; equivalent to `/pipeline:fullsend --campaign` (same machinery). |
| [`/pipeline:classify-issue`](../skills/classify-issue/SKILL.md) | `<issue_number>` | Triage → PATH A/B/C/D; applies the path label, posts `## Classification`. |
| [`/pipeline:plan-issue`](../skills/plan-issue/SKILL.md) | `<issue_number>` | Produce + post `## Implementation Plan`; label `plan-pending`. |
| [`/pipeline:evaluate-issue-plan`](../skills/evaluate-issue-plan/SKILL.md) | `<issue_number>` | Independent plan review; label `plan-reviewed`. |
| [`/pipeline:execute-issue-plan`](../skills/execute-issue-plan/SKILL.md) | `<issue_number>` | Implement the approved plan; run from inside the feature worktree. |
| [`/pipeline:evaluate-issue-pr`](../skills/evaluate-issue-pr/SKILL.md) | `<issue_number> [--manual-merge]` | Independent PR review; auto-merges on green unless `--manual-merge`; run from inside the worktree. |
| [`/pipeline:create-issues`](../skills/create-issues/SKILL.md) | `[--confirm]` | Brainstorm → file issues; `--confirm` forces the gate on the single-standalone path. |
| [`/pipeline:analyze-issues`](../skills/analyze-issues/SKILL.md) | (none) | Read-only hygiene pass (dupes / tracker-fit / missing-label / supersession). |
| [`/pipeline:doctor`](../skills/doctor/SKILL.md) | `[--fix labels]` | Read-only install audit; `--fix labels` seeds canonical labels idempotently. |
| [`/pipeline:init`](../skills/init/SKILL.md) | (none) | Greenfield bootstrap (preflight → config → gitignore → label seed → doctor tail). |
| [`/pipeline:hotfix`](../skills/hotfix/SKILL.md) | `"<problem>" \| <issue-number> [--inline\|--subagent] [--auto-merge]` | Emergency-lane in-session worktree fix bypassing lifecycle gates. |
| [`/pipeline:tokenomics`](../skills/tokenomics/SKILL.md) | `[--limit N] [--since DATE] [--until DATE] [--per-day]` | Dogfood-only cost/latency report (default `--limit 50`). |
| [`/pipeline:worktree-sync`](../skills/worktree-sync/SKILL.md) | (none) | Sync untracked `.claude/` files to active worktrees + report setup health. |
| [`/pipeline:visual-proof-from-plan`](../skills/visual-proof-from-plan/SKILL.md) | (internal sub-skill, not a top-level command) | Browser-predicate verification invoked by execute-issue-plan and evaluate-issue-pr. |
| [`/pipeline:visualize`](../skills/visualize/SKILL.md) | `plan <file> \| recap [git-range] [--out <dir>]` | Render a plan file or a diff as one self-contained local HTML page and open it; no network, no upload. |
| [`/pipeline:evolve`](../skills/evolve/SKILL.md) | `start [--cycles N] \| stop \| pause \| resume \| status [--tracker N]` | Dogfood-only harness-evolve loop driver (observe → diagnose → file → fullsend → measure → decide) on the `evolve` branch, run from the loop clone. |

## Per-command flag detail

Only the load-bearing nuance is captured here; see each SKILL.md for the full spec.

### fullsend

- `--spawn` routes every path's execute (Step 6) and PR-eval (Step 7) through the tmux run-queue — purely additive; A/B/D execute inline by default, C is always queued.
- `--manual-merge` skips auto-merge (also settable per-issue via a `manual-merge` label).
- `--debug-first` forces every dispatched `/pipeline:plan-issue N` through plan-issue's diagnosis gate before drafting; without it the gate fires only for issues carrying the durable `needs-debug` label.
- Plan approval is an auto-gate governed by `PIPELINE_PLAN_GATE` (default `annotate`: one evaluate, a Revise binds its amendments into execute, no re-plan; `full`: evaluate → re-plan → re-evaluate, cap 3; `none`: skip). The resolver emits it as `GATE=<v>` on every plan-eval resolution.
- Headless launches (`PIPELINE_HEADLESS=true`, calibration, the evolve loop) run under `--permission-mode auto` with the `PermissionRequest` bridge (`hooks/permission-bridge.py`) as the escalation channel; `PIPELINE_HEADLESS_PERMISSIONS=bypass` restores the old skip-permissions flag for one run. Answer queued escalations with `scripts/permission-bridge.sh pending|answer <id> allow|deny`.
- `--campaign` wraps the slate in ordered per-path legs, capped by `PIPELINE_CAMPAIGN_MAX_BC` (default 2) / `PIPELINE_CAMPAIGN_MAX_AD` (default 5). Equivalent to the standalone `/pipeline:campaign` entry — same machinery; `--campaign` is NOT deprecated.
- All flags are position-independent and cannot collide with bare-integer issue numbers.

### campaign

- Standalone entry into the SAME coordinated-leg machinery as `/pipeline:fullsend --campaign` — the canonical leg-loop prose lives ONCE in `skills/fullsend/SKILL.md` `## Campaign mode`; this skill defers to it (no forked machinery, no drift).
- `--max-bc=N` / `--max-ad=N` override the per-leg `PIPELINE_CAMPAIGN_MAX_BC` / `PIPELINE_CAMPAIGN_MAX_AD` caps for that invocation.
- `--spawn` and `--manual-merge` compose exactly as under `--campaign`.

### status

- `--table` renders ONLY the status table and stops.
- `--analyze` delegates to `/pipeline:analyze-issues`.
- `--keep-trees` opts out of merged-worktree auto-cleanup for that invocation (flag-only — no config default).
- `--label <l>` (repeatable) scopes the status table to issues carrying ANY of the given labels — a UNION/OR, which differs from `gh issue list --label` (AND). Trackers are child-driven: a tracker survives only if >= 1 of its children survives. Flag-only — no `pipeline.config` default.

### create-issues

- `--confirm` forces the confirmation gate on the single-standalone auto-create path (one-off, no config key).
- Body markers: authoritative `<!-- pipeline:path=D -->` forces PATH D; advisory `<!-- pipeline:path-hint=A|B|C -->` is one prior that `classify-issue` may override (`D` is never a hint).

### tokenomics

- Dogfood-only.
- `--limit N` — window of most-recent merged PRs (default 50).
- `--since DATE` / `--until DATE` — restrict the cost/token tables to a `ts_start` date window (`YYYY-MM-DD`, inclusive).
- `--per-day` — walks the window day-by-day, emitting one report per day.

### hotfix

- Takes either a quoted `"<problem>"` (files a new issue) or an existing `<issue-number>`.
- `--inline` vs `--subagent` selects the fix transport.
- `--auto-merge` opts in to auto-merge (off by default — operator merges manually).

### visualize

- `plan <file>` renders a markdown plan; `recap [git-range]` renders a diff (default range resolved from the current branch against the base).
- `--out <dir>` overrides the output directory; the page inlines all CSS/SVG/data-URIs and never fetches from a CDN.

### evolve

- Dogfood-only; run from the evolve loop clone, never from the orchestrator checkout.
- `start [--cycles N]` runs cycles until the count is reached, the `paused` tracker label appears, or the diminishing-returns check fires; `stop` / `pause` / `resume` act on the tracker; `status [--tracker N]` prints the mode line plus the current cycle's `run-retro.sh` summary.
- Per-cycle retros land in `docs/retros/cycle-NN.md`; calibration artifacts in `docs/retros/calib/`. See [docs/calibration.md](calibration.md).

## Interaction surfaces

Beyond argv, commands read and write these shared surfaces.

### Labels

- **Lifecycle:** `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`.
- **Path labels:** `docs-only` (A), `multi-task` (C), `quick-fix` (D); default PATH B when none.
- **Control labels:** `manual-merge` (per-issue auto-merge opt-out), `tracker` (coordination issue, excluded from the action queue), `next` (routes the feature PR onto `PIPELINE_NEXT_BRANCH`; legacy alias `next-major-release`), `needs-debug` (plan-issue runs its diagnosis gate first), `needs-browser` (visual-proof lane).
- **Triage labels** (`PIPELINE_LABELS_*`, defaults `excluded` / `later` / `human` / `brainstorm`): shown in the status table, never entered into an autonomous run.
- Full flow: [docs/process-maps.md](process-maps.md).

### Config knobs

`pipeline.config.example` is authoritative for the full config surface. The user-facing knobs that change command behavior:

- `PIPELINE_BASE_BRANCH` — PR target branch (default `staging`). `PIPELINE_NEXT_BRANCH` / `PIPELINE_NEXT_LABEL` route `next`-labelled issues onto the next-integration branch; `PIPELINE_RELEASE_BRANCH` (default `main`) is the branch the promotion PR targets.
- `PIPELINE_CAMPAIGN_MAX_BC` / `PIPELINE_CAMPAIGN_MAX_AD` / `PIPELINE_CAMPAIGN_MAX_FOLD` — `--campaign` leg caps (default 2 / 5) and the end-of-campaign fold-wave ceiling (default 3).
- `PIPELINE_PLAN_GATE` — `annotate` (default) | `full` | `none` | `single` (legacy); see the fullsend bullets above.
- `PIPELINE_PATH_{A,B,C,D}_MODEL_EXECUTE` — execute-stage model per path; unset resolves to `opus` (#1186 / #1420 / #1428). `=sonnet` opts a path into the cheaper lane; on B and D the high-uncertainty and `needs-browser` carve-outs still pin `opus`, and `PIPELINE_PATH_B_ELIGIBLE_SCOPE` (`all` | `low-blast`) narrows which PATH B issues the knob applies to.
- `PIPELINE_PATH_C_MODEL_PLAN` (default `fable`), `PIPELINE_STAGE_MODEL_PLAN_EVAL` and `PIPELINE_STAGE_MODEL_PR_EVAL` (default `opus`) — stage model pins resolved by `scripts/resolve-stage-model.sh`; the high-uncertainty carve-out downgrades a Fable plan to `opus`, plan-eval never resolves below its producer, and an explicit pr-eval knob below the execute tier is honored with a stderr warning.
- `PIPELINE_TRUST_PROFILE` — `strict` (default) | `lean` (lean may skip plan-eval on non-high-uncertainty PATH A/D).
- `PIPELINE_USAGE_GATE_ENABLED` / `PIPELINE_USAGE_GATE_THRESHOLD_PCT` — the pause-5h / halt-7d gate (default on, 85%).
- `PIPELINE_HEADLESS` / `PIPELINE_HEADLESS_PERMISSIONS` / `PIPELINE_PERMISSION_BRIDGE_DIR` / `PIPELINE_PERMISSION_BRIDGE_TIMEOUT` — unattended-run contract and the permission bridge (defaults `false` / `auto` / empty / 840 s).
- `PIPELINE_CI_CHECK_ENABLED` / `PIPELINE_CI_FIX_LOOP_ENABLED` / `PIPELINE_CI_FIX_RETRY_BUDGET` — the pr-eval CI check and the red-CI re-dispatch loop (default on / on / 2).
- `PIPELINE_LOGS_ENABLED` / `PIPELINE_LOGS_RETENTION_DAYS` — gates tokenomics/observability logs (default `false`) and the `prune-logs.sh` window (default 30).
- `PIPELINE_RELEASE_PR_LABEL` — label identifying release-bot PRs to discover.

### Body markers

- `<!-- pipeline:path=D -->` — authoritative; forces PATH D.
- `<!-- pipeline:path-hint=A|B|C -->` — advisory; one prior in `classify-issue`'s score table, may be overridden (`D` is never a hint).

### Lifecycle scripts

The commands above delegate every decision that a permission classifier might misread to one opaque script with a one-line stdout contract:

- `scripts/transition-issue.sh` — the non-terminal lifecycle label flip (`plan-pending` → `plan-approved`, …); `scripts/finalize-issue-labels.sh` owns the terminal `merged` strip-set.
- `scripts/resolve-stage-model.sh` / `scripts/resolve-execute-dispatch.sh` — the single source for every stage's model, the plan gate value, and the execute carve-outs.
- `scripts/pr-eval-preflight.sh` — `PREFLIGHT=ok|block REASON=<token> PR=<n> FIXED=<csv|none>`; a `block` skips the model review.
- `scripts/auto-merge-gate.sh` — the greenlight decision after an approved pr-eval; `scripts/usage-gate.sh` — the `decision=proceed|skip|pause-5h|halt-7d` line read before every wave.

