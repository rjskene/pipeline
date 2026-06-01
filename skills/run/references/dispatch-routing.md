# Step 6 — dispatch routing detail

This file holds the verbose detail for Step 6 of `/pipeline:run` (on-confirmation dispatch). SKILL.md keeps the path-tier routing tables inline because several contract tests grep for the literal PATH A/B/C/D dispatch blocks (`tests/test-run-skill-dispatch-routing.sh`, `tests/test-path-d-auto-approve.sh`, `tests/test-run-skill-setup-worktree-signature.sh`). Everything else — the cleanup walkthrough, the plan-evaluation narrative, the queue-runner mechanics, the manual-mode block — lives here.

**IMPORTANT: All spawned `claude` agent processes MUST run in foreground (never `run_in_background`).** Background agents lose tool permissions and the user cannot monitor progress. The **queue runner script** (`run-queue.sh`) is a plain bash process that manages tmux windows — it does NOT need tool permissions. The orchestrator should launch the queue runner via `Bash` with `run_in_background: true` to receive a single completion notification instead of blocking (see "Queue runner" below).

## Cleanup (merged PRs with active worktrees)

### Step A — Update CLAUDE.md files

Before removing any worktree, review what the merged branch changed and update the CLAUDE.md documentation so it reflects the new state of the codebase. For each cleanup candidate:

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

### Step B — Run cleanup

Run the cleanup script for each candidate, capturing its stdout to a per-issue temp file so the orchestrator can parse the final `CLEANUP-SUMMARY:` line for batch tagging:

```bash
mkdir -p /tmp/pipeline-cleanup
OUT_LOG=$(mktemp /tmp/pipeline-cleanup/issue-<issue_number>-XXXX.log)
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-worktree.sh <issue_number> | tee "$OUT_LOG"
```

This script (in order): verifies the PR is merged/closed, closes the GitHub issue with the `merged` label, consolidates tool-use logs, removes the git worktree, and deletes the remote+local branch. Its final line is machine-readable: `CLEANUP-SUMMARY: issue=<N> pr=<PR|none> branch=<branch>`.

If multiple worktrees need cleanup, run them sequentially, each to its own temp log.

### Step B.5 — Create a checkpoint tag for the batch

After every cleanup invocation finishes (including a batch of one), aggregate the `CLEANUP-SUMMARY` lines and create a single local checkpoint tag on the base branch:

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

## Plan evaluation (plan-pending → plan-reviewed)

Run `/pipeline:evaluate-issue-plan N` for each issue needing evaluation. If multiple issues need evaluation, spawn one Agent per issue in parallel (foreground), each invoking `/pipeline:evaluate-issue-plan N`. The evaluate-issue-plan skill is read-only — it reads the plan comment and codebase, posts an evaluation comment, and updates labels. If the verdict is "Approve," the label changes to `plan-reviewed`. If "Revise," the label stays `plan-pending` and the evaluation comment explains what needs to change.

## Planning (no label → plan-pending) or re-planning (plan-pending with user feedback)

