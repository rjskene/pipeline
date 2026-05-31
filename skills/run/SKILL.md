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

The bash blocks below reference `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Pipeline Coordinator

## What `/pipeline:run` does

One-screen flow: `housekeeping → discover → status table → propose ONE action → dispatch`. The orchestrator surveys open issues, renders the prioritization+grouping status table, proposes the single next action by state priority, and waits for the user's confirmation before dispatching anything.

## Canonical entry points

- `/pipeline:run` — interactive **prioritize-then-dispatch** loop (this skill). The user picks the slate; classify dispatches only after they commit.
- `/pipeline:fullsend` — autonomous **end-to-end** execution (`skills/fullsend/SKILL.md`): classify → plan → evaluate plan → execute → evaluate PR → auto-merge greenlit PRs without intermediate confirmations.

PATH labels (A=docs-only, B=standard, C=multi-task, D=quick-fix) are owned by `skills/classify-issue/SKILL.md`; the lifecycle ASCII ladder lives in `docs/process-maps.md`. This skill references them by letter without redefining.

## Prioritization-first invariant

> **Invariant — prioritization first.** `/pipeline:run` MUST render the prioritization+grouping status table before any classify dispatch. Classification on the full ready set at startup is forbidden — classify runs only on the user-committed slate at Step 6. This carries forward the `feedback_pipeline_run_prioritization_first` direction from auto-memory and is asserted by `tests/test-pipeline-run-no-upfront-classify.sh`. Do not regress.

## Analyze mode (--analyze)

When `--analyze` appears anywhere in the argv to `/pipeline:run`, this skill MUST delegate by invoking `Skill(skill: "pipeline:analyze-issues")` and then STOP. Do not duplicate the analyze flow inline — the delegation is the only supported path. Full spec: [skills/analyze-issues/SKILL.md](../analyze-issues/SKILL.md).

## Shortcuts

| Shortcut | Meaning |
|----------|---------|
| **full send** | Back-compat alias for `/pipeline:fullsend`. Delegates to that skill with the same argv. |
| `--analyze` | Read-only hygiene pass — delegates to /pipeline:analyze-issues. See [skills/analyze-issues/SKILL.md](../analyze-issues/SKILL.md). |

## Full Send — back-compat delegator

The autonomous flow lives in its own skill: **`/pipeline:fullsend`** (see `skills/fullsend/SKILL.md`).

For back-compat, when the user prompt to `/pipeline:run` contains the token `full send` / `full-send` / `fullsend` (case-insensitive), this skill MUST delegate by invoking:

`Skill(skill: "pipeline:fullsend", args: "<original argv: issue numbers + --manual-merge if present>")`

and then STOP. Do not duplicate the autonomous flow inline — the delegation is the only supported back-compat path.

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

- `docs-only` / `multi-task` — PATH tag applied by classify-issue; persists through the rest of the lifecycle. Read by plan-issue (to emit PATH-aware Task 0/N), by spawn-claude.sh (to inject the path-specific execute skills), and by the enforce-path-c-delegation hook (to block direct orchestrator edits on multi-task issues).
- `plan-pending` — plan posted, awaiting evaluation.
- `plan-reviewed` — evaluation posted, awaiting user approval.
- `plan-approved` — user approved the plan; ready for execution.
- `in-progress` — execution agent is implementing.
- `pr-open` — PR created, awaiting evaluation/review/merge.
- `merged` — PR merged, worktree ready for cleanup.

## Worktree-only rule

**NEVER implement GitHub issue work directly on the current branch.** All issue-related changes — no matter how small — must go through a worktree, feature branch, and PR. This keeps the main working directory clean and ensures every issue follows the full pipeline flow (worktree → branch → PR → merge → cleanup).

If the user asks to "just fix" an issue or work on it directly, remind them that pipeline issues require a worktree and propose setting one up.

## Status table

Rendering is delegated to `scripts/render-status-table.sh`; the renderer is the single source of truth for column widths, ordering, header lines, and footer formats — future tweaks ship as script changes plus golden-file updates, not prompt edits. Full input-file assembly, renderer invocation, and a labeled ASCII example (release-PR row, dated header, tracker section, orphan section, NOTES block, counts footer) in [references/status-table.md](references/status-table.md).

Path column shows `?` for ready issues not yet classified — classification runs on demand when the user commits to a slate (see Step 4), not upfront on the full ready set.

## Steps

0. **Housekeeping** — concerns covered before any discovery: orchestrator branch check, base-branch hook wiring advisory, `next-major-release` warning, worktree sync, release-PR discovery, stale tmux cleanup, auto-close trackers, reap stale visual-proof servers. Full detail in [references/housekeeping.md](references/housekeeping.md). The branch check must use `git pull --quiet origin "${EXPECTED_BASE}"` (quiet flag is required so the orchestrator does not pull the fast-forward file list into context). Discover release PRs with `list-release-prs.sh` (which lists PRs carrying the label configured by `PIPELINE_RELEASE_PR_LABEL`, default `autorelease: pending`), auto-close finished trackers, sync worktrees, and reap stale visual-proof servers — all wrapped with `PIPELINE_REPO=` per Issue #288:

   ```bash
   RELEASE_PRS=$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
     echo "[run] WARN: auto-close-trackers.sh exited non-zero (continuing)"
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
   # Reap stale visual-proof servers (orphaned python http.servers whose
   # worktree has been pruned). Housekeeping; never gate-fatal. See #517.
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/reap-stale-visual-proof-servers.sh" || true
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

   Classification is deferred — see Step 6 (Propose ONE action → planning branch) for the cache-checked dispatch that runs only on the user-committed slate.

