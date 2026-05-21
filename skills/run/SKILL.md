---
name: run
description: Check the status of the GitHub issue pipeline and advance the next stage. Run this at the start of any coding session to see what is ready and propose next actions. Usage: /pipeline:run
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Agent
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Pipeline Coordinator

## Pipeline utilities

| Script | Description |
|--------|-------------|
| `${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh <pr> <base>` | Retarget a PR's base branch with verify-retry-fail pattern (gh pr edit then REST API fallback) |

## Shortcuts

| Shortcut | Meaning |
|----------|---------|
| **full send** | Back-compat alias for `/pipeline:fullsend`. Delegates to that skill with the same argv. |
| `--analyze` | Read-only hygiene pass over the open-issue set. Surfaces likely duplicates and standalones that fit existing trackers. No mutations. See [Analyze mode (--analyze)](#analyze-mode---analyze) below. |

### Full Send — autonomous end-to-end execution

The autonomous flow lives in its own skill: **`/pipeline:fullsend`** (see `skills/fullsend/SKILL.md`).

For back-compat, when the user prompt to `/pipeline:run` contains the token `full send` / `full-send` / `fullsend` (case-insensitive), this skill MUST delegate by invoking:

`Skill(skill: "pipeline:fullsend", args: "<original argv: issue numbers + --manual-merge if present>")`

and then STOP. Do not duplicate the autonomous flow inline — the delegation is the only supported back-compat path.

## Analyze mode (--analyze)

Read-only hygiene pass over the open-issue set; no mutations. Full spec, helper invocation, subagent dispatch contract, and output tables in [references/analyze-mode.md](references/analyze-mode.md).

## Issue discovery

Pipeline issues are fetched dynamically from GitHub — not hardcoded. At the start of each run, fetch all open issues:

```bash
gh issue list --repo $PIPELINE_REPO --state open --json number,title,labels --limit 100
```

**Excluded labels:** Issues with the label `PIPELINE_LABELS_EXCLUDED` are skipped entirely. Issues with the label `PIPELINE_LABELS_LATER` are shown in the status table (stage = `PIPELINE_LABELS_LATER`) but are **not** proposed for any action. Issues with the label `PIPELINE_LABELS_HUMAN` are shown in the status table (stage = `PIPELINE_LABELS_HUMAN`) and are **never** included in autonomous full send — they require manual handling because they involve architecture decisions, cross-platform validation, production deploy risk, or other judgment that the autonomous pipeline shouldn't make. The user can still pick them up manually with `/pipeline:plan-issue` or `/pipeline:execute-issue-plan`. Issues with the label `PIPELINE_LABELS_BRAINSTORM` are shown in the status table (stage = `PIPELINE_LABELS_BRAINSTORM`) but are **not** proposed for any action — same handling as `PIPELINE_LABELS_LATER` / `PIPELINE_LABELS_HUMAN`. These represent open-ended discussion or architectural critique; the body is not yet a commit-to-act spec. All other open issues are pipeline candidates.

### Branch and worktree naming convention
- Branch: `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short)
- Worktree path: `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-<issue_number>-<slug>` (e.g., `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-25-gantt-contract-creation`)
- If an issue already has a branch (check `gh issue view N` body/comments or existing branches), use that branch name
- Issues that share a branch (noted in issue body or comments) should be grouped together
- **Commit messages must follow Conventional Commits** (see CLAUDE.md → Commit Conventions & Releases). release-please parses these to drive automated versioning and CHANGELOG generation. Use `feat:`, `fix:`, `chore:`, etc. with a scope when relevant (`feat(redline):`, `fix(email-pull):`).

## Label flow

```
(no label) → [classified: docs-only | multi-task | none] → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged → (cleaned up)
```

- `docs-only` / `multi-task` — PATH tag applied by classify-issue; persists through the rest of the lifecycle. Read by plan-issue (to emit PATH-aware Task 0/N), by spawn-claude.sh (to inject the path-specific execute skills), and by the enforce-path-c-delegation hook (to block direct orchestrator edits on multi-task issues).
- `plan-pending` — plan posted, awaiting evaluation
- `plan-reviewed` — evaluation posted, awaiting user approval
- `plan-approved` — user approved the plan; ready for execution
- `in-progress` — execution agent is implementing
- `pr-open` — PR created, awaiting evaluation/review/merge
- `merged` — PR merged, worktree ready for cleanup

## Worktree-only rule

**NEVER implement GitHub issue work directly on the current branch.** All issue-related changes — no matter how small — must go through a worktree, feature branch, and PR. This ensures the main working directory stays clean and every issue follows the full pipeline flow (worktree → branch → PR → merge → cleanup).

If the user asks to "just fix" an issue or work on it directly, remind them that pipeline issues require a worktree and propose setting one up.

## Steps

> **Invariant — prioritization first.** `/pipeline:run` MUST render the prioritization+grouping status table before any classify dispatch. Classification on the full ready set at startup is forbidden — classify runs only on the user-committed slate at step 6. This carries forward the `feedback_pipeline_run_prioritization_first` direction from auto-memory and is asserted by `tests/test-pipeline-run-no-upfront-classify.sh`. Do not regress.

0. **Housekeeping — branch check + sync worktrees + kill stale sessions**

   **First, confirm the orchestrator is on the configured base branch.** The base branch for all PRs is read from `pipeline.config` (`PIPELINE_BASE_BRANCH=$PIPELINE_BASE_BRANCH`). The orchestrator session should be on that branch so spawned worktrees inherit from it and PRs target it.

   ```bash
   EXPECTED_BASE="$PIPELINE_BASE_BRANCH"
   CURRENT_BRANCH=$(git branch --show-current)
   echo "Session base branch: ${EXPECTED_BASE} (orchestrator on: ${CURRENT_BRANCH})"
   ```

   If `CURRENT_BRANCH` does not equal `EXPECTED_BASE`:
   - Warn the user: **"Orchestrator is on `<CURRENT_BRANCH>` but the configured pipeline base is `<EXPECTED_BASE>`. Switch to `<EXPECTED_BASE>`? (yes / no)"**
   - If yes: `git checkout "${EXPECTED_BASE}" && git pull --quiet origin "${EXPECTED_BASE}"`
   - If no: abort the pipeline run — running on the wrong branch will cause PRs to target the wrong base and create orphan worktrees.

   Also print a reminder: *"PRs created by spawned agents will target `${EXPECTED_BASE}`. The enforce-base-branch hook blocks any `gh pr create` without `--base ${EXPECTED_BASE}`."*

   Then run the **base-branch hook wiring advisory**. This is defense-in-depth visibility: the `enforce-base-branch.py` PreToolUse hook is what makes the reminder above actually enforceable, and that hook must be registered in *either* the plugin manifest (`.claude-plugin/plugin.json`) *or* the consumer's local `.claude/settings.json`. If both surfaces silently drop the registration (e.g. a stale install, a hand-edited settings file, or a partial migration), `gh pr create` from spawned agents can escape `PIPELINE_BASE_BRANCH` and target the repo's default branch. The helper scans both files and prints a single `WARN:` line on stdout when neither wires the hook — otherwise it stays silent. The check is **advisory only and never aborts the run**; `/pipeline:run` cannot rewrite a consumer's `.claude/settings.json` (#215 tracks render-on-install). Surface the WARN to the user and continue.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-branch-hook-wiring.sh" \
     --plugin-manifest "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" \
     --consumer-settings ".claude/settings.json" \
     --expected-base "${EXPECTED_BASE}" || true
   ```

   Then, check for `next-major-release` issues in the open pipeline set. These should be processed from the `next` branch by convention:

   ```bash
   NEXT_ISSUES=$(gh issue list --repo $PIPELINE_REPO --state open \
     --label next-major-release --json number,title \
     --jq '.[] | "#\(.number) \(.title)"')
   if [ -n "$NEXT_ISSUES" ] && [ "$CURRENT_BRANCH" != "next" ]; then
     echo ""
     echo "WARNING: The following open issues are labeled 'next-major-release':"
     echo "$NEXT_ISSUES" | sed 's/^/  /'
     echo ""
     echo "These should be processed from the 'next' branch. You are currently on '$CURRENT_BRANCH'."
     echo "Switch to 'next' before proceeding (if you intend to work on those issues)."
   fi
   ```
   Do not auto-switch. Proceed with the run; the user decides.

   Then, if any worktrees exist, run the sync script to ensure all active worktrees have up-to-date CLAUDE.md files, `.claude/` settings, and hooks:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
   ```
   Report any fixes briefly.

   Then discover open release-bot PRs (release-please by default) so they can be surfaced in the status table and proposed/auto-merged in later steps. The helper lists PRs carrying the label configured by `PIPELINE_RELEASE_PR_LABEL` (default `autorelease: pending`):

   ```bash
   RELEASE_PRS=$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)
   ```

   Output schema, one line per PR: `pr=<num> ci=<pass|fail|pending> title=<title>`. Empty when no release PRs are open or `gh` is unavailable — degrade silently in that case.

   Then check for stale tmux sessions from previous pipeline runs. If a tmux `PIPELINE_TMUX_SESSION` session exists, kill any leftover queue runner and agent windows:
   ```bash
   # List all windows in the $PIPELINE_TMUX_SESSION session
   tmux list-windows -t $PIPELINE_TMUX_SESSION -F '#{window_name}' 2>/dev/null
   ```
   - Kill any `issue-*` windows (stale agent sessions from prior runs)
   - If window 0 is running a queue runner (`run-queue.sh`), send Ctrl-C to stop it
   ```bash
   # Kill stale agent windows
   for win in $(tmux list-windows -t $PIPELINE_TMUX_SESSION -F '#{window_name}' 2>/dev/null | grep '^issue-'); do
     tmux kill-window -t "$PIPELINE_TMUX_SESSION:${win}" 2>/dev/null || true
   done
   # Interrupt any running queue runner in the first window
   tmux send-keys -t $PIPELINE_TMUX_SESSION:0 C-c 2>/dev/null || true
   ```
   Report what was cleaned up, then proceed.

   Then, auto-close any tracker issue whose Rollout-sequence children are all closed. This is cheap (one `gh issue list` + one `gh issue view` per open tracker) and fail-soft — a non-zero exit from the helper is logged but never aborts the run:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
     echo "[run] WARN: auto-close-trackers.sh exited non-zero (continuing)"
   ```

