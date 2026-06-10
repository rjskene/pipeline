---
name: status
description: Read-only status and reporting for the GitHub issue pipeline. Renders the prioritization+grouping status table so you can see what is ready, in-progress, and awaiting review. Does not dispatch or merge. Usage: /pipeline:status
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash blocks below reference `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Pipeline Status

## What `/pipeline:status` does

Read-only survey: `housekeeping → discover → status table`. The orchestrator surveys open issues, renders the prioritization+grouping status table, and reports. It does NOT propose actions, dispatch agents, or merge PRs — autonomous advancement lives in `/pipeline:fullsend`.

## Canonical entry points

- `/pipeline:status` — read-only **status and reporting** survey (this skill). Renders the prioritization+grouping status table; never dispatches or merges.
- `/pipeline:fullsend` — autonomous **end-to-end** execution (`skills/fullsend/SKILL.md`): classify → plan → evaluate plan → execute → evaluate PR → auto-merge greenlit PRs without intermediate confirmations.

PATH labels (A=docs-only, B=standard, C=multi-task, D=quick-fix) are owned by `skills/classify-issue/SKILL.md`; the lifecycle ASCII ladder lives in `docs/process-maps.md`. This skill references them by letter without redefining.

## Prioritization-first invariant

> **Invariant — prioritization first.** `/pipeline:status` MUST render the prioritization+grouping status table as its primary output. This carries forward the `feedback_pipeline_run_prioritization_first` direction from auto-memory and is asserted by `tests/test-pipeline-run-no-upfront-classify.sh`. Do not regress.

## Analyze mode (--analyze)

When `--analyze` appears anywhere in the argv to `/pipeline:status`, this skill MUST delegate by invoking `Skill(skill: "pipeline:analyze-issues")` and then STOP. Do not duplicate the analyze flow inline — the delegation is the only supported path. Full spec: [skills/analyze-issues/SKILL.md](../analyze-issues/SKILL.md).

## Table-only mode (--table)

When `--table` appears anywhere in the argv to `/pipeline:status`, this skill MUST render ONLY the status table via the Step 3 `scripts/render-status-table.sh` block and then STOP — skip housekeeping (Step 0), discovery prose narration, dependency reads, prioritization/grouping commentary, and any proposals. The status table is the sole output.

## Auto-cleanup mode (--keep-trees)

When a merged PR still has an active worktree, `/pipeline:status` **auto-proceeds** the cleanup during Step 0 housekeeping — **before discovery**, as a **non-blocking** tail pass that never preempts feature work — WITHOUT a confirmation gate. This is safe by construction: `cleanup-worktree.sh` already gates every destructive op on `PR state == MERGED`, and the destructive worktree-remove + branch-delete remain subject to the existing `ALLOW_DELETIONS` gate (`block_deletions.py` / `sync-worktrees.sh`). No second gate is added. The batch `create-checkpoint-tag.sh` (local-only `checkpoint/YYYY-MM-DD-NN` tag) is the rollback point for the whole auto-cleaned batch.

When `--keep-trees` appears **anywhere in the argv**, the auto-cleanup is **SUPPRESSED** for that invocation: candidates are still detected and surfaced (status table), they are just NOT acted on. The flag is **per-invocation only — there is NO persistent `pipeline.config` default** (precedent: `--analyze`). Auto-cleanup is non-blocking and never gate-fatal.

## Shortcuts

| Shortcut | Meaning |
|----------|---------|
| `--table` | Render ONLY the status table (Step 3) and STOP — skip housekeeping, discovery, and grouping. |
| `--analyze` | Read-only hygiene pass — delegates to /pipeline:analyze-issues. See [skills/analyze-issues/SKILL.md](../analyze-issues/SKILL.md). |
| `--keep-trees` | Opt out of auto-cleanup for this invocation — merged-worktree cleanup candidates are still surfaced but NOT acted on. Flag-only; no pipeline.config default. |

Autonomous advancement lives in /pipeline:fullsend — this command does not delegate full send.

## Pipeline utilities

| Script | Description |
|--------|-------------|
| `${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh <pr> <base>` | Retarget a PR's base branch with verify-retry-fail pattern (gh pr edit then REST API fallback) |

## Issue discovery

Pipeline issues are fetched dynamically from GitHub — not hardcoded. At the start of each run, fetch all open issues:

```bash
gh issue list --repo $PIPELINE_REPO --state open --json number,title,labels --limit 100
```

**Excluded labels.** Issues with `PIPELINE_LABELS_EXCLUDED` are skipped entirely. Issues with `PIPELINE_LABELS_LATER` are shown in the status table (stage = `PIPELINE_LABELS_LATER`) but are not proposed for any action. Issues with `PIPELINE_LABELS_HUMAN` are shown (stage = `PIPELINE_LABELS_HUMAN`) and never enter autonomous full send — they require manual handling because they involve architecture decisions, cross-platform validation, production deploy risk, or other judgment the autonomous pipeline shouldn't make. The user can still pick them up manually. Issues with `PIPELINE_LABELS_BRAINSTORM` are shown (stage = `PIPELINE_LABELS_BRAINSTORM`) and treated the same — the body is not yet a commit-to-act spec.

### Branch and worktree naming convention

- Branch: `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short).
- Worktree path: `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-<issue_number>-<slug>` (e.g., `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-25-gantt-contract-creation`).
- If an issue already has a branch (check `gh issue view N` body/comments or existing branches), use that branch name.
- Issues that share a branch should be grouped together.
- **Commit messages must follow Conventional Commits** (see CLAUDE.md → Commit Conventions & Releases). release-please parses these to drive automated versioning and CHANGELOG generation. Use `feat:`, `fix:`, `chore:`, etc. with a scope when relevant (`feat(redline):`, `fix(email-pull):`).

