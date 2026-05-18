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

Read-only hygiene pass over the open-issue set. Surfaces likely duplicates and standalones that fit existing trackers so the user can decide whether to close, merge, or re-bucket before the next full send. **No mutations.** Decision-support only — the user reads the digest and runs the suggested `gh` commands manually.

**Trigger.** Parse `--analyze` from any argv position (same pattern as `--manual-merge`). The token must not collide with bare issue numbers, so any token starting with `--` is filtered out of the issue-number list. Parser sketch:

```bash
ANALYZE=0
for arg in "$@"; do
  case "$arg" in
    --analyze) ANALYZE=1 ;;
  esac
done
```

**Branch behavior.** When `ANALYZE=1`, this skill SKIPS classify / plan / execute / eval entirely and exits cleanly after printing the digest. No labels are applied, no comments are posted, no PRs are opened, no worktrees are created. The session is fully read-only.

**Stage 1 — heuristic shortlist.** Run the deterministic shell helper and capture its single-line stdout as the shortlist path:

```bash
SHORTLIST_PATH=$(bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/analyze-issues.sh")
```

The helper writes JSON to `.claude/logs/analyze-shortlist-<ISO>.json` with three keys, `duplicate_pairs`, `tracker_fits`, and `missing_label_candidates`, each capped at 20 entries. The path is the only stdout line.

The `missing_label_candidates` entries are produced purely mechanically — they flag issues lacking a `priority/P*` label, a `docs-only`/`multi-task` path label, or any pipeline-stage/classification label (with a 24h age gate to skip just-filed issues; configurable via `PIPELINE_ANALYZE_MIN_AGE_HOURS`). No subagent confirmation is needed for these — the suggested `gh issue edit` command is rendered directly from the JSON row.

**Stage 2 — subagent dispatch.** Hand the shortlist to a general-purpose subagent which confirms / denies each LLM-required candidate and synthesizes the suggested `gh` command. Verbatim block:

```
Agent(subagent_type='general-purpose',
      description='analyze open-issue hygiene shortlist',
      prompt='Read shortlist at <SHORTLIST_PATH>. The JSON has three keys:
              duplicate_pairs, tracker_fits, missing_label_candidates.

              For each duplicate-pair row, run gh issue view <a> --json
              title,body and gh issue view <b> --json title,body;
              confirm/deny duplication, assign confidence (high|medium|low),
              write a one-line rationale, and synthesize the gh command.

              For each tracker-fits row, run gh issue view <issue> and
              gh issue view <tracker>; confirm/deny fit, same fields.

              For each missing_label_candidates row, NO per-issue
              gh issue view confirmation is required — the signal is
              purely label-presence-based. Pass the row straight through
              to the rendered table and synthesize the suggested
              gh issue edit command from the .missing array (e.g.
              `gh issue edit <N> --add-label priority/P2` when "priority"
              appears in .missing).

              Output ONLY the three markdown tables defined in
              skills/run/SKILL.md analyze-mode section. Omit a table
              entirely if it has zero high|medium findings (for the LLM-
              classified categories) or zero rows (for missing-label).
              No mutations.')
```

Substitute `<SHORTLIST_PATH>` with the path captured in Stage 1.

**Stage 3 — output contract.** The subagent prints up to three markdown tables to the orchestrator conversation. If a category has zero high|medium findings (LLM-classified) or zero rows (missing-label), its table is omitted (no empty noise).

```
## Duplicate candidates
| Pair | Confidence | Reason | Suggested action |
|------|------------|--------|-------------------|

## Standalones that fit an existing tracker
| Issue | Tracker | Confidence | Reason | Suggested action |
|-------|---------|------------|--------|-------------------|

## Issues missing labels
| Issue | Missing | Suggested action |
|-------|---------|-------------------|
```

Omit the `## Issues missing labels` section entirely if `missing_label_candidates` is empty — same convention as the other two tables.

**Constraints.** No mutations. No auto-close, no auto-label, no auto-comment. The pipeline does not run `gh issue close`, `gh issue edit`, or `gh issue comment` from this branch. The user reads the digest and decides what to act on.

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