2. **Check for dependency information** — read issue bodies for "blocked by #N" or similar dependency notes. An issue is blocked if the blocking issue's branch has not appeared in the merged PR list.

3. **Render the status table** — invoke `scripts/render-status-table.sh` with the three input files described in [references/status-table.md](references/status-table.md). Print the renderer's stdout verbatim; the run skill is NOT the source of truth for layout. After invoking the renderer, the orchestrator MUST reprint the rendered table as plain text inside its assistant reply — bash tool stdout alone is not visible to the user without expanding the tool call. Attachments (`att` column) come from `$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-<N>/`, populated upstream by `/pipeline:fullsend` step 1a or `/pipeline:plan-issue` step 3b — the run skill does NOT re-fetch.

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

4. **Propose ONE action** based on state priority (highest → lowest): cleanup > in-progress > pr-open eval > plan-pending eval > plan-reviewed (await user) > plan-approved exec > merge release PR > ready planning. Rationale: a release PR is the end of the release loop — it must NOT preempt active feature work, but it should come BEFORE pulling in new ready work.

   - **cleanup**: if any worktrees are cleanup candidates (merged PR with active worktree) → propose cleanup; list each candidate with issue number and worktree path.
   - **in-progress**: print which issues, note agents are working, do not propose anything else.
   - **pr-open**: for each, check for a `## Evaluation` comment via `gh pr view $PR_NUM --json comments`. If any have no evaluation → propose `/pipeline:evaluate-issue-pr` for those. If all have evaluation → remind user to review flagged PRs or note they're ready to merge.
   - **plan-pending**:
     - **PATH D auto-flip (quick-fix bypass).** For each plan-pending issue labelled quick-fix, immediately emit gh issue edit $N --add-label plan-approved --remove-label plan-pending in this orchestrator turn:

       ```bash
       gh issue edit $N --repo $PIPELINE_REPO --add-label plan-approved --remove-label plan-pending
       ```

       Do NOT propose `/pipeline:evaluate-issue-plan` for PATH D issues; the evaluate-issue-plan stage is bypassed for D. After the flip, the issue advances to the `plan-approved` branch on the same or next ladder traversal. This is a discovery-driven flip — the run skill emits it whenever it observes a `plan-pending`+`quick-fix` issue, so it is idempotent across re-runs and works for both fresh plans and re-plans.
     - For non-D issues, check for `## Plan Evaluation`. No evaluation → propose `/pipeline:evaluate-issue-plan`. Evaluation present AND user feedback posted after it → propose re-running `/pipeline:plan-issue N`. Otherwise → awaiting user review.
   - **plan-reviewed**: note awaiting user approval; do not propose anything.
   - **plan-approved**: propose setting up worktrees via `scripts/setup-worktree.sh` and printing launch instructions. The script takes TWO positional args: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh <branch-name> <issue-number>`. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title per the **Branch and worktree naming convention** block above. Worked example: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81`. **Do NOT invoke with only the issue number** — the script will reject a bare integer as of #350 because it does not match the `feature/<slug>` shape.
   - **release PR**: if any release PRs from Step 0 have `ci=pass` → propose "merge release PR #N" (one per green release PR). On user confirmation, run `gh pr merge $PR_NUM --repo $PIPELINE_REPO --merge --delete-branch`. Release PRs with `ci=fail` or `ci=pending` are surfaced in the status table but NOT proposed.
   - **tracker**: shown in the table (stage=`tracker`) but never proposed for plan/execute — coordination rollups, not implementation work.
   - **ready planning**: if any issues have no pipeline label, are not blocked, and are not labeled `PIPELINE_LABELS_HUMAN` / `PIPELINE_LABELS_BRAINSTORM`:
     - Identify the unclassified subset of the proposed slate (ready issues without a fresh `## Classification` comment per the cache check in Step 6). The proposal MUST name the slate AND surface the unclassified subset by issue number — for example: "Propose planning for #292, #309, #316. Of these, #292 and #316 lack classification — `/pipeline:classify-issue` will run on those first." Classification only runs on user confirmation (Step 6), not at proposal time. Issues labeled `PIPELINE_LABELS_HUMAN` or `PIPELINE_LABELS_BRAINSTORM` are surfaced with a manual-only note.
   - **all merged**: congratulate and exit.