## Label flow

```
(no label) → [classified: docs-only | multi-task | none] → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged → (cleaned up)
```

- `docs-only` / `multi-task` — PATH tag applied by classify-issue; persists through the rest of the lifecycle. Read by plan-issue (to emit PATH-aware Task 0/N), by spawn-claude.sh under `--spawn` (the legacy transport — to inject the path-specific execute skills; the default `multi-task` execute is the inline orchestrator-owned per-leaf-worktree fan-out), and by the enforce-path-c-delegation hook (to block direct orchestrator edits on multi-task issues).
- `plan-pending` — plan posted, awaiting evaluation.
- `plan-reviewed` — evaluation posted, awaiting user approval.
- `plan-approved` — user approved the plan; ready for execution.
- `in-progress` — execution agent is implementing.
- `pr-open` — PR created, awaiting evaluation/review/merge.
- `merged` — PR merged, worktree ready for cleanup.

## Worktree-only rule

**NEVER implement GitHub issue work directly on the current branch.** All issue-related changes — no matter how small — must go through a worktree, feature branch, and PR. This keeps the main working directory clean and ensures every issue follows the full pipeline flow (worktree → branch → PR → merge → cleanup).

If the user asks to "just fix" an issue or work on it directly, remind them that pipeline issues require a worktree and that autonomous advancement runs through `/pipeline:fullsend`.

## Status table

Rendering is delegated to `scripts/render-status-table.sh`; the renderer is the single source of truth for column widths, ordering, header lines, and footer formats — future tweaks ship as script changes plus golden-file updates, not prompt edits. Full input-file assembly, renderer invocation, and a labeled ASCII example (release-PR row, dated header, tracker section, orphan section, NOTES block, counts footer) in [references/status-table.md](references/status-table.md).

Path column shows `?` for ready issues not yet classified — classification runs on demand in `/pipeline:fullsend` when a slate is committed, not here.

The non-default NOTES footer now surfaces `needs-debug` as a `Dbg` column — a per-issue durable signal alongside Target Base / Path / Blocked by (cell value `yes` when the issue carries the `needs-debug` label, else `--`).

## Steps