1. **Discover pipeline issues** — fetch all open AND recently closed issues, and classify by label:
   ```bash
   gh issue list --repo $PIPELINE_REPO --state open --json number,title,labels --limit 100
   gh issue list --repo $PIPELINE_REPO --state closed --json number,title,labels --limit 20
   for wt in $(git worktree list --porcelain | awk '/^branch refs/{sub("refs/heads/","",$2); print $2}'); do
     gh pr list --repo $PIPELINE_REPO --head "$wt" --state merged --json number,headRefName --jq '.[] | {branch: .headRefName, pr: .number}'
   done
   git worktree list
   ```
   Classify each issue by its pipeline label (`plan-pending`, `plan-reviewed`, `plan-approved`, `in-progress`, `pr-open`). Issues with no pipeline label are in the `ready` stage. Skip issues labeled `PIPELINE_LABELS_EXCLUDED`. Issues labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM` are shown in the table but never proposed by full send (treat them like `PIPELINE_LABELS_LATER`).

   **Tracker issues are coordination artifacts**, not implementation work. They carry the `tracker` label and roll up child issues for visibility. The orchestrator excludes them from the action queue (never proposed for plan/execute) but surfaces them in the status table with `stage=tracker`. The filter block below partitions the issue list into `READY_ISSUES` (no pipeline-stage label AND no `tracker`/excluded/later/human label) and `TRACKER_ISSUES` (carry `tracker`). Assume `ISSUE_LIST_JSON` holds the output of `gh issue list ... --json number,title,labels --limit 100`.

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

   `READY_ISSUES` feeds the planning proposal in step 4. `TRACKER_ISSUES` feeds the status-table render in step 3 — those issues are displayed with `Stage=tracker` and never reach the classify/plan dispatch.

   Classification is deferred — see step 6 (Propose ONE action → planning branch) for the cache-checked dispatch that runs only on the user-committed slate.

   **Detect residual mismatch (audit only):** For each `ready` issue with a fresh classification, compare the cached comment's `recommended_path` against the current label-derived path (`A` if labeled `docs-only`, `C` if labeled `multi-task`, else `B`). They should match — classify-issue writes them together. If they diverge, it means a user hand-edited a label after the last classify run; flag as `⚠ mismatch` and include in the final report column. Do NOT block planning on a mismatch: the label is authoritative, the comment is history.

   **Detect cleanup candidates:** Cross-reference active worktrees (from `git worktree list`) with merged PRs. A worktree whose branch appears in the merged PR list is a cleanup candidate. Also check for `pr-open` issues whose PR has been merged (state = MERGED) — these need cleanup too.

2. **Check for dependency information** — read issue bodies for "blocked by #N" or similar dependency notes. An issue is blocked if the blocking issue's branch has not appeared in the merged PR list.

3. **Print a grouped status table** for all discovered pipeline issues — epics (tracker issues) at the top with their open children indented underneath, and orphans (non-tracker issues not listed under any tracker) at the bottom, bucketed by conventional-commit scope. The per-row line carries only priority + type prefix + title + stage; any non-default Target Base / Path / Blocked-by metadata is surfaced in a separate **NOTES** footer table.

   **Inputs.** This step consumes `TRACKER_ISSUES` and `READY_ISSUES` from the tracker-filter block in step 1, plus the open-issue label/title map fetched in step 1. For each tracker, run the shared parser to extract its checklist children:

   ```bash
   body=$(gh issue view "$tracker" --repo "$PIPELINE_REPO" --json body --jq .body)
   children=$(printf '%s\n' "$body" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/parse-tracker-children.sh" -)
   ```

   Intersect `children` with the set of open issues to get **open children**; closed children are omitted. Children referenced under any tracker's checklist are removed from the orphan candidate set; whatever remains in the non-tracker open set is an orphan.

   **Per-row metadata** (used by the renderer and the NOTES footer):
   - **Priority badge** from the `priority/P*` label (fallback `[--]`).
   - **Type prefix** parsed from the issue title via the regex `^(feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert|bug|brainstorm)\(([^)]+)\):` — group 2 is the **scope** used for orphan bucketing. Titles that don't match (or use `type:` without parens) land in the `(none / generic)` bucket.
   - **Stage** = current pipeline label (`plan-pending`, `plan-reviewed`, `plan-approved`, `in-progress`, `pr-open`, `merged`, or `ready`). Trackers render with `Stage=tracker`.
   - **Tags** = non-pipeline labels (i.e., NOT in `{plan-pending, plan-reviewed, plan-approved, in-progress, pr-open, merged, docs-only, multi-task, quick-fix, tracker, PIPELINE_LABELS_LATER, PIPELINE_LABELS_HUMAN, PIPELINE_LABELS_BRAINSTORM, PIPELINE_LABELS_EXCLUDED, priority/P*, next-major-release}`). Inline tags `(brainstorm)` / `(human-in-loop)` / `(later)` render alongside the title for issues carrying those labels.
   - **Target Base** = `next` if labels contain `next-major-release`, else `PIPELINE_BASE_BRANCH`. ≤10 chars, no truncation.
   - **Path** = winning letter under precedence A > D > C > B applied to the issue labels (`docs-only` → A, `quick-fix` → D, `multi-task` → C, else B). When two or more path labels coexist, suffix the winning letter with `!` to flag the collision. Specific glyphs by collision set:
     - `A` alone → `A`
     - `D` alone → `D`
     - `C` alone → `C`
     - `B` (no path label) → `B`
     - `A`+`D` → `A!` (A wins)
     - `A`+`C` → `A!` (existing rule preserved)
     - `D`+`C` → `D!` (D wins)
     - `A`+`D`+`C` → `A!` (A always wins)
     classify-issue writes labels directly, so label and recommendation always match after a classify run; the audit-only `⚠ mismatch` flag (see step 1) lives in the final report, not this column. If a ready issue has no path label AND no fresh `## Classification` comment, render the Path column as `?` (unknown) — classify will run on demand when the user commits to a slate.
   - **Blocked by** = `#N` references parsed from `blocked by #N` / `depends on #N` annotations in the issue body, when present.
   - **Attachments (`att=N`)** = count of files present at `$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-<N>/` at table-render time, computed as `ls -1 .claude/scratch/issue-<N>/ 2>/dev/null | wc -l`. Surfaced in the NOTES footer only when N>0 for at least one issue (consistent with other non-default columns). Sourced from on-disk state populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b; the run skill itself does NOT re-fetch attachments at discovery time.

   **Grouped layout (epics on top, orphans below).** Trackers appear first with their priority badge and conventional-title; each open child renders on its own line, indented eight spaces, with stage right-aligned in parentheses. A tracker with zero open children collapses to a single `(all children closed — pending auto-close)` line:

   _Example layout: see [references/status-table-layout.md](references/status-table-layout.md)._

   Path column shows `?` for ready issues not yet classified. Classification runs on demand when you commit to a slate.

   Orphan bucketing rules:
   - Bucket key is the conventional-commit `<scope>` token from the title regex above.
   - Scope buckets render in alphabetical order; `(none / generic)` always last.
   - Within a bucket, rows sort by priority tier (`P0` < `P1` < `P2` < `P3` < no-priority).

   **NOTES footer (non-default metadata only).** Surface Target Base / Path / Blocked-by only for issues whose values differ from the defaults (`Target Base = $PIPELINE_BASE_BRANCH`, `Path = B`, `Blocked by = none`). If every issue carries defaults, omit the entire block:

   _Example layout: see [references/status-table-layout.md](references/status-table-layout.md)._

   The `att` column is rendered only when at least one row has `att>0`; if every issue has zero on-disk attachments the column is suppressed (same convention as Target Base / Path / Blocked-by defaults). When the column is rendered, `att=0` rows still appear so the table stays rectangular.

   **Counts footer (always rendered).** A single trailing line of the form `N epics + N children + N orphans = N open`:

   _Example layout: see [references/status-table-layout.md](references/status-table-layout.md)._

   - `children` counts open children that appear under any tracker, deduplicated. If the same `#N` appears under two trackers, emit a `WARN: #N listed under multiple trackers: #A, #B` line above the counts and still count once.
   - `open` is the sum `epics + children + orphans` and must equal the open-issue total; a mismatch indicates a parser bug or a malformed tracker body.

   Tracker issues (from `TRACKER_ISSUES`) are rendered in the EPICS section with `Stage=tracker` and are never proposed for plan/execute. Their child-issue rollup is parsed from the body's `## Rollout sequence` checklist and rendered inline.

   **Release PRs row group.** If `RELEASE_PRS` (from step 0) is non-empty, render an additional table ABOVE the pipeline-issue table. Parse each line (`pr=<num> ci=<pass|fail|pending> title=<title>`) into a row:

   ```
   RELEASE PRs
   ================================================================
    PR     Title                              Stage             CI
   ----------------------------------------------------------------
    #201   chore(main): release 1.2.3         release-pending   pass
    #202   chore(main): release 1.3.0         release-pending   fail
   ================================================================
   ```
   `release-pending` is a **display-only** Stage value — it is NOT a GitHub label. The PR already carries `autorelease: pending` (release-please convention) and writing a second label would force consumer repos to define it. The Stage column is purely a rendering concern.