5. **Wait for user confirmation** before taking any action. Never spawn agents without explicit user approval.

6. **On confirmation — dispatch.** Verbose detail (cleanup walkthrough, plan-evaluation narrative, queue-runner mechanics, manual-mode block) in [references/dispatch-routing.md](references/dispatch-routing.md). The path-tier routing surfaces stay inline because contract tests grep for them.

   **For cleanup (merged PRs with active worktrees):** Update CLAUDE.md, run `scripts/cleanup-worktree.sh` per candidate, then create a batch checkpoint tag with `scripts/create-checkpoint-tag.sh`. Full walkthrough in [references/dispatch-routing.md](references/dispatch-routing.md#cleanup-merged-prs-with-active-worktrees).

   **For plan evaluation (plan-pending → plan-reviewed):** Run `/pipeline:evaluate-issue-plan N` for each issue needing evaluation; parallel Agent dispatches when multiple.

   **For planning (no label → plan-pending) or re-planning (plan-pending with user feedback):** Classify the user-committed subset first — for each issue, check whether a fresh `## Classification` comment exists (`createdAt >= issue.updatedAt`). If any lack a fresh classification, dispatch one `Agent(subagent_type='general-purpose')` per stale/missing issue **in parallel**, each invoking `/pipeline:classify-issue N`. Cached issues skip dispatch. Then run `/pipeline:plan-issue N` for each issue, parallel when multiple.

   **For PR evaluation (pr-open → evaluated):** Use the same launch flow as execution — the worktree already exists from execute-issue-plan, no setup needed.

   **Web-surface routing.** PRs labelled `needs-browser` route through inline `Agent(general-purpose)` dispatch with the visual-proof preflight; no separate classifier is consulted.

   **Dispatch routing by path tier.** Read each PR-open issue's labels:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux. Worktree was already created during execute-issue-plan, so reuse `<worktree-path>`:
     ```
     Agent(subagent_type='general-purpose',
           description='evaluate-issue-pr #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/evaluate-issue-pr/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>. MANUAL_MERGE=<0|1>')
     ```
     Thread `MANUAL_MERGE=1` into the prompt verbatim when the issue carries the manual-merge label or the user passed `--manual-merge`; the evaluate-issue-pr skill treats the inline token identically to the `MANUAL_MERGE=1` env var set by `spawn-claude.sh --manual-merge`.
   - **PATH B / PATH C**: proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh` (see [references/dispatch-routing.md](references/dispatch-routing.md#pr-evaluation-pr-open--evaluated)).
   - **PATH D**: PR evaluation stays `general-purpose` (NOT `tdd-implementer`) — inline dispatch shape identical to PATH A. Asymmetric by design: reusing `tdd-implementer` for eval would force red→green discipline on a workflow that does not need it.

   **For execution (plan-approved → worktree setup):** For each approved issue's branch (deduplicated):

   **Dispatch routing by path tier.** After the worktree is set up, read each approved issue's labels:
   - **PATH A** (`docs-only`): dispatch inline — no `spawn-claude.sh`, no `claude -p`, no tmux. The worktree was created by `setup-worktree.sh`; only the agent launch is inline:
     ```
     Agent(subagent_type='general-purpose',
           description='execute-issue-plan #<N> (PATH A inline)',
           prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')
     ```
   - **PATH B / PATH C**: proceed with the existing terminal/tmux/remote-control/manual launch flow via `spawn-claude.sh` / `run-queue.sh`.
   - **PATH D** (`quick-fix`): dispatch inline via `Agent(subagent_type='tdd-implementer', description='execute-issue-plan #<N> (PATH D collapsed inline tdd)', prompt: 'cd <worktree-absolute-path>; then follow skills/execute-issue-plan/SKILL.md for issue #<N>. <worktree-path>=<abs path>, slug=<slug>.')`. No spawn-claude.sh, no tmux, no run-queue.sh. The subagent_type uses the BARE `tdd-implementer` form (matching the existing PATH C plan-issue precedent and the agent-file declaration), NOT a namespaced form.

     **Collapsed-D ceremony.** That single dispatch is **one collapsed inline `Agent`** doing **classify+plan+execute** in a single carried-forward context — NOT three separate Agent dispatches. The classify and plan stages run inside that same single context (carried-forward, not re-spawned), emitting `## Classification`+path label and `## Implementation Plan`+`plan-pending` as inline side-effects as the agent goes, then it carries straight on to execution.

     **pr-eval stays a separate inline agent.** The collapsed D context covers classify+plan+execute only — the subsequent pr-eval STAYS a SEPARATE inline `Agent` (separate ≠ spawned; it is still inline, just a fresh context). An agent must not evaluate its own work — **evaluator independence** is the reason pr-eval is never folded into the collapsed D context.

     **Concurrency bound + fan-out.** Multiple D issues fan out as parallel inline `Agent` calls in a single tool-call batch, capped at **max 3 concurrent inline** D agents — this bounds orchestrator context plus the blocking foreground turn while the inline agents run.

     **Escalation backstop.** A collapsed D agent that discovers the change exceeds D's envelope (the quick-fix scope) aborts up to a spawned PATH B run rather than forcing the work through the collapsed inline path.

   Run the setup script with BOTH positional args — `<branch-name>` AND `<issue-number>`. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title per the **Branch and worktree naming convention** block above; `<issue-number>` is the bare integer:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/<slug> <issue_number>
   ```

   Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81
   ```

   This creates the worktree at `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-<issue_number>-<slug>`, copies `.claude/settings.local.json`, installs dependencies, and seeds the dev database. **Do NOT invoke with only the issue number** — the script will reject a bare integer as of #350 because it does not match the `feature/<slug>` shape required by the branch-naming convention.

   After all worktrees are set up, ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)" and dispatch via `spawn-claude.sh` (single issue) or `run-queue.sh` (2+ issues, max 3 concurrent). Full launch-mode flow and queue-runner mechanics in [references/dispatch-routing.md](references/dispatch-routing.md#launch-mode-prompt).

### Anti-patterns

See [references/anti-patterns.md](references/anti-patterns.md) for the list of patterns to avoid when orchestrating the run loop.

7. **Merge orchestration** — after all evaluations complete, the pipeline handles merging. **Default is autonomous merge for the green subset** via the greenlight gate (`${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh`). The four greenlight conditions: latest `## Evaluation` verdict is **Approved**; every `statusCheckRollup` entry has `conclusion == SUCCESS` (or the rollup is empty); `mergeable == MERGEABLE`; `mergeStateStatus == CLEAN`. Any one missing falls back to a `block-*` reason and requires manual `gh pr merge`. Full detail in [references/merge-orchestration.md](references/merge-orchestration.md).

   **Per-PR auto-merge loop.** For each PR labelled `pr-open`:

   1. **Already-merged short-circuit.** Check the latest `## Evaluation` PR comment for the exact footer prefix `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at` (written by `evaluate-issue-pr` Step 11 on the green path). If present, mark the row `Auto-merged? = yes (eval)` and skip — already merged and closed.
   2. **Run the gate.** `source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"; REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM")`.
   3. **On `green`:** run the conventional-title pre-validation, then merge synchronously (NOT `--auto`): `gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch`, write the `Auto-merged: eval Approved + CI SUCCESS + MERGEABLE/CLEAN at <ts>` footer to the issue-close comment, flip labels (`pr-open` → `merged`), close issue. Mark the row `Auto-merged? = yes (step8)`.
   4. **On any `block-*` reason:** mark the row `Auto-merged? = no (${REASON})` and leave the PR for manual merge. Do NOT flip labels. Do NOT close the issue. **After the operator hand-merges such a PR** (`gh pr merge <PR> --repo "$PIPELINE_REPO" --merge --delete-branch`), have them run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-manual-merge.sh" <issue> <PR>` to replay the bookkeeping the gate skipped — flip `pr-open`→`merged`, drop `manual-merge`, and close the issue with a `Merged via PR #<PR>` note (`Closes #N` does not fire against the `staging` base). The helper is idempotent, so it is safe to run even if some labels are already correct.

   Release-please PRs are out of scope here — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b above, unchanged. Opt-outs: `FULL SEND --manual-merge`, `/pipeline:evaluate-issue-pr N --manual-merge`, or the `manual-merge` label on the issue.

   **Base-branch retarget + conflict rebase + sequential merge.** Before the sequential loop, source `${CLAUDE_PLUGIN_ROOT}/scripts/detect-merge-overlap.sh` and run `detect_merge_overlap` over the approved-PR set to surface pairwise file overlaps; `recommend_merge_order` returns a fewest-overlap-first ordering to use for the loop. Advisory — does not block. Before each merge: detect the PR's base branch; if it diverges from `.claude/base-branch` (or `PIPELINE_BASE_BRANCH`), call `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/retarget-pr.sh $PR_NUM $EXPECTED_BASE`. Check `mergeable`; on conflict, rebase in the worktree and force-push with `--force-with-lease`, retrying merge. Merge PRs sequentially to avoid cascading conflicts. Validate the PR title against the Conventional Commits format (`scripts/check-conventional-title.sh`) — release-please reads the squash commit on merge, so a non-conforming title breaks automated versioning. Full step-by-step in [references/merge-orchestration.md](references/merge-orchestration.md#sequential-merge-with-base-branch-retarget--conflict-rebase).

8. **After agents complete** (or after merge orchestration), report results and tell the user what to do next (review plans on GitHub, merge PRs, etc).