0. **Housekeeping** — concerns covered before any discovery: orchestrator branch check, base-branch hook wiring advisory, `next-major-release` warning, worktree sync, release-PR discovery, stale tmux cleanup, auto-close trackers, reap stale visual-proof servers, and auto-cleanup of merged worktrees (unless `--keep-trees`). Full detail in [references/housekeeping.md](references/housekeeping.md). **Auto-cleanup placement:** detect cleanup candidates inline here (reuse the per-worktree merged-PR loop — `gh pr list --head <wt> --state merged` — so detection does not depend on Step 1 ordering), then run cleanup as Step 0's NON-BLOCKING tail pass. When `--keep-trees` is in argv, SKIP the auto-cleanup (candidates are still detected and surfaced downstream in the status table, just not acted on). The branch check must use `git pull --quiet origin "${EXPECTED_BASE}"` (quiet flag is required so the orchestrator does not pull the fast-forward file list into context). Discover release PRs with `list-release-prs.sh` (which lists PRs carrying the label configured by `PIPELINE_RELEASE_PR_LABEL`, default `autorelease: pending`), auto-close finished trackers, sync worktrees, and reap stale visual-proof servers — all wrapped with `PIPELINE_REPO=` per Issue #288:

   ```bash
   RELEASE_PRS=$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
     echo "[status] WARN: auto-close-trackers.sh exited non-zero (continuing)"
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
   # Reap stale visual-proof servers (orphaned python http.servers whose
   # worktree has been pruned). Housekeeping; never gate-fatal. See #517.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/reap-stale-visual-proof-servers.sh" || true
   # Rolling-window usage read-out (dogfood-only, #725). READ-ONLY advisory
   # over the gated agent-cost capture — relay its single read-out line so the
   # operator sees window-usage / headroom / throttle-ETA. Never gate-fatal;
   # emits SKIP_LOGGING_DISABLED when logs are off and a `disabled (... unset)`
   # line when the cap is unset. No hold/queue/pacing is performed (#725).
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_LOGS_ENABLED="$PIPELINE_LOGS_ENABLED" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-surface.sh" || true
   # Usage gate (#969) — ADVISORY-ONLY relay: report the single decision line.
   # Status is read-only: it NEVER pauses, schedules, or stops on the gate.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true
   ```

   Output schema, one line per PR: `pr=<num> ci=<pass|fail|pending> title=<title>`. Empty when no release PRs are open. Release PRs are surfaced in the status table as a Release-PR block with Stage column rendering as the display-only literal `release-pending` (NOT a real GitHub label) and never enter the issue lifecycle.

