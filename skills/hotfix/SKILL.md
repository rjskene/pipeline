---
name: hotfix
description: Emergency-lane hotfix — in-session worktree fix bypassing all pipeline lifecycle gates (classify/plan/evaluate/auto-merge). Files an issue (or uses an existing one), creates a worktree, runs the test/fix loop in the current orchestrator session, opens a PR. Usage: /pipeline:hotfix "<problem>" | /pipeline:hotfix <issue-number> [--inline|--subagent] [--auto-merge]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill
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

The bash code blocks below reference `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_WORKTREE_PREFIX`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Hotfix Agent

```
parse args → look up / file issue → snapshot cwd + trap → create worktree → dispatch fix (in-session) → open PR → restore cwd → summary
```

`/pipeline:hotfix` is the **emergency lane**: file an audit-anchor issue, run the fix end to end, open a PR — without the standard classify → plan → evaluate-plan → execute → evaluate-pr → auto-merge lifecycle. It runs in the **current** orchestrator session (red→green→commit live); merge by hand.

## Invariants

- **In-session.** Executes directly in the calling session. No dispatch to a worker session.
- **No pipeline labels.** None of `plan-pending`/`plan-reviewed`/`plan-approved`/`in-progress`/`pr-open` applied — the standard `pipeline:fullsend` orchestrator does not pick it up.
- **No evaluator gates.** Explicitly: no /pipeline:classify-issue, no /pipeline:plan-issue, no /pipeline:evaluate-issue-plan, no /pipeline:evaluate-issue-pr, no /pipeline:fullsend dispatch.
- **Auto-merge: manual by default, opt-in CI-only.** With no flag there is no auto-merge — the user merges manually. With `--auto-merge`, Step 6.5 runs `scripts/auto-merge-gate.sh` in `NO_VERDICT=1` mode (CI-only greenlight: every `statusCheckRollup` SUCCESS AND `mergeable == MERGEABLE` AND `mergeStateStatus == CLEAN` AND base `== $PIPELINE_BASE_BRANCH`, skipping the evaluator-verdict condition the emergency lane never produces) and merges on green. Never default.
- **PR base.** Targets `PIPELINE_BASE_BRANCH` (defaults to `staging`).

## Steps

1. **Parse arguments.** Detect whether `$1` is a numeric issue number (existing issue) or a quoted problem string (new issue to file). Parse `--inline` / `--subagent`; default is `--subagent`.

   ```bash
   ARGS=("$@")
   EXECUTOR="--subagent"   # default executor is --subagent
   AUTO_MERGE=0            # emergency lane must never surprise-merge — opt-in only
   ENTRY=""
   for a in "${ARGS[@]}"; do
     case "$a" in
       --inline)     EXECUTOR="--inline" ;;
       --subagent)   EXECUTOR="--subagent" ;;
       --auto-merge) AUTO_MERGE=1 ;;
       *)            ENTRY="$a" ;;
     esac
   done
   if [ -z "$ENTRY" ]; then echo "usage: /pipeline:hotfix \"<problem>\" | <issue-number> [--inline|--subagent] [--auto-merge]" >&2; exit 1; fi
   ```

2. **Look up or file the issue.**

   - If `$ENTRY` is numeric: treat as existing.
     ```bash
     N="$ENTRY"
     gh issue view "$N" --repo "$PIPELINE_REPO" --json number,title,body
     ```
   - Otherwise: file a new issue as the audit anchor and capture the number.
     ```bash
     URL=$(gh issue create --repo "$PIPELINE_REPO" \
       --title "hotfix: $(echo "$ENTRY" | head -c 80)" \
       --body "$ENTRY"$'\n\n_Filed by /pipeline:hotfix as audit anchor — no pipeline labels applied._")
     N="${URL##*/}"
     ```

   Either path yields `$N` for later steps. No labels are added.

3. **Snapshot original cwd and install the restoration trap.** The worktree `cd` is global to the orchestrator session — without this trap an early-exit (subagent error, hook denial, Ctrl-C) strands the session inside the worktree. The trap MUST cover EXIT (normal flow), ERR (non-zero under `set -e`), and INT (user interrupt); the explicit `cd` in step 7 is the happy path.

   ```bash
   ORIG_PWD="$(pwd)"
   restore_cwd() { cd "$ORIG_PWD" 2>/dev/null || true; }
   trap restore_cwd EXIT ERR INT
   ```

