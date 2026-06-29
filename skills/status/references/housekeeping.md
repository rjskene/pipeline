# Step 0 housekeeping — verbose detail

`/pipeline:status` Step 0 covers nine housekeeping concerns. SKILL.md keeps a compact version of each; the full detail (including the surrounding rationale) lives here.

## 1. Orchestrator branch check

The base branch for all PRs is read from `pipeline.config` (`PIPELINE_BASE_BRANCH=$PIPELINE_BASE_BRANCH`). The orchestrator session should be on that branch so spawned worktrees inherit from it and PRs target it.

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

## 2. Base-branch hook wiring advisory

Defense-in-depth visibility: the `enforce-base-branch.py` PreToolUse hook is what makes the branch-check reminder above actually enforceable, and that hook must be registered in *either* the plugin manifest (`.claude-plugin/plugin.json`) *or* the consumer's local `.claude/settings.json`. If both surfaces silently drop the registration (e.g. a stale install, a hand-edited settings file, or a partial migration), `gh pr create` from spawned agents can escape `PIPELINE_BASE_BRANCH` and target the repo's default branch. The helper scans both files and prints a single `WARN:` line on stdout when neither wires the hook — otherwise it stays silent. The check is **advisory only and never aborts the run**; `/pipeline:status` cannot rewrite a consumer's `.claude/settings.json` (#215 tracks render-on-install). Surface the WARN to the user and continue.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-base-branch-hook-wiring.sh" \
  --plugin-manifest "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json" \
  --consumer-settings ".claude/settings.json" \
  --expected-base "${EXPECTED_BASE}" || true
```

## 3. Next-branch routing

Surface open issues routed onto the next-integration branch. Routing is now **actuated** (#1128): the execute path passes `--base "$NEXT_BRANCH"` to `setup-worktree.sh` for these issues automatically (see `skills/fullsend/SKILL.md` Step 5), so they land on — and their PRs target — the next-branch. This pass is a status surface, not a manual gate.

Resolve the configurable label/branch (defaults `next`/`next`) and query the union of the configured next-label AND the retained legacy `next-major-release` alias (so already-labelled issues keep routing without re-labelling):

```bash
NEXT_LABEL="${PIPELINE_NEXT_LABEL:-next}"
NEXT_BRANCH="${PIPELINE_NEXT_BRANCH:-next}"
NEXT_ISSUES=$( { \
  gh issue list --repo "$PIPELINE_REPO" --state open \
    --label "$NEXT_LABEL" --json number,title --jq '.[] | "#\(.number) \(.title)"'; \
  gh issue list --repo "$PIPELINE_REPO" --state open \
    --label next-major-release --json number,title --jq '.[] | "#\(.number) \(.title)"'; \
} | sort -u)
if [ -n "$NEXT_ISSUES" ]; then
  echo ""
  echo "Next-branch routing: the following open issues route onto '$NEXT_BRANCH' (label '$NEXT_LABEL' or legacy 'next-major-release'):"
  echo "$NEXT_ISSUES" | sed 's/^/  /'
  echo "  The execute path passes --base \"$NEXT_BRANCH\" for these automatically."
fi
```

The orchestrator session itself is not force-switched — only each next-labelled issue's worktree is cut from the next-branch.

## 4. Worktree sync

If any worktrees exist, run the sync script to ensure all active worktrees have up-to-date CLAUDE.md files, `.claude/` settings, and hooks:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/sync-worktrees.sh
```

Report any fixes briefly.

## 5. Release-PR discovery

Discover open release-bot PRs (release-please by default) so they can be surfaced in the status table and proposed/auto-merged in later steps. The helper lists PRs carrying the label configured by `PIPELINE_RELEASE_PR_LABEL` (default `autorelease: pending`):

```bash
RELEASE_PRS=$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)
```

Output schema, one line per PR: `pr=<num> ci=<pass|fail|pending> title=<title>`. Empty when no release PRs are open or `gh` is unavailable — degrade silently in that case.

## 6. Stale tmux cleanup

Check for stale tmux sessions from previous pipeline runs. If a tmux `PIPELINE_TMUX_SESSION` session exists, kill any leftover queue runner and agent windows:

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

## 7. Auto-close trackers

Auto-close any tracker issue whose Rollout-sequence children are all closed. This is cheap (one `gh issue list` + one `gh issue view` per open tracker) and fail-soft — a non-zero exit from the helper is logged but never aborts the run:

```bash
PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/auto-close-trackers.sh" --apply || \
  echo "[run] WARN: auto-close-trackers.sh exited non-zero (continuing)"
```

## 8. Reap stale visual-proof servers

Visual-proof evaluators spawn short-lived `python -m http.server` processes rooted at a worktree directory. If a worktree is removed (cleanup-worktree.sh, manual rm, container teardown) while a server is still bound to a port, the process leaks. The reaper enumerates such servers, identifies each one's enclosing `.git` ancestor, cross-checks against `git worktree list --porcelain`, and SIGTERM/SIGKILLs any whose worktree is no longer registered. Emits `EVENT: reaped pid=<P> dir=<D>` per kill or `(no stale servers)` when nothing matched. Always exits 0 (housekeeping, never gate-fatal). See #517.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/reap-stale-visual-proof-servers.sh" || true
```

## 9. Auto-cleanup of merged worktrees

When a merged PR still has an active worktree, clean it up automatically here — as the **non-blocking tail of Step 0, before discovery** — so it never preempts feature-work proposal. This reuses the EXISTING cleanup machinery; no new deletion logic and no second gate.

Detect cleanup candidates inline (do not depend on Step 1 ordering) via the per-worktree merged-PR loop:

```bash
for wt in $(git worktree list --porcelain | awk '/^branch refs/{sub("refs/heads/","",$2); print $2}'); do
  gh pr list --repo "$PIPELINE_REPO" --head "$wt" --state merged --json number,headRefName \
    --jq '.[] | {branch: .headRefName, pr: .number}'
done
```

For each candidate (merged PR + active worktree), run `cleanup-worktree.sh <issue>` capturing its `CLEANUP-SUMMARY:` line, then create ONE batch `create-checkpoint-tag.sh --issues … --prs …` for the whole batch — updating CLAUDE.md, capturing each `CLEANUP-SUMMARY`, creating the batch `create-checkpoint-tag.sh`, and emitting the CLEANUP COMPLETE table.

**Gate reuse, not duplication.** `cleanup-worktree.sh` already verifies `PR state == MERGED` before any destructive op, and the destructive worktree-remove + branch-delete remain subject to the existing `ALLOW_DELETIONS` gate (read from `settings.local.json` `.env.ALLOW_DELETIONS` by `sync-worktrees.sh` pruning and honored by `block_deletions.py`). Do NOT add a second gate.

**`--keep-trees` opt-out.** When `--keep-trees` appears anywhere in the argv, SKIP this concern entirely — candidates are still detected and surfaced downstream (status table / Step 4), they are just not acted on. Auto-cleanup is non-blocking and never gate-fatal.