1. **Discover pipeline issues** — fetch all open AND recently closed issues, plus per-worktree merged PRs:

   ```bash
   gh issue list --repo $PIPELINE_REPO --state open --json number,title,labels --limit 100
   gh issue list --repo $PIPELINE_REPO --state closed --json number,title,labels --limit 20
   for wt in $(git worktree list --porcelain | awk '/^branch refs/{sub("refs/heads/","",$2); print $2}'); do
     gh pr list --repo $PIPELINE_REPO --head "$wt" --state merged --json number,headRefName --jq '.[] | {branch: .headRefName, pr: .number}'
   done
   git worktree list
   ```

   Classify each issue by pipeline label (`plan-pending`, `plan-reviewed`, `plan-approved`, `in-progress`, `pr-open`). Issues with no pipeline label are in the `ready` stage. Skip issues labeled `PIPELINE_LABELS_EXCLUDED`. Issues labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM` are shown in the table but never proposed by full send (treat them like `PIPELINE_LABELS_LATER`).

   **Tracker issues are coordination artifacts**, not implementation work. Partition the issue list with the tracker filter below; full audit-only notes (residual-mismatch detection, cleanup-candidate detection) in [references/tracker-filter.md](references/tracker-filter.md).

   ```bash
   # BEGIN-TRACKER-FILTER
   # Required env: ISSUE_LIST_JSON (output of `gh issue list ... --json number,title,labels`).
   # Emits: READY_ISSUES (space-separated numbers), TRACKER_ISSUES (space-separated numbers).
   STAGE_LABELS='plan-pending|plan-reviewed|plan-approved|in-progress|pr-open|merged'
   SKIP_LABELS="tracker|$PIPELINE_LABELS_EXCLUDED|$PIPELINE_LABELS_LATER|$PIPELINE_LABELS_HUMAN|$PIPELINE_LABELS_BRAINSTORM"
   READY_ISSUES=$(echo "$ISSUE_LIST_JSON" | jq -r --arg stage "$STAGE_LABELS" --arg skip "$SKIP_LABELS" '
     .[] | select(
       ([.labels[].name] | any(test("^(" + $stage + ")$"))) | not
     ) | select(
       ([.labels[].name] | any(test("^(" + $skip  + ")$"))) | not
     ) | .number
   ' | tr '\n' ' ')
   TRACKER_ISSUES=$(echo "$ISSUE_LIST_JSON" | jq -r '
     .[] | select([.labels[].name] | any(. == "tracker")) | .number
   ' | tr '\n' ' ')
   # END-TRACKER-FILTER
   ```

2. **Check for dependency information** — read issue bodies for "blocked by #N" or similar dependency notes. An issue is blocked if the blocking issue's branch has not appeared in the merged PR list.

3. **Render the status table** — invoke `scripts/render-status-table.sh` with the three input files described in [references/status-table.md](references/status-table.md). The renderer is the single deterministic source of truth for the table (golden-file guaranteed); the status skill is NOT the source of truth for layout. Bash tool stdout alone is hidden inside a folded tool call, so after invoking the renderer the orchestrator MUST paste the renderer's EXACT stdout verbatim into a single fenced code block in its next assistant message — byte-for-byte, nothing added or removed around the rows. **Contract violation:** reformatting the table, restating rows in prose, narrating per-row, or substituting a "here's the gist" summary for the rendered output. Do NOT re-render the table from JSON in the model and do NOT route it through a file — paste the renderer's stdout verbatim. Attachments (`att` column) come from `$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-<N>/`, populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b — the status skill does NOT re-fetch.

   **trackers.json build contract.** The renderer expects `--trackers` to be a JSON object `{"<num>": "<body>", ...}`, NOT an array of issue objects. As of #416 the renderer fails loud (exit 2) on wrong shape, but the operator must still build the map correctly. Use this block — lifted from [references/status-table.md](references/status-table.md) so SKILL.md can be read linearly:

   ```bash
   # issues.json — re-fetch with body so NOTES blocked-by parsing works.
   ISSUES_JSON=$(mktemp)
   gh issue list --repo "$PIPELINE_REPO" --state open \
     --json number,title,labels,body,updatedAt --limit 100 > "$ISSUES_JSON"

   # trackers.json — JSON OBJECT keyed by tracker number, value = body.
   TRACKERS_JSON=$(mktemp); echo '{}' > "$TRACKERS_JSON"
   for tracker in $TRACKER_ISSUES; do
     body=$(gh issue view "$tracker" --repo "$PIPELINE_REPO" --json body --jq .body)
     TRACKERS_JSON_NEXT=$(jq --arg k "$tracker" --arg v "$body" '. + {($k): $v}' "$TRACKERS_JSON")
     printf '%s' "$TRACKERS_JSON_NEXT" > "$TRACKERS_JSON"
   done
   ```

   See `references/status-table.md` for the full contract (release-prs feed, invocation block, NOTES rendering, example output).

   Path column shows `?` for ready issues not yet classified — classification is a `/pipeline:fullsend` concern, not a status concern.

   This is the terminal output of `/pipeline:status`. After pasting the rendered table (plus the prioritization/grouping read below), STOP — do not propose actions, dispatch agents, or merge.

### Prioritization and grouping

The status table is rendered sorted by tracker/scope/label so the operator can read the prioritized, grouped picture at a glance. This skill surfaces that picture; it does not act on it. When the operator wants to advance issues, they invoke `/pipeline:fullsend`.

### Anti-patterns

See [references/anti-patterns.md](references/anti-patterns.md) for the list of patterns to avoid when reading the status surface.