0. **Housekeeping — branch check + sync worktrees + kill stale sessions**

   **First, confirm the orchestrator is on the configured base branch.** The base branch for all PRs is read from `pipeline.config` (`PIPELINE_BASE_BRANCH=$PIPELINE_BASE_BRANCH`). The orchestrator session should be on that branch so spawned worktrees inherit from it and PRs target it.

   ```bash
   EXPECTED_BASE="$PIPELINE_BASE_BRANCH"
   CURRENT_BRANCH=$(git branch --show-current)
   echo "Session base branch: ${EXPECTED_BASE} (orchestrator on: ${CURRENT_BRANCH})"
   ```

   If `CURRENT_BRANCH` does not equal `EXPECTED_BASE`:
   - Warn the user: **"Orchestrator is on `<CURRENT_BRANCH>` but the configured pipeline base is `<EXPECTED_BASE>`. Switch to `<EXPECTED_BASE>`? (yes / no)"**
   - If yes: `git checkout "${EXPECTED_BASE}" && git pull origin "${EXPECTED_BASE}"`
   - If no: abort the pipeline run — running on the wrong branch will cause PRs to target the wrong base and create orphan worktrees.

   Also print a reminder: *"PRs created by spawned agents will target `${EXPECTED_BASE}`. The enforce-base-branch hook blocks any `gh pr create` without `--base ${EXPECTED_BASE}`."*

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
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
   ```
   Report any fixes briefly.

   Then discover open release-bot PRs (release-please by default) so they can be surfaced in the status table and proposed/auto-merged in later steps. The helper lists PRs carrying the label configured by `PIPELINE_RELEASE_PR_LABEL` (default `autorelease: pending`):

   ```bash
   RELEASE_PRS=$(bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)
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
   bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
     echo "[run] WARN: auto-close-trackers.sh exited non-zero (continuing)"
   ```

1. **Check for agent session logs** — if any logs exist in `.claude/logs/`, run the summary:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-logs.sh
   ```
   If there are logs, show the summary table and ask: **"Review any session logs before continuing? (issue number / all / skip)"**
   - If the user gives an issue number, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-logs.sh <N>` and display the output.
   - If "all", run the detail view for each issue with errors > 0.
   - If "skip", proceed to the next step.

1b. **Check audit data.** If `.claude/logs/runs.log` exists and has at least one row, ask:

   **"Review audits before continuing? (last / path / deviations / issue / skip)"**

   - `last N`   — run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh --last N` (prompt for N, default 5).
   - `path X`   — run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh --path X` (prompt for A/B/C).
   - `deviations` — run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh --deviations`.
   - `issue N`  — run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh --issue N` (prompt for N).
   - `skip`     — proceed to step 2.

   Display the script output and continue to step 2.

   **During full send:** auto-skip audit review (same behavior as log review in step 1).

1c. **Dispatch audit subagent if prior transcript unaudited.** This runs inside housekeeping (alongside auto-close-trackers and the classify-issue cache check), at a moment the user is already waiting on `/pipeline:run` before any other action. Adding ~30-60s of synchronous subagent work to that window is acceptable. The dispatch is **synchronous in wall-clock** but **zero-cost in orchestrator context** — `Agent(subagent_type='general-purpose', ...)` runs the audit prompt + transcript in an isolated context window; only the one-line summary returns to the orchestrator.

   Run the dispatch-gate helper to decide whether the prior orchestrator session needs the Interaction-lens classifier:

   ```bash
   GATE=$(bash "${CLAUDE_PLUGIN_ROOT:-.}/dev/self-audit/should-dispatch-audit.sh" 2>/dev/null || echo "skip:helper-error")
   case "$GATE" in
     dispatch:*)
       TRANSCRIPT_PATH=$(echo "$GATE" | cut -d: -f2)
       SESSION_UUID=$(echo "$GATE" | cut -d: -f3-)
       DIGEST_PATH=$(ls -t dev/audits/inner-*.md 2>/dev/null | head -1)
       REDACT_SH="$(pwd)/dev/self-audit/redact.sh"
       PROMPT_FILE="$(pwd)/dev/self-audit/dispatch-audit-subagent.md"
       # Proceed to Agent dispatch below.
       ;;
     skip:*) echo "[run] audit-dispatch: $GATE" ;;
   esac
   ```

   On a `dispatch:*` hit, dispatch the audit subagent **synchronously**, loading the prompt verbatim from `dev/self-audit/dispatch-audit-subagent.md` and substituting `TRANSCRIPT_PATH`, `DIGEST_PATH`, `SESSION_UUID`, and `REDACT_SH`:

   ```
   Agent(subagent_type='general-purpose',
         description='audit Interaction lens for session <SESSION_UUID>',
         prompt: '<contents of dev/self-audit/dispatch-audit-subagent.md, with the four vars substituted>')
   ```

   **Wait for completion before proceeding to step 2.** The Agent dispatch returns when the subagent finishes (success: one-line `audit: appended N events to <digest-basename>` summary; failure: visible error). The orchestrator's own context window receives only that summary, not the transcript or per-event detail. Idempotency: once the subagent replaces the placeholder line, the next `/pipeline:run` invocation finds no placeholder matching this session UUID — re-dispatching against the same transcript is harmless (the subagent's `Edit` call no-ops because `old_string` won't match).

   **During full send:** auto-skip — full send pipelines are bots-only sessions; their transcripts contain no human correction events worth classifying.

2. **Discover pipeline issues** — fetch all open AND recently closed issues, and classify by label:
   ```bash
   gh issue list --repo $PIPELINE_REPO --state open --json number,title,labels --limit 100
   gh issue list --repo $PIPELINE_REPO --state closed --json number,title,labels --limit 20
   gh pr list --repo $PIPELINE_REPO --state merged --json headRefName,number --jq '[.[] | {branch: .headRefName, pr: .number}]'
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

   `READY_ISSUES` feeds the parallel classify dispatch (below) and the planning proposal in step 5. `TRACKER_ISSUES` feeds the status-table render in step 4 — those issues are displayed with `Stage=tracker` and never reach the classify/plan dispatch.

   **Classify `ready` issues in parallel.** For each issue in the `ready` stage (no pipeline stage label) AND not excluded/later/human/brainstorm-labeled, check whether a `## Classification` comment already exists that is newer than the issue's `updatedAt`:

   ```bash
   for N in <ready_issue_numbers>; do
     LATEST_CLASS_TS=$(gh issue view $N --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Classification"))] | max_by(.createdAt) | .createdAt // empty')
     ISSUE_TS=$(gh issue view $N --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
     # If LATEST_CLASS_TS is empty OR LATEST_CLASS_TS < ISSUE_TS, queue for classification
   done
   ```

   Dispatch one `Agent(subagent_type='general-purpose')` per stale/missing issue **in parallel** (single tool-call batch, one Agent per issue), each invoking `/pipeline:classify-issue N`. Each classify run writes the Classification comment AND applies the path label (`docs-only` or `multi-task`). Cached issues skip dispatch. No user reconciliation step is needed — labels are now authoritative.

   **Caching semantics:** A classification is fresh when the latest `## Classification` comment's `createdAt > issue.updatedAt`. GitHub's `updatedAt` bumps on body edits AND label changes, so the cache auto-invalidates. Forced reclassification: delete the classification comment OR edit the issue body/labels. Both `/pipeline:run` (this step) and the `classify-issue` skill itself perform the same cache check so the skill can be re-invoked directly without duplicating work.

   **Detect residual mismatch (audit only):** For each `ready` issue with a fresh classification, compare the cached comment's `recommended_path` against the current label-derived path (`A` if labeled `docs-only`, `C` if labeled `multi-task`, else `B`). They should match — classify-issue writes them together. If they diverge, it means a user hand-edited a label after the last classify run; flag as `⚠ mismatch` and include in the final report column. Do NOT block planning on a mismatch: the label is authoritative, the comment is history.

   **Detect cleanup candidates:** Cross-reference active worktrees (from `git worktree list`) with merged PRs. A worktree whose branch appears in the merged PR list is a cleanup candidate. Also check for `pr-open` issues whose PR has been merged (state = MERGED) — these need cleanup too.