4. **Create the worktree** via `scripts/setup-worktree.sh`. Branch naming is `feature/hotfix-<N>` so existing parsers (e.g. `scripts/cleanup-worktree.sh`) keep working.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh" \
     --base "$PIPELINE_BASE_BRANCH" "feature/hotfix-$N" "$N"
   WT_PATH="$ORIG_PWD/.claude/worktrees/$PIPELINE_WORKTREE_PREFIX-${N}-hotfix-${N}"
   cd "$WT_PATH"
   ```

5. **Dispatch the fix in the current session.**

   - **`--subagent` (default).** Dispatch the same leaf executor PATH C and PATH D use (runs inline; output streams live):
     ```
     Agent(
       subagent_type: "tdd-implementer",
       description: "hotfix #<N>",
       prompt: "target=<relevant-dir>/  ...full issue body...  write failing test → minimum impl → commit"
     )
     ```

   - **`--inline`.** Drive TDD directly from the orchestrator (no subagent dispatch):
     ```
     Skill(skill: "superpowers:test-driven-development")
     ```

6. **Open the PR.** Targets `PIPELINE_BASE_BRANCH`; no pipeline labels.

   ```bash
   if [ -z "$PIPELINE_BASE_BRANCH" ]; then echo "FATAL: PIPELINE_BASE_BRANCH unset; refusing to call gh pr create" >&2; exit 1; fi
   PR_URL=$(gh pr create \
     --repo "$PIPELINE_REPO" \
     --base "$PIPELINE_BASE_BRANCH" \
     --head "feature/hotfix-$N" \
     --title "hotfix: <short summary>" \
     --body "Closes #$N"$'\n\n_Filed via /pipeline:hotfix — bypassed plan/evaluate gates intentionally (emergency lane)._')
   PR="${PR_URL##*/}"   # PR number, consumed by Step 6.5 when --auto-merge is set
   ```

   Do NOT add `pr-open`, `in-progress`, or any other pipeline label to either the issue or the PR. By default the PR will not be picked up by the auto-merge gate — that's the design. (When `--auto-merge` is set, Step 6.5 runs the CI-only gate explicitly; it still applies no labels.)

6.5. **Opt-in CI-only auto-merge (only when `AUTO_MERGE=1`).** Skip this step entirely unless the user passed `--auto-merge`. There is no evaluator verdict in the emergency lane, so this runs the shared gate in `NO_VERDICT=1` mode — a CI-only greenlight that still enforces every other check (base, CI rollup, mergeable, mergeStateStatus) and still honors the `MANUAL_MERGE` env / `manual-merge` label opt-outs.

   ```bash
   if [ "${AUTO_MERGE:-0}" = "1" ]; then
     source "${CLAUDE_PLUGIN_ROOT}/scripts/auto-merge-gate.sh"
     # Let freshly-created CI settle; a still-in-flight rollup would race to block-ci.
     # `|| true` so a long/never-completing watch falls through to one gate evaluation
     # rather than hanging the emergency lane indefinitely.
     gh pr checks "$PR" --repo "$PIPELINE_REPO" --watch --interval 30 || true
     GATE=$(NO_VERDICT=1 auto_merge_should_fire "$N" "$PR")
     if [ "$GATE" = "green" ]; then
       gh pr merge "$PR" --repo "$PIPELINE_REPO" --merge --delete-branch
       # The hotfix lane applies NO pipeline labels and `Closes #N` does NOT fire
       # against the `staging` base, so close the audit-anchor issue explicitly.
       # TODO(#655): refactor to scripts/finish-manual-merge.sh once it lands.
       gh issue close "$N" --repo "$PIPELINE_REPO" \
         --comment "Auto-merged via PR #$PR (hotfix --auto-merge, CI-only greenlight, no evaluator verdict)."
     else
       echo "[hotfix] --auto-merge gate returned '$GATE'; leaving PR #$PR for manual merge." >&2
     fi
   fi
   ```

   Do NOT `--add-label` here — the lane stays label-free regardless of `--auto-merge`.

7. **Restore cwd explicitly and clear the trap.**

   ```bash
   cd "$ORIG_PWD"
   trap - EXIT ERR INT
   ```

8. **Print summary.** Report the issue URL, PR URL, branch name, worktree path, executor flag used, and a one-line reminder:

   > Emergency lane: this PR did NOT pass through evaluate-issue-pr. Review and merge manually.

   Once the PR is hand-merged, run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-manual-merge.sh" <N> <PR>` to close the audit-anchor issue and record the merge (`Merged via PR #<PR>`). The hotfix lane applies no pipeline labels, so the `pr-open`/`manual-merge` removals are no-ops here (absorbed by the helper's idempotency) — the load-bearing effect is the issue close + merge note, since the PR's `Closes #N` does not fire against the `staging` base.

## Boundary with PATH D

`/pipeline:hotfix` and **PATH D (`quick-fix`)** share the same `tdd-implementer` leaf executor but differ in session shape and review gate:

| | PATH D (`quick-fix`) | `/pipeline:hotfix` |
|---|---|---|
| Invocation | `/pipeline:fullsend <N>` after `quick-fix` label | `/pipeline:hotfix "<problem>" \| <N>` directly |
| Session | spawned worker via `/pipeline:execute-issue-plan` | current orchestrator session, in-session |
| Plan stage | skipped (PATH D dispatch directly) | skipped (emergency lane) |
| Evaluator | `/pipeline:evaluate-issue-pr` runs | none |
| Auto-merge gate | fires on Approved verdict | off by default; `--auto-merge` fires CI-only (NO_VERDICT) |
| Lifecycle labels | `in-progress` → `pr-open` → `merged` | none applied |
| Who merges | pipeline (greenlight) | user (manually) |

## Safety notes

- **Worktree path safety.** `scripts/setup-worktree.sh` writes worktrees under `.claude/worktrees/` (a sub-path of the project root) so they pass `hooks/restrict_paths.py`. Do NOT introduce code that constructs `//`-prefixed paths or relies on substring path matching — the **issue #353** hook-bug family (`//` collapsing, substring matching, `..` escape) must not be regressed.
- **PR title sanitization.** The PR title MUST NOT contain unescaped CI-blocking markers (`[skip ci]`, `***NO_CI***`, etc.). The `hooks/check-ci-skip-markers.py` PreToolUse hook blocks the `gh pr create` call if it sees them; wrap any marker in backticks (e.g. `` `[skip ci]` ``) in the PR body if you need to describe one.
- **Base-branch guard.** The explicit `[ -z "$PIPELINE_BASE_BRANCH" ]` check in step 6 is defense-in-depth alongside `hooks/enforce-base-branch.py` and the eval-time `baseRefName` assertion. Same pattern as `execute-issue-plan` Step 9b.