<!--
Priority order for "Propose ONE action" (highest → lowest):
  cleanup > in-progress > pr-open eval > plan-pending eval > plan-reviewed (await user)
  > plan-approved exec > merge release PR > ready planning.

Rationale: a release PR is the end of the release loop — it must NOT preempt
active feature work, but it should come BEFORE pulling in new ready work
(no point planning new issues if a release is queued and ready to merge).
-->

4. **Propose ONE action** based on state priority:
   - If any worktrees are cleanup candidates (merged PR with active worktree) → propose cleanup. List each candidate with its issue number and worktree path.
   - Else if any issues have `in-progress` → print which ones and note agents are working. Do not propose anything else.
   - Else if any issues have `pr-open`:
     - For each, check if the PR has an evaluation comment:
       ```bash
       PR_NUM=$(gh pr list --repo $PIPELINE_REPO --head <branch> --json number --jq '.[0].number')
       gh pr view $PR_NUM --repo $PIPELINE_REPO --json comments --jq '[.comments[] | select(.body | contains("## Evaluation"))] | length'
       ```
     - If any `pr-open` issues have NO evaluation comment → propose running `/pipeline:evaluate-issue-pr` for those issues (in their existing worktrees).
     - If all `pr-open` issues HAVE evaluation comments → remind user to review flagged PRs or note they're ready to merge.
   - Else if any issues have `plan-pending`:
     - **PATH D auto-flip (quick-fix bypass).** For each plan-pending issue labelled quick-fix, immediately emit gh issue edit $N --add-label plan-approved --remove-label plan-pending in this orchestrator turn:
       ```bash
       gh issue edit $N --repo $PIPELINE_REPO --add-label plan-approved --remove-label plan-pending
       ```
       Do NOT propose `/pipeline:evaluate-issue-plan` for PATH D issues; the evaluate-issue-plan stage is bypassed for D. After the flip, the issue advances to the `plan-approved` branch on the same or next ladder traversal. This is a discovery-driven flip — the run skill emits it whenever it observes a `plan-pending`+`quick-fix` issue, so it is idempotent across re-runs and works for both fresh plans and re-plans.
     - For each, check if the issue has a plan evaluation comment:
       ```bash
       gh issue view $N --repo $PIPELINE_REPO --json comments --jq '[.comments[] | select(.body | contains("## Plan Evaluation"))] | length'
       ```
     - If any `plan-pending` issues have NO plan evaluation → propose running `/pipeline:evaluate-issue-plan` for those issues.
     - If any `plan-pending` issues HAVE a plan evaluation AND user feedback comments (from rjskene) posted AFTER the evaluation → propose re-running `/pipeline:plan-issue N` to revise.
     - Otherwise, note they are awaiting user review.
   - Else if any issues have `plan-reviewed` → note they are awaiting user approval. Do not propose anything.
   - Else if any issues have `plan-approved` → propose setting up worktrees via `scripts/setup-worktree.sh` and printing launch instructions.
   - Else if any release PRs were discovered in step 0 with `ci=pass` → propose **"merge release PR #N"** (one proposal per green release PR). Show the PR title and CI status. On user confirmation, run `gh pr merge $PR_NUM --repo $PIPELINE_REPO --squash --delete-branch`. Release PRs with `ci=fail` or `ci=pending` are surfaced in the status table but NOT proposed — wait for CI to settle (or fix it) before merging.
   - Issues labeled `tracker` are shown in the table (stage=`tracker`) but never proposed for plan/execute — they are coordination rollups, not implementation work.
   - Else if any issues have no pipeline label and are not blocked and are not labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM`:
     - Before proposing planning: identify the unclassified subset of the proposed slate (ready issues lacking a fresh `## Classification` comment per the cache check below). The proposal MUST name the slate AND surface the unclassified subset by issue number — for example: "Propose planning for #292, #309, #316. Of these, #292 and #316 lack classification — `/pipeline:classify-issue` will run on those first." Classification only runs on user confirmation (step 6), not at proposal time. Issues labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM` are shown in the table but never proposed for autonomous action; surface them in the report with a note like "(human-in-loop, manual)" or "(brainstorm, manual)".
   - If all issues are merged/done → congratulate and exit.