3. **Check for dependency information** — read issue bodies for "blocked by #N" or similar dependency notes. An issue is blocked if the blocking issue's branch has not appeared in the merged PR list.

4. **Print a grouped status table** for all discovered pipeline issues — epics (tracker issues) at the top with their open children indented underneath, and orphans (non-tracker issues not listed under any tracker) at the bottom, bucketed by conventional-commit scope. The per-row line carries only priority + type prefix + title + stage; any non-default Target Base / Path / Blocked-by metadata is surfaced in a separate **NOTES** footer table.

   **Inputs.** This step consumes `TRACKER_ISSUES` and `READY_ISSUES` from the tracker-filter block in step 2, plus the open-issue label/title map fetched in step 1. For each tracker, run the shared parser to extract its checklist children:

   ```bash
   body=$(gh issue view "$tracker" --repo "$PIPELINE_REPO" --json body --jq .body)
   children=$(printf '%s\n' "$body" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/parse-tracker-children.sh" -)
   ```

   Intersect `children` with the set of open issues to get **open children**; closed children are omitted. Children referenced under any tracker's checklist are removed from the orphan candidate set; whatever remains in the non-tracker open set is an orphan.

   **Per-row metadata** (used by the renderer and the NOTES footer):
   - **Priority badge** from the `priority/P*` label (fallback `[--]`).
   - **Type prefix** parsed from the issue title via the regex `^(feat|fix|chore|refactor|docs|test|perf|build|ci|style|revert|bug|brainstorm)\(([^)]+)\):` — group 2 is the **scope** used for orphan bucketing. Titles that don't match (or use `type:` without parens) land in the `(none / generic)` bucket.
   - **Stage** = current pipeline label (`plan-pending`, `plan-reviewed`, `plan-approved`, `in-progress`, `pr-open`, `merged`, or `ready`). Trackers render with `Stage=tracker`.
   - **Tags** = non-pipeline labels (i.e., NOT in `{plan-pending, plan-reviewed, plan-approved, in-progress, pr-open, merged, docs-only, multi-task, tracker, PIPELINE_LABELS_LATER, PIPELINE_LABELS_HUMAN, PIPELINE_LABELS_BRAINSTORM, PIPELINE_LABELS_EXCLUDED, priority/P*, next-major-release}`). Inline tags `(brainstorm)` / `(human-in-loop)` / `(later)` render alongside the title for issues carrying those labels.
   - **Target Base** = `next` if labels contain `next-major-release`, else `PIPELINE_BASE_BRANCH`. ≤10 chars, no truncation.
   - **Path** = `A` if labeled `docs-only`, `C` if labeled `multi-task`, else `B`. If both are present, show `A!` (PATH A wins, flag the collision). classify-issue writes labels directly, so label and recommendation always match after a classify run; the audit-only `⚠ mismatch` flag (see step 2) lives in the final report, not this column.
   - **Blocked by** = `#N` references parsed from `blocked by #N` / `depends on #N` annotations in the issue body, when present.

   **Grouped layout (epics on top, orphans below).** Trackers appear first with their priority badge and conventional-title; each open child renders on its own line, indented eight spaces, with stage right-aligned in parentheses. A tracker with zero open children collapses to a single `(all children closed — pending auto-close)` line:

   ```
   PIPELINE STATUS — <today's date>
   ================================================================
   EPICS
   ================================================================
    [P1] #120 — feat(install): consumer install hardening
            #144 — feat(doctor): label seeding              (plan-approved)
            #145 — feat(install): CLAUDE.md cleanup         (in-progress)
            #146 — feat(install): settings.json patch       (plan-pending)
    [P2] #131 — feat(observability): self-improve loop
            (all children closed — pending auto-close)
   ================================================================
   ORPHANS
   ================================================================
    (run)
       [P1] #133 — feat(run): canonical status table grouped by tracker + scope   (plan-pending)
       [P2]  #34 — feat(run): sort status table by scope                           (ready)
    (doctor)
       [P2] #150 — feat(doctor): settings cleanup patch                            (merged)
    (none / generic)
       [P2] #999 — chore: bump tooling                                             (ready)
   ================================================================
   ```

   Orphan bucketing rules:
   - Bucket key is the conventional-commit `<scope>` token from the title regex above.
   - Scope buckets render in alphabetical order; `(none / generic)` always last.
   - Within a bucket, rows sort by priority tier (`P0` < `P1` < `P2` < `P3` < no-priority).

   **NOTES footer (non-default metadata only).** Surface Target Base / Path / Blocked-by only for issues whose values differ from the defaults (`Target Base = $PIPELINE_BASE_BRANCH`, `Path = B`, `Blocked by = none`). If every issue carries defaults, omit the entire block:

   ```
   NOTES (non-default)
   ================================================================
    Issue  | Target Base | Path | Blocked by
   ----------------------------------------------------------------
    #150   | next        | A    | --
    #133   | pipeline    | B    | #132
   ================================================================
   ```

   **Counts footer (always rendered).** A single trailing line of the form `N epics + N children + N orphans = N open`:

   ```
   5 epics + 19 children + 5 orphans = 29 open
   ```

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