**Classify the user-committed subset first.** For each issue in the committed slate, check whether a fresh `## Classification` comment exists (the comment's `createdAt >= issue.updatedAt`). If any lack a fresh classification, dispatch one `Agent(subagent_type='general-purpose')` per stale/missing issue **in parallel** (single tool-call batch, one Agent per issue), each invoking `/pipeline:classify-issue N`. Each classify run writes the Classification comment AND applies the path label. Cached issues skip dispatch. Wait for all classify agents to complete before dispatching plan-issue. Caching semantics: GitHub's `updatedAt` bumps on body edits AND label changes, so the cache auto-invalidates. This is the same cache check that previously lived in Step 1 discovery, relocated to fire only on the user-committed subset rather than the full ready set.

Then: Run `/pipeline:plan-issue N` for each issue. If multiple issues need planning, spawn one Agent per issue in parallel (foreground), each invoking `/pipeline:plan-issue N`. If multiple issues share a branch (discovered from issue body/comments or matching branch names), plan them together in a single agent call. The plan-issue skill reads prior comments (including user feedback) and produces a revised plan when feedback exists.

**Dispatch prompt contract (mandatory):** each `/pipeline:plan-issue N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: (a) `bash "${CLAUDE_PLUGIN_ROOT}/scripts/post-plan.sh" N <draft-file>` exited 0 and it reports the success line, or (b) `post-plan.sh` exited non-zero and it reports the FAILED line. Returning the plan body in chat is a failure — the plan does not exist until `post-plan.sh` has posted the `## Implementation Plan` comment and applied the `plan-pending` label. A `general-purpose` subagent may never load `skills/plan-issue/SKILL.md` (it can treat `/pipeline:plan-issue N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. (This block is intentionally verbatim with `skills/fullsend/SKILL.md` Step 1b — the two dispatch sites are one contract in two places.)

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

## PR evaluation (pr-open → evaluated)

Use the same launch flow as execution — the worktree already exists from execute-issue-plan, no setup needed.

**Path-tier scope (#748).** The `spawn-claude.sh` / `run-queue.sh` launch flow described below applies to **PATH C only**. PATH A, PATH B, and PATH D PR-evals dispatch inline via `Agent(subagent_type='general-purpose', ...)` (no `spawn-claude.sh`, no `run-queue.sh`, no tmux) — see the path-tier routing blocks in SKILL.md Step 6. PATH B joined the inline foreground path in #748; the inline B execute Agent and the inline B PR-eval Agent stay SEPARATE inline contexts (evaluator independence).

**Web-surface routing.** PRs labelled `needs-browser` route through inline `Agent(general-purpose)` dispatch with the visual-proof preflight; no separate classifier is consulted.

### Launch flow for PR evaluation

1. Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
2. Launch via spawn-claude.sh with `--skill evaluate-issue-pr`:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] --skill evaluate-issue-pr <worktree-path> <issue> <slug> <mode>
   ```
3. For multiple issues, use the queue runner:
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] --skill evaluate-issue-pr <issue1> <issue2> ...
   ```
4. The evaluate-issue-pr skill reviews the PR diff against the plan, makes minimal fixes if needed, and posts a verdict (Approved or Flagged). It does NOT merge — merge orchestration is handled by the pipeline (see [merge-orchestration.md](merge-orchestration.md)).

## Execution (plan-approved → worktree setup)

For each approved issue's branch (deduplicated — issues sharing a branch get one worktree):

**Path-tier scope (#748).** Worktree setup (`setup-worktree.sh`) is identical for every path, but the *launch* differs by tier. The `spawn-claude.sh` / `run-queue.sh` launch flow below applies to **PATH C only**. PATH A and PATH B execute dispatch inline via `Agent(subagent_type='general-purpose', ...)`, and PATH D via the collapsed inline `Agent(subagent_type='tdd-implementer', ...)` — none of A/B/D use `spawn-claude.sh`, `run-queue.sh`, or tmux (see the SKILL.md Step 6 path-tier blocks). PATH B's red→green discipline comes from the plan's Task 0 `superpowers:test-driven-development` bookend inside execute-issue-plan, identical to a spawned worker, so the transport flip changes only the launch, not the TDD discipline.

**Inline execute dispatch prompt contract (mandatory).** Each inline PATH A/B/D `/pipeline:execute-issue-plan N` Agent prompt MUST end with a directive stating the dispatched subagent's *only* valid terminal states are: **(a)** the PR is opened and the issue is flipped to `pr-open`, reporting the success line (PR number + final test status); or **(b)** the work failed, reporting a FAILED line. Narrating an intention to "wait" (e.g. *"I'll wait for the suite notification."*) — or returning prose/edits instead of committing, pushing, and opening the PR — is explicitly a **failure**: a dispatched `Agent`'s turn ends the moment it stops emitting tool calls, so narrate-and-yield strands the subagent with uncommitted work in progress (the #752/#764 drop-out). The subagent must instead run to completion (commit → push → `gh pr create` → label flip) or actually block on the suite via `Monitor`/`BashOutput` before yielding. A `general-purpose`/`tdd-implementer` subagent may never load `skills/execute-issue-plan/SKILL.md` (it can treat `/pipeline:execute-issue-plan N` as content rather than a skill load), so this dispatch-site directive — not the skill body — is the binding contract. (This block is intentionally verbatim with `skills/run/SKILL.md` Step 6 — the two execute dispatch sites are one contract in two places, mirroring the plan-issue precedent above.)

### Setup-worktree invocation

Run the setup script with BOTH positional args — `<branch-name>` AND `<issue-number>`. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title per the "Branch and worktree naming convention" block (in SKILL.md); `<issue-number>` is the bare integer:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/<slug> <issue_number>
```

Worked example:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81
```

This creates the worktree at `.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-<issue_number>-<slug>`, copies `.claude/settings.local.json`, installs dependencies, and seeds the dev database.

**Do NOT invoke with only the issue number** — the script will reject a bare integer as of #350 because it does not match the `feature/<slug>` shape required by the branch-naming convention. A call like `setup-worktree.sh 81` fails the branch-prefix guard; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.

### Post-setup summary

After ALL worktrees are set up, print a summary with the frontend URL for each issue. The frontend port is `$PIPELINE_FRONTEND_PORT_OFFSET + issue_number`:

```
WORKTREES READY
================================================================
Issue  Frontend URL                        Worktree Path
----------------------------------------------------------------
#N     http://<server-ip>:<$PIPELINE_FRONTEND_PORT_OFFSET+N>        .claude/worktrees/$PIPELINE_WORKTREE_PREFIX-N-<slug>
================================================================
```

To get your server's public IP, run: `curl -s ifconfig.me`

### Launch mode prompt

Ask: "Launch mode? (terminal / tmux / remote-control / manual) | Skip permissions? (y/n)"
If the user opts in to skip permissions, pass `--dangerously-skip-permissions` to the spawn script. This lets agents run without any permission prompts (all tool calls auto-approved).

- **terminal** (default) — new Terminal.app window per issue with interactive Claude, auto-fires `/pipeline:execute-issue-plan N`. User monitors and interacts locally.
- **tmux** — tmux windows in a `PIPELINE_TMUX_SESSION` session, auto-fires `/pipeline:execute-issue-plan N`
- **remote-control** — `claude remote-control` servers, control from Claude mobile app or claude.ai/code. Only use this mode when the user explicitly says "remote-control".
- **manual** — print instructions only

### Queue runner (tmux with 2+ issues)

If the user says tmux and there are 2+ issues — use the queue runner to manage concurrency (max 3 at a time):

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
```

Only pass `--skip-permissions` if the user opted in at the launch-mode prompt. The queue runner must be executed from inside a tmux session. If no tmux session exists, create one first:

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

### Single-issue spawn (tmux/terminal/remote-control with 1 issue)

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/spawn-claude.sh [--dangerously-skip-permissions] <worktree-path> <issue_number> <slug> <mode>
```

Where `<mode>` is `terminal`, `tmux`, or `remote-control`. Only pass `--dangerously-skip-permissions` if the user opted in.

### Manual mode

If the user says manual — print manual instructions:

```
Open each worktree in a terminal. They can run in parallel.

Interactive: cd <worktree-path> && claude [--dangerously-skip-permissions] "/pipeline:execute-issue-plan N"
Remote:      cd <worktree-path> && claude [--dangerously-skip-permissions] remote-control --name "issue-N-<slug>"
Queue:       PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh [--skip-permissions] <issue1> <issue2> ...
```
