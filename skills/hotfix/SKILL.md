---
name: hotfix
description: Emergency-lane hotfix — in-session worktree fix bypassing all pipeline lifecycle gates (classify/plan/evaluate/auto-merge). Files an issue (or uses an existing one), creates a worktree, runs the test/fix loop in the current orchestrator session, opens a PR. Usage: /pipeline:hotfix "<problem>" | /pipeline:hotfix <issue-number> [--inline|--subagent]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_WORKTREE_PREFIX`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Hotfix Agent

## Overview

`/pipeline:hotfix` is the **emergency lane**. It exists for cases where you want to file an audit-anchor issue, run a fix end to end, and open a PR — without going through the standard classify → plan → evaluate-plan → execute → evaluate-pr → auto-merge lifecycle.

It runs **in the current orchestrator session** (no out-of-session worker, no background worker session). You observe red→green→commit live and merge the PR by hand.

## Invariants

- **In-session.** The hotfix skill executes directly in the calling session. No dispatch to a worker session.
- **No pipeline labels.** No `--add-label` invocations for `plan-pending`, `plan-reviewed`, `plan-approved`, `in-progress`, or `pr-open`. The issue stays unlabelled (modulo whatever the user added by hand) so the standard `pipeline:run` orchestrator does not pick it up.
- **No evaluator gates.** No call to `/pipeline:classify-issue`, `/pipeline:plan-issue`, `/pipeline:evaluate-issue-plan`, `/pipeline:evaluate-issue-pr`, or `/pipeline:fullsend`. Explicitly: **no /pipeline:evaluate-issue-plan** dispatch, **no /pipeline:evaluate-issue-pr** dispatch.
- **No auto-merge.** The greenlight `scripts/auto-merge-gate.sh` does not fire. The PR sits open until the user merges manually.
- **PR base.** Targets `PIPELINE_BASE_BRANCH` (currently `staging` by default) — consistent with every other feature lane.

## Steps

1. **Parse arguments.** Detect whether `$1` is a numeric issue number (existing issue) or a quoted problem string (new issue to file). Parse `--inline` / `--subagent`. Default executor is `--subagent`. Reject combinations like passing both flags.

   ```bash
   ARGS=("$@")
   EXECUTOR="--subagent"   # default executor is --subagent
   ENTRY=""
   for a in "${ARGS[@]}"; do
     case "$a" in
       --inline)   EXECUTOR="--inline" ;;
       --subagent) EXECUTOR="--subagent" ;;
       *)          ENTRY="$a" ;;
     esac
   done
   if [ -z "$ENTRY" ]; then echo "usage: /pipeline:hotfix \"<problem>\" | <issue-number> [--inline|--subagent]" >&2; exit 1; fi
   ```

2. **Look up or file the issue.**

   - If `$ENTRY` is numeric: treat as an existing issue.
     ```bash
     N="$ENTRY"
     gh issue view "$N" --repo "$PIPELINE_REPO" --json number,title,body
     ```
   - Otherwise: file a new issue as the audit anchor and capture the new number.
     ```bash
     URL=$(gh issue create --repo "$PIPELINE_REPO" \
       --title "hotfix: $(echo "$ENTRY" | head -c 80)" \
       --body "$ENTRY"$'\n\n_Filed by /pipeline:hotfix as audit anchor — no pipeline labels applied._")
     N="${URL##*/}"
     ```

   Either path yields the issue number `$N` for later steps. No labels are added in this step.

3. **Snapshot original cwd and install the restoration trap.** The worktree `cd` is global to the orchestrator session. Without this trap an early-exit (subagent error, hook denial, user Ctrl-C) strands the session inside the worktree and breaks every subsequent unrelated turn.

   ```bash
   ORIG_PWD="$(pwd)"
   restore_cwd() { cd "$ORIG_PWD" 2>/dev/null || true; }
   trap restore_cwd EXIT ERR INT
   ```

   The trap MUST cover EXIT (normal flow), ERR (any non-zero exit under `set -e`), and INT (user interrupt). The explicit `cd` in step 7 is the happy path; the trap is the safety net.

4. **Create the worktree** by invoking the existing `scripts/setup-worktree.sh` helper (no changes to it). Branch naming is `feature/hotfix-<N>` so the existing branch-name parsers (e.g. `scripts/cleanup-worktree.sh`) keep working.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh" \
     --base "$PIPELINE_BASE_BRANCH" "feature/hotfix-$N" "$N"
   WT_PATH="$(pwd)/.claude/worktrees/${PIPELINE_WORKTREE_PREFIX}-${N}-hotfix-${N}"
   cd "$WT_PATH"
   ```

5. **Dispatch the fix in the current session.**

   - **`--subagent` (default).** Dispatch the same leaf executor PATH C and PATH D use:
     ```
     Agent(
       subagent_type: "tdd-implementer",
       description: "hotfix #<N>",
       prompt: "target=<relevant-dir>/  ...full issue body...  write failing test → minimum impl → commit"
     )
     ```
     The subagent runs inline in the current orchestrator session; output streams to the user live.

   - **`--inline`.** Drive TDD directly from the orchestrator:
     ```
     Skill(skill: "superpowers:test-driven-development")
     ```
     and proceed with red→green→commit by hand. No subagent dispatch.

6. **Open the PR.** Targets `PIPELINE_BASE_BRANCH`; no pipeline labels.

   ```bash
   if [ -z "$PIPELINE_BASE_BRANCH" ]; then echo "FATAL: PIPELINE_BASE_BRANCH unset; refusing to call gh pr create" >&2; exit 1; fi
   gh pr create \
     --repo "$PIPELINE_REPO" \
     --base "$PIPELINE_BASE_BRANCH" \
     --head "feature/hotfix-$N" \
     --title "hotfix: <short summary>" \
     --body "Closes #$N"$'\n\n_Filed via /pipeline:hotfix — bypassed plan/evaluate gates intentionally (emergency lane)._'
   ```

   Do NOT add `pr-open`, `in-progress`, or any other pipeline label to either the issue or the PR. The PR will not be picked up by the auto-merge gate — that's the design.

7. **Restore cwd explicitly and clear the trap.** Belt-and-braces: the trap is the safety net, the explicit `cd` is the happy path.

   ```bash
   cd "$ORIG_PWD"
   trap - EXIT ERR INT
   ```

8. **Print summary.** Report the issue URL, PR URL, branch name, worktree path, executor flag used, and a one-line reminder:

   > Emergency lane: this PR did NOT pass through evaluate-issue-pr. Review and merge manually.

## Boundary with PATH D

`/pipeline:hotfix` and **PATH D (`quick-fix`)** share the same `tdd-implementer` leaf executor, but they differ in session shape and review gate:

| | PATH D (`quick-fix`) | `/pipeline:hotfix` |
|---|---|---|
| Session | Separate worker session via `/pipeline:execute-issue-plan` | Current orchestrator session, in-session |
| Plan stage | Skipped (PATH D dispatch directly) | Skipped (emergency lane) |
| Evaluator | `/pipeline:evaluate-issue-pr` runs; auto-merge gate decides | No evaluator, no auto-merge |
| Labels | Standard lifecycle (`in-progress`, `pr-open`, `merged`) | No pipeline labels applied |

If you want the greenlight auto-merge gate, label the issue `quick-fix` and use `/pipeline:fullsend <N>` (PATH D) instead. If you want to watch the fix happen live and merge by hand, use `/pipeline:hotfix`.

## Safety notes

- **Worktree path safety.** `scripts/setup-worktree.sh` writes worktrees under `.claude/worktrees/` (a sub-path of the project root), so they pass `hooks/restrict_paths.py`. Do NOT introduce code that constructs `//`-prefixed paths or relies on substring path matching — the **issue #353** hook-bug family (`//` collapsing, substring matching, `..` escape) must not be regressed.
- **PR title sanitization.** The PR title MUST NOT contain unescaped CI-blocking markers (`[skip ci]`, `***NO_CI***`, etc.). The `hooks/check-ci-skip-markers.py` PreToolUse hook will block the `gh pr create` call if it sees them; wrap any marker in backticks (e.g. `` `[skip ci]` ``) if you need to describe one in the PR body.
- **Base-branch guard.** The explicit `[ -z "$PIPELINE_BASE_BRANCH" ]` check in step 6 is defense-in-depth alongside `hooks/enforce-base-branch.py` and the eval-time `baseRefName` assertion used by other lanes. Same pattern as `execute-issue-plan` Step 9b.
