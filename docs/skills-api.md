# Skills API reference

The exhaustive catalogue of pipeline slash commands — invocation form, args/flags, and interaction surfaces (labels, config knobs, body markers). For the curated "start here" set, see the [Canonical entry points](../README.md#canonical-entry-points) table in the README.

> **Source of truth is each `skills/<name>/SKILL.md`.** This reference *summarizes* the argv surface — it does not redefine behavior. When a flag changes, edit the SKILL.md (authoritative) and then this one line. Each subsection links its SKILL.md.

## Master table

| Command | Args / flags | Summary |
|---|---|---|
| [`/pipeline:status`](../skills/status/SKILL.md) | `[--table] [--analyze] [--keep-trees]` | Read-only status table + housekeeping; advances nothing. |
| [`/pipeline:run`](../skills/run/SKILL.md) | (none) | Deprecated alias forwarding to `/pipeline:status`. |
| [`/pipeline:fullsend`](../skills/fullsend/SKILL.md) | `[issue_numbers...] [--manual-merge] [--spawn] [--campaign]` | Autonomous end-to-end run; flags position-independent. |
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

## Per-command flag detail

Only the load-bearing nuance is captured here; see each SKILL.md for the full spec.

### fullsend

- `--spawn` routes every path's execute (Step 6) and PR-eval (Step 7) through the tmux run-queue — purely additive; A/B/D execute inline by default, C is always queued.
- `--manual-merge` skips auto-merge (also settable per-issue via a `manual-merge` label).
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

## Interaction surfaces

Beyond argv, commands read and write these shared surfaces.

### Labels

- **Lifecycle:** `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`.
- **Path labels:** `docs-only` (A), `multi-task` (C), `quick-fix` (D); default PATH B when none.
- **Control labels:** `manual-merge` (per-issue auto-merge opt-out), `tracker` (coordination issue, excluded from the action queue).
- Full flow: [docs/process-maps.md](process-maps.md).

### Config knobs

`pipeline.config.example` is authoritative for the full config surface. The user-facing knobs that change command behavior:

- `PIPELINE_BASE_BRANCH` — PR target branch.
- `PIPELINE_CAMPAIGN_MAX_BC` / `PIPELINE_CAMPAIGN_MAX_AD` — `--campaign` leg caps (default 2 / 5).
- `PIPELINE_LOGS_ENABLED` — gates tokenomics/observability logs.
- `PIPELINE_RELEASE_PR_LABEL` — label identifying release-bot PRs to discover.

### Body markers

- `<!-- pipeline:path=D -->` — authoritative; forces PATH D.
- `<!-- pipeline:path-hint=A|B|C -->` — advisory; one prior in `classify-issue`'s score table, may be overridden (`D` is never a hint).