5. **Wait for user confirmation** before taking any action. Never spawn agents without explicit user approval.

6. **On confirmation:**

   **IMPORTANT: All spawned `claude` agent processes MUST run in foreground (never `run_in_background`).** Background agents lose tool permissions and the user cannot monitor progress. The **queue runner script** (`run-queue.sh`) is a plain bash process that manages tmux windows — it does NOT need tool permissions. The orchestrator should launch the queue runner via `Bash` with `run_in_background: true` to receive a single completion notification instead of blocking (see sub-step 4 below for details).

   **For cleanup (merged PRs with active worktrees):**

   **Step A — Update CLAUDE.md files.** Before removing any worktree, review what the merged branch changed and update the CLAUDE.md documentation so it reflects the new state of the codebase. For each cleanup candidate:
   1. Get the diff of the merged branch against `PIPELINE_BASE_BRANCH`:
      ```bash
      gh pr view <pr_number> --repo $PIPELINE_REPO --json files --jq '.files[].path'
      gh pr diff <pr_number> --repo $PIPELINE_REPO
      ```
   2. Read the current CLAUDE.md files (check each file listed in: `PIPELINE_CONTEXT_FILES`).
   3. Determine if the changes introduced new routes, env vars, Python scripts, schema fields, CLI args, or other items that should be documented. If so, update the relevant CLAUDE.md file(s) in the **main repo** working directory.
   4. If multiple worktrees are being cleaned up, batch all CLAUDE.md updates into a single commit.
   5. Commit the CLAUDE.md updates (if any) to the current branch before proceeding:
      ```bash
      git add CLAUDE.md web/CLAUDE.md redline/CLAUDE.md
      git diff --cached --quiet || git commit -m "docs: update CLAUDE.md files after merging #<N>"
      ```

   **Step B — Run cleanup.** Then run the cleanup script for each candidate, capturing its stdout to a per-issue temp file so the orchestrator can parse the final `CLEANUP-SUMMARY:` line for batch tagging:
   ```bash
   mkdir -p /tmp/pipeline-cleanup
   OUT_LOG=$(mktemp /tmp/pipeline-cleanup/issue-<issue_number>-XXXX.log)
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue_number> | tee "$OUT_LOG"
   ```
   This script (in order): verifies the PR is merged/closed, closes the GitHub issue with the `merged` label, consolidates tool-use logs, removes the git worktree, and deletes the remote+local branch. Its final line is machine-readable: `CLEANUP-SUMMARY: issue=<N> pr=<PR|none> branch=<branch>`.

   If multiple worktrees need cleanup, run them sequentially, each to its own temp log.

   **Step B.5 — Create a checkpoint tag for the batch.** After every cleanup invocation finishes (including a batch of one), aggregate the `CLEANUP-SUMMARY` lines and create a single local checkpoint tag on the base branch:
   ```bash
   ISSUES=$(grep -h '^CLEANUP-SUMMARY:' /tmp/pipeline-cleanup/*.log \
     | sed -n 's/.*issue=\([0-9][0-9]*\).*/\1/p' | paste -sd ',' -)
   PRS=$(grep -h '^CLEANUP-SUMMARY:' /tmp/pipeline-cleanup/*.log \
     | sed -n 's/.*pr=\([0-9][0-9]*\).*/\1/p' | paste -sd ',' -)
   if [ -n "$ISSUES" ]; then
     PIPELINE_PROJECT_ROOT="$(pwd)" bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-checkpoint-tag.sh --issues "$ISSUES" --prs "$PRS"
   fi
   rm -f /tmp/pipeline-cleanup/*.log
   ```
   The tag is created **locally only** (never pushed) and named `checkpoint/YYYY-MM-DD-NN`. It annotates all issues + PRs in the batch so a later `git checkout -B pipeline checkpoint/<name>` (hook-safe rollback — `git reset --hard` is blocked by `block_deletions.py`) can roll back the entire cleanup if a regression surfaces. If zero cleanups succeeded (no `CLEANUP-SUMMARY` lines), skip the tag step.

   After all cleanups (and the checkpoint tag, if created), print a summary:
   ```
   CLEANUP COMPLETE
   ================================================================
   Issue  CLAUDE.md Updated?   Checkpoint Tag              Status
   ----------------------------------------------------------------
   #N     yes / no              checkpoint/YYYY-MM-DD-NN   Cleaned up
   ================================================================
   ```

   **For plan evaluation (plan-pending → plan-reviewed):** Run `/pipeline:evaluate-issue-plan N` for each issue needing evaluation. If multiple issues need evaluation, spawn one Agent per issue in parallel (foreground), each invoking `/pipeline:evaluate-issue-plan N`. The evaluate-issue-plan skill is read-only — it reads the plan comment and codebase, posts an evaluation comment, and updates labels. If the verdict is "Approve," the label changes to `plan-reviewed`. If "Revise," the label stays `plan-pending` and the evaluation comment explains what needs to change.

   **For planning (no label → plan-pending) or re-planning (plan-pending with user feedback):** **Classify the user-committed subset first.** For each issue in the committed slate, check whether a fresh `## Classification` comment exists (the comment's `createdAt > issue.updatedAt`). If any lack a fresh classification, dispatch one `Agent(subagent_type='general-purpose')` per stale/missing issue **in parallel** (single tool-call batch, one Agent per issue), each invoking `/pipeline:classify-issue N`. Each classify run writes the Classification comment AND applies the path label. Cached issues skip dispatch. Wait for all classify agents to complete before dispatching plan-issue. Caching semantics: GitHub's `updatedAt` bumps on body edits AND label changes, so the cache auto-invalidates. This is the same cache check that previously lived in step 1 discovery, relocated to fire only on the user-committed subset rather than the full ready set. Then: Run `/pipeline:plan-issue N` for each issue. If multiple issues need planning, spawn one Agent per issue in parallel (foreground), each invoking `/pipeline:plan-issue N`. If multiple issues share a branch (discovered from issue body/comments or matching branch names), plan them together in a single agent call. The plan-issue skill reads prior comments (including user feedback) and produces a revised plan when feedback exists.

   After all planning agents complete, verify each targeted issue has a plan comment:
   ```bash
   for N in <planned_issues>; do
     PLAN_COUNT=$(gh issue view $N --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     if [ "$PLAN_COUNT" -eq 0 ]; then
       echo "WARNING: Issue #$N has no plan comment. Re-running /pipeline:plan-issue $N."
       # Re-run plan-issue for this issue (max 1 retry)
     fi
   done
   ```
   If a re-run also fails to post the comment, flag the issue in the status report as "Plan failed — no comment posted" and do not advance it to evaluate-plan.

   **For PR evaluation (pr-open → evaluated):** Use the same launch flow as execution — the worktree already exists from execute-issue-plan, no setup needed.

   **Pre-spawn classifier (issue #218).** Before dispatching the PR evaluator, the orchestrator runs `bash ${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh <issue> <pr>` if `PIPELINE_EVAL_CLASSIFIER` is set. The classifier's stdout is parsed token-by-token; a `--container-mode=<name>` token causes the dispatch to fall through to `spawn-claude.sh --container-mode=<name>` regardless of PATH letter — container mode overrides PATH A inline subagent dispatch because container isolation cannot be honored inside an inline `Agent()` call. Any other `--flag=value` tokens are forwarded to `spawn-claude.sh` via `--classifier-passthrough=<token>`. If the classifier exit non-zero, the issue is skipped with the classifier's first stderr line surfaced as the reason; the orchestrator continues with the remaining issues. When `PIPELINE_EVAL_CLASSIFIER` is unset (default), this step is a no-op and PATH A / B / C routing below is unchanged.

   **Dispatch routing by path tier.** Read each PR-open issue's labels:
   - **PATH A** (`docs-only` label present): dispatch inline from this orchestrator session — no `spawn-claude.sh`, no `claude -p`, no tmux. Worktree was already created during execute-issue-plan, so reuse `<worktree-path>`:
     ```
     Agent(subagent_type='general-purpose',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1> (set to 1 if --manual-merge flag is in argv or the issue carries the manual-merge label).')
     ```
     Thread the `MANUAL_MERGE=1` token into the prompt verbatim when applicable; the evaluate-issue-pr skill treats the inline token identically to the `MANUAL_MERGE=1` env var that `spawn-claude.sh --manual-merge` sets.
   - **PATH B / PATH C** (no `docs-only` label): unchanged — proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh` below.
   - **PATH D**: PR evaluation stays `general-purpose` (NOT `tdd-implementer`) — inline dispatch shape identical to PATH A. Asymmetric by design: the evaluator role differs from the leaf-executor role; reusing `tdd-implementer` for eval would force red→green discipline on a workflow that does not need it.

   1. Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
   2. Launch via spawn-claude.sh with `--skill evaluate-issue-pr`:
      ```bash
      PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] --skill evaluate-issue-pr <worktree-path> <issue> <slug> <mode>
      ```
   3. For multiple issues, use the queue runner:
      ```bash
      PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] --skill evaluate-issue-pr <issue1> <issue2> ...
      ```
   4. The evaluate-issue-pr skill reviews the PR diff against the plan, makes minimal fixes if needed, and posts a verdict (Approved or Flagged). It does NOT merge — merge orchestration is handled by the pipeline (see step 7 below).

   **For execution (plan-approved → worktree setup):** For each approved issue's branch (deduplicated — issues sharing a branch get one worktree):

   **Dispatch routing by path tier.** After the worktree is set up (step 1 below), read each approved issue's labels:
   - **PATH A** (`docs-only` label present): dispatch inline from this orchestrator session — no `spawn-claude.sh`, no `claude -p`, no tmux. The worktree was created by `setup-worktree.sh`; only the agent launch is inline:
     ```
     Agent(subagent_type='general-purpose',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
   - **PATH B / PATH C** (no `docs-only` label): unchanged — proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh` below.
   - **PATH D** (quick-fix label present): dispatch inline from this orchestrator session via `Agent(subagent_type='tdd-implementer', description='execute-issue-plan #<N> (PATH D inline tdd)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')`. No spawn-claude.sh, no tmux, no run-queue.sh. Multiple D issues fan out as parallel inline Agent calls in a single tool-call batch. Note: the subagent_type uses the BARE `tdd-implementer` form (matching the existing PATH C plan-issue precedent and the agent-file declaration), NOT a `pipeline:` namespaced form.

   1. Run the setup script with the issue number:
      ```bash
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh <branch> <issue_number>
      ```
      This creates the worktree at `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-<issue_number>-<slug>`, copies `.claude/settings.local.json`, installs dependencies, and seeds the dev database.

   2. After ALL worktrees are set up, print a summary with the frontend URL for each issue. The frontend port is `$PIPELINE_FRONTEND_PORT_OFFSET + issue_number`:
      ```
      WORKTREES READY
      ================================================================
      Issue  Frontend URL                        Worktree Path
      ----------------------------------------------------------------
      #N     http://<server-ip>:<$PIPELINE_FRONTEND_PORT_OFFSET+N>        .claude/worktrees/$PIPELINE_WORKTREE_PREFIX-N-<slug>
      ================================================================
      ```
      To get your server's public IP, run: `curl -s ifconfig.me`

   3. Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
      If the user opts in to skip permissions, pass `--dangerously-skip-permissions` to the spawn script. This lets agents run without any permission prompts (all tool calls auto-approved).
      - **terminal** (default) — new Terminal.app window per issue with interactive Claude, auto-fires `/pipeline:execute-issue-plan N`. User monitors and interacts locally.
      - **tmux** — tmux windows in a `PIPELINE_TMUX_SESSION` session, auto-fires `/pipeline:execute-issue-plan N`
      - **remote-control** — `claude remote-control` servers, control from Claude mobile app or claude.ai/code. Only use this mode when the user explicitly says "remote-control".
      - **manual** — print instructions only

   4. **If user says tmux and there are 2+ issues** — use the queue runner to manage concurrency (max 3 at a time):
      ```bash
      PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
      ```
      Only pass `--skip-permissions` if the user opted in at step 3. The queue runner must be executed from inside a tmux session. If no tmux session exists, create one first:
      ```bash
      tmux new -s $PIPELINE_TMUX_SESSION -d
      ```
      Then launch the queue runner in a tmux window:
      ```bash
      tmux send-keys -t $PIPELINE_TMUX_SESSION "PIPELINE_REPO=\"$PIPELINE_REPO\" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ..." Enter
      ```
      The queue runner launches up to 3 agents at a time, polls for completion every 60s, and fills slots as agents finish. Override with `MAX_AGENTS=N` or `POLL_SECONDS=N` env vars.

      After launching, print:
      ```
      QUEUE STARTED (tmux mode, max 3 concurrent)
      ================================================================
      Issue  Worktree
      ----------------------------------------------------------------
      #N     .claude/worktrees/$PIPELINE_WORKTREE_PREFIX-N-<slug>
      ================================================================
      ```
      Add: "Queue runner is in tmux window 0. Agent windows appear as they launch."
      Add: "Monitor with: tmux attach -t $PIPELINE_TMUX_SESSION"

      **Waiting for queue completion:** After launching the queue runner, use `Bash` with `run_in_background: true` to wait:
      ```bash
      timeout 7200 bash -c 'tail -F "$(ls -t .claude/logs/queue-*.log | head -1)" | grep -m1 "EVENT: queue-complete"'
      ```
      The orchestrator receives a single completion notification when the queue finishes. Do NOT poll in a `while ... sleep ... grep` loop.

      If the queue runner crashes without emitting the completion event, the `timeout 7200` (2 hours) ensures the wait does not hang forever. On timeout, check the queue log and tmux session manually for errors.

      **Live per-agent events (optional):** To receive a notification each time an agent finishes, use `Monitor`:
      ```bash
      tail -F "$(ls -t .claude/logs/queue-*.log | head -1)" | grep --line-buffered "EVENT: agent-finished"
      ```

      **Automatic status updates:** The queue runner emits a rich status table (per-agent CPU%, memory, runtime, PR URLs) every `STATUS_INTERVAL` polls (default 3, so every 3 minutes at 60s poll interval). Configure with `STATUS_INTERVAL=N` env var. No manual setup needed — status output is built into the poll loop.


   5. **If user says tmux/terminal/remote-control and there is only 1 issue** — spawn directly:
      ```bash
      PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] <worktree-path> <issue_number> <slug> <mode>
      ```
      Where `<mode>` is `terminal`, `tmux`, or `remote-control`. Only pass `--dangerously-skip-permissions` if the user opted in at step 3.

   6. **If user says manual** — print manual instructions:
      ```
      Open each worktree in a terminal. They can run in parallel.

      Interactive: cd <worktree-path> && claude [--dangerously-skip-permissions] "/pipeline:execute-issue-plan N"
      Remote:      cd <worktree-path> && claude [--dangerously-skip-permissions] remote-control --name "issue-N-<slug>"
      Queue:       PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
      ```

### Anti-patterns

See [references/anti-patterns.md](references/anti-patterns.md) for the list of patterns to avoid when orchestrating the run loop.

7. **Merge orchestration** — after all evaluations complete, the pipeline handles merging. **Default is autonomous merge for the green subset** via the greenlight gate (`${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh`). The four greenlight conditions are: latest `## Evaluation` verdict is **Approved**; every `statusCheckRollup` entry has `conclusion == SUCCESS` (or the rollup is empty); `mergeable == MERGEABLE`; `mergeStateStatus == CLEAN`. Any one missing falls back to a `block-*` reason and requires manual `gh pr merge`.

   **Per-PR auto-merge loop.** For each PR labelled `pr-open`:

   1. **Already-merged short-circuit.** Check the latest `## Evaluation` PR comment body for the exact footer prefix `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at` (written by `evaluate-issue-pr` Step 11 on the green path). If present, mark the row `Auto-merged? = yes (eval)` in the report and skip this PR — it is already merged and closed.
   2. **Run the gate.** Source the helper and call it:
      ```bash
      source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
      REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")
      ```
   3. **On `green`:** run the conventional-title pre-validation below, then merge synchronously here (NOT `--auto`):
      ```bash
      gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --squash --delete-branch
      SHA=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json mergeCommit --jq .mergeCommit.oid)
      TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      FOOTER="Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at ${TS}"
      gh issue edit "$ISSUE" --repo "$PIPELINE_REPO" --add-label "merged" --remove-label "pr-open"
      if [ -n "$SHA" ]; then
        gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM} (${SHA}). ${FOOTER}"
      else
        gh issue close "$ISSUE" --repo "$PIPELINE_REPO" --comment "Merged via #${PR_NUM}. ${FOOTER}"
      fi
      ```
      Mark the row `Auto-merged? = yes (step8)`.
   4. **On any `block-*` reason:** mark the row `Auto-merged? = no (${REASON})` and leave the PR for manual merge by the user. Do NOT flip labels. Do NOT close the issue.

   Release-please PRs are out of scope here — they continue to flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b above, unchanged. The opt-outs are: `FULL SEND --manual-merge`, `/pipeline:evaluate-issue-pr N --manual-merge`, or the `manual-merge` label on the issue.

   The conventional-title pre-validation runs before any merge call regardless of the auto/manual path. It is informational at the batch level and enforced per-PR in sub-step 4 below.

   ```bash
   # Uses canonical regex from scripts/check-conventional-title.sh — see Issue #45.
   source $CLAUDE_PLUGIN_ROOT/scripts/check-conventional-title.sh
   echo "=== Pre-merge PR title validation ==="
   for PR_NUM in $(gh pr list --repo $PIPELINE_REPO --state open --json number --jq '.[].number'); do
     PR_TITLE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json title --jq '.title')
     if ! check_conventional_title "$PR_TITLE"; then
       echo "  ⚠ PR #$PR_NUM: $PR_TITLE"
     else
       echo "  ✓ PR #$PR_NUM: $PR_TITLE"
     fi
   done
   ```

   Then:
   1. For each approved PR, detect its base branch:
      ```bash
      gh pr view $PR_NUM --repo $PIPELINE_REPO --json baseRefName --jq '.baseRefName'
      ```
   1b. Verify and retarget if needed — compare the PR's current base with the expected base from the worktree metadata:
      ```bash
      EXPECTED_BASE=$(cat <worktree-path>/.claude/base-branch 2>/dev/null || echo "$PIPELINE_BASE_BRANCH")
      ACTUAL_BASE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json baseRefName --jq '.baseRefName')
      if [ "$ACTUAL_BASE" != "$EXPECTED_BASE" ]; then
        PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE
      fi
      ```
      If `retarget-pr.sh` exits non-zero, stop the merge sequence and report the failure.
   2. Check for merge conflicts:
      ```bash
      gh pr view $PR_NUM --repo $PIPELINE_REPO --json mergeable --jq '.mergeable'
      ```
   3. If conflicts exist, attempt rebase in the worktree:
      ```bash
      cd <worktree-path>
      BASE_BRANCH=$(cat .claude/base-branch 2>/dev/null || echo "$PIPELINE_BASE_BRANCH")
      git fetch origin "$BASE_BRANCH"
      git rebase "origin/$BASE_BRANCH"
      ```
      - If rebase succeeds: run tests, force-push with `--force-with-lease`, retry merge
      - If conflicts are complex: abort rebase, flag for user review, skip this PR
   4. Merge PRs sequentially to avoid cascading conflicts. Before each merge, validate the PR title against the Conventional Commits format — release-please reads the squash commit on merge, so a non-conforming title breaks automated versioning and CHANGELOG generation.

      ```bash
      # Validate PR title against Conventional Commits format.
      # Uses canonical regex from scripts/check-conventional-title.sh — see Issue #45.
      source $CLAUDE_PLUGIN_ROOT/scripts/check-conventional-title.sh
      PR_TITLE=$(gh pr view $PR_NUM --repo $PIPELINE_REPO --json title --jq '.title')
      if ! check_conventional_title "$PR_TITLE"; then
        echo "⚠ PR #$PR_NUM title does not match conventional commit format: $PR_TITLE"
        echo "  Expected: type(scope): description  (e.g. feat(web): add modal component)"
        # Propose a reword based on the issue title/body, then apply with:
        # gh pr edit $PR_NUM --repo $PIPELINE_REPO --title "<type>(<scope>): <summary>"
      fi
      ```

      - **Interactive mode:** if validation fails, print the warning, propose a reword derived from the PR's issue title/body, and ask the user to confirm or provide an alternative. If the user confirms (or supplies one), apply via `gh pr edit $PR_NUM --repo $PIPELINE_REPO --title "..."` and proceed. If the user declines, skip the merge for this PR and flag it in the final report.
      - **Full send (autonomous mode):** auto-propose a reword from the PR's issue title/body, apply it with `gh pr edit`, and proceed without blocking. If a valid reword cannot be determined, skip the PR and flag it in the final report.

      Once the title passes validation, run the merge:
      ```bash
      gh pr merge $PR_NUM --repo $PIPELINE_REPO --squash --delete-branch
      gh issue edit <N> --repo $PIPELINE_REPO --add-label "merged" --remove-label "pr-open"
      gh issue close <N> --repo $PIPELINE_REPO
      ```
   5. If a merge fails, stop and report the failure. Do not continue merging remaining PRs (they may depend on the failed one).

8. **After agents complete** (or after merge orchestration), report results and tell the user what to do next (review plans on GitHub, merge PRs, etc).