5. **Propose ONE action** based on state priority:
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
     - **Before proposing planning:** verify every ready issue has a fresh `## Classification` comment (the cache check from step 2 considers a comment fresh when its `createdAt > issue.updatedAt`). If any ready issue lacks a fresh classification, propose running `/pipeline:classify-issue N` for those issues first. Do NOT advance to planning until all ready issues are classified — classify-issue writes both the comment and the path label together.
     - Then propose planning for the ready issues (in parallel). Issues labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM` are shown in the table but never proposed for autonomous action; surface them in the report with a note like "(human-in-loop, manual)" or "(brainstorm, manual)".
   - If all issues are merged/done → congratulate and exit.

6. **Wait for user confirmation** before taking any action. Never spawn agents without explicit user approval.

7. **On confirmation:**

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
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue_number> | tee "$OUT_LOG"
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

   **For planning (no label → plan-pending) or re-planning (plan-pending with user feedback):** Run `/pipeline:plan-issue N` for each issue. If multiple issues need planning, spawn one Agent per issue in parallel (foreground), each invoking `/pipeline:plan-issue N`. If multiple issues share a branch (discovered from issue body/comments or matching branch names), plan them together in a single agent call. The plan-issue skill reads prior comments (including user feedback) and produces a revised plan when feedback exists.

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

   **Pre-spawn classifier (issue #218).** Before dispatching the PR evaluator, the orchestrator runs `bash scripts/eval-classifier-invoke.sh <issue> <pr>` if `PIPELINE_EVAL_CLASSIFIER` is set. The classifier's stdout is parsed token-by-token; a `--container-mode=<name>` token causes the dispatch to fall through to `spawn-claude.sh --container-mode=<name>` regardless of PATH letter — container mode overrides PATH A inline subagent dispatch because container isolation cannot be honored inside an inline `Agent()` call. Any other `--flag=value` tokens are forwarded to `spawn-claude.sh` via `--classifier-passthrough=<token>`. If the classifier exit non-zero, the issue is skipped with the classifier's first stderr line surfaced as the reason; the orchestrator continues with the remaining issues. When `PIPELINE_EVAL_CLASSIFIER` is unset (default), this step is a no-op and PATH A / B / C routing below is unchanged.

   **Dispatch routing by path tier.** Read each PR-open issue's labels:
   - **PATH A** (`docs-only` label present): dispatch inline from this orchestrator session — no `spawn-claude.sh`, no `claude -p`, no tmux. Worktree was already created during execute-issue-plan, so reuse `<worktree-path>`:
     ```
     Agent(subagent_type='general-purpose',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1> (set to 1 if --manual-merge flag is in argv or the issue carries the manual-merge label).')
     ```
     Thread the `MANUAL_MERGE=1` token into the prompt verbatim when applicable; the evaluate-issue-pr skill treats the inline token identically to the `MANUAL_MERGE=1` env var that `spawn-claude.sh --manual-merge` sets.
   - **PATH B / PATH C** (no `docs-only` label): unchanged — proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh` below.

   1. Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
   2. Launch via spawn-claude.sh with `--skill evaluate-issue-pr`:
      ```bash
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] --skill evaluate-issue-pr <worktree-path> <issue> <slug> <mode>
      ```
   3. For multiple issues, use the queue runner:
      ```bash
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] --skill evaluate-issue-pr <issue1> <issue2> ...
      ```
   4. The evaluate-issue-pr skill reviews the PR diff against the plan, makes minimal fixes if needed, and posts a verdict (Approved or Flagged). It does NOT merge — merge orchestration is handled by the pipeline (see step 8 below).

   **For execution (plan-approved → worktree setup):** For each approved issue's branch (deduplicated — issues sharing a branch get one worktree):

   **Dispatch routing by path tier.** After the worktree is set up (step 1 below), read each approved issue's labels:
   - **PATH A** (`docs-only` label present): dispatch inline from this orchestrator session — no `spawn-claude.sh`, no `claude -p`, no tmux. The worktree was created by `setup-worktree.sh`; only the agent launch is inline:
     ```
     Agent(subagent_type='general-purpose',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
   - **PATH B / PATH C** (no `docs-only` label): unchanged — proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh` below.

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
      #N     http://<droplet-ip>:<$PIPELINE_FRONTEND_PORT_OFFSET+N>        .claude/worktrees/$PIPELINE_WORKTREE_PREFIX-N-<slug>
      ================================================================
      ```
      To get the droplet IP, run: `curl -s ifconfig.me`

   3. Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
      If the user opts in to skip permissions, pass `--dangerously-skip-permissions` to the spawn script. This lets agents run without any permission prompts (all tool calls auto-approved).
      - **terminal** (default) — new Terminal.app window per issue with interactive Claude, auto-fires `/pipeline:execute-issue-plan N`. User monitors and interacts locally.
      - **tmux** — tmux windows in a `PIPELINE_TMUX_SESSION` session, auto-fires `/pipeline:execute-issue-plan N`
      - **remote-control** — `claude remote-control` servers, control from Claude mobile app or claude.ai/code. Only use this mode when the user explicitly says "remote-control".
      - **manual** — print instructions only

   4. **If user says tmux and there are 2+ issues** — use the queue runner to manage concurrency (max 3 at a time):
      ```bash
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
      ```
      Only pass `--skip-permissions` if the user opted in at step 3. The queue runner must be executed from inside a tmux session. If no tmux session exists, create one first:
      ```bash
      tmux new -s $PIPELINE_TMUX_SESSION -d
      ```
      Then launch the queue runner in a tmux window:
      ```bash
      tmux send-keys -t $PIPELINE_TMUX_SESSION "bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ..." Enter
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
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] <worktree-path> <issue_number> <slug> <mode>
      ```
      Where `<mode>` is `terminal`, `tmux`, or `remote-control`. Only pass `--dangerously-skip-permissions` if the user opted in at step 3.

   6. **If user says manual** — print manual instructions:
      ```
      Open each worktree in a terminal. They can run in parallel.

      Interactive: cd <worktree-path> && claude [--dangerously-skip-permissions] "/pipeline:execute-issue-plan N"
      Remote:      cd <worktree-path> && claude [--dangerously-skip-permissions] remote-control --name "issue-N-<slug>"
      Queue:       bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
      ```

### Anti-patterns

**Do not poll for queue completion with `while ... sleep ... grep` inside Bash tool calls.** This pattern burns context tokens on every poll cycle and ties up the orchestrator for the duration. Use `Bash run_in_background: true` for one-shot completion waits, or `Monitor` for streaming per-event notifications. The queue runner's internal `sleep` polling (inside `run-queue.sh`) is fine — it runs in its own process and does not consume orchestrator context.

8. **Merge orchestration** — after all evaluations complete, the pipeline handles merging. **Default is autonomous merge for the green subset** via the greenlight gate (`${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh`). The four greenlight conditions are: latest `## Evaluation` verdict is **Approved**; every `statusCheckRollup` entry has `conclusion == SUCCESS` (or the rollup is empty); `mergeable == MERGEABLE`; `mergeStateStatus == CLEAN`. Any one missing falls back to a `block-*` reason and requires manual `gh pr merge`.

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
        bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE
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

9. **After agents complete** (or after merge orchestration), report results and tell the user what to do next (review plans on GitHub, merge PRs, etc).
