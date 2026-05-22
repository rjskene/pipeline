---
name: fullsend
description: Run the full pipeline autonomously end-to-end (classify → plan → evaluate → execute → evaluate PR → auto-merge greenlit PRs) without intermediate confirmations. Usage: /pipeline:fullsend [issue_numbers...] [--manual-merge]
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

# Full Send — the autonomous entry point

`/pipeline:fullsend` is the canonical autonomous entry to the pipeline. It chains classify → plan → eval-plan → execute → eval-pr → greenlight-merge across a slate of issues without intermediate confirmations.

```
slate → wave plan → classify+plan (waves) → eval-plan → approve → execute → eval-pr → greenlight → merge
```

Invoked two ways: (1) directly as `/pipeline:fullsend [issue_numbers...] [--manual-merge]` — the canonical entry point; (2) via the back-compat magic-string delegator in `/pipeline:run` — when a user prompt to `/pipeline:run` contains the token `full send` / `full-send` / `fullsend` (case-insensitive), `/pipeline:run` invokes this skill via `Skill(skill: "pipeline:fullsend", args: "<argv>")` with the original argv and stops.

Argv shape: `[issue_numbers...] [--manual-merge]`, position-independent (the flag-parsing rule below preserves the prior behavior).

PATH D (quick-fix) is path-agnostic to fullsend: the slate dispatcher does not branch on D. PATH-D-specific behavior (auto-flip plan-pending → plan-approved, inline tdd-implementer execute dispatch, Step 8 skip) is owned entirely by /pipeline:run (skills/run/SKILL.md Step 4 and Step 6) and /pipeline:execute-issue-plan (skills/execute-issue-plan/SKILL.md Step 8 early-return). No fullsend code change is required.

## Wave plan (pre-think)

Before any dispatch, fullsend pre-thinks the slate via `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/plan-waves.sh --stage=classify <ready-issue-numbers>` and captures stdout as the wave plan. Waves are processed serially; within a wave, issues dispatch in parallel. `plan-waves.sh` groups issues honoring (1) priority tiers, (2) explicit `blocked by #N` / `depends on #N` annotations in issue bodies, and (3) shared-file conflicts extracted via body-substring grep — when two issues touch the same file path, the second is deferred. The `--stage=classify` flag skips file-conflict detection because classify/plan agents are read-only, so cross-references in issue bodies must not over-serialize them.

```
Wave 1: classify #101, #102, #103 in parallel
Wave 2: classify #104 (serial — shares skills/run/SKILL.md with #101)
Wave 3: classify #105 (serial — blocked by #104)
Wave 4: classify #106, #107 in parallel
Wave 5: classify #108 in parallel
```

Gated by `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED` (default `true`); when `false`, fullsend falls back to single-blast parallel dispatch. The same wave-by-wave discipline applies to plan-issue dispatch in Step 1b — the wave plan is reused; the planner is not re-run.

## Greenlight matrix

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, fullsend auto-squash-merges iff all four conditions hold; otherwise the PR is left for manual merge with a `block-*` reason token.

```
| # | Condition                                                | Source                              |
|---|----------------------------------------------------------|-------------------------------------|
| 1 | Latest `## Evaluation` has `**Verdict:** Approved`       | gh pr view --json comments          |
| 2 | Every statusCheckRollup entry `conclusion == SUCCESS`    | gh pr view --json statusCheckRollup |
| 3 | `mergeable == MERGEABLE`                                 | gh pr view --json mergeable         |
| 4 | `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE) | gh pr view --json mergeStateStatus |
```

**block-base-mismatch** is enforced as defense-in-depth — PR `baseRefName` must equal `PIPELINE_BASE_BRANCH` (see #295). Order of evaluation: env (`MANUAL_MERGE=1`) → label (`manual-merge`) → verdict → base-mismatch → CI rollup → mergeable → mergeStateStatus. Tokens: `green`, `block-flag`, `block-label`, `block-verdict`, `block-base-mismatch`, `block-ci`, `block-mergeable`, `block-mergestate`.

**Three opt-outs:** (1) `FULL SEND --manual-merge` — flag may appear anywhere in argv (cannot collide with issue numbers, which are bare integers); (2) `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations; (3) a `manual-merge` label on the issue for per-issue control without re-typing the flag.

## Auto-merge ownership

The gate logic lives in `scripts/auto-merge-gate.sh` (function `auto_merge_should_fire <issue> <pr>` returning a single token). `/pipeline:evaluate-issue-pr` Step 11 fires the gate inline immediately after posting its Approved verdict — that is the primary auto-merge path. Fullsend's Step 8 (Report) is the **fallback** auto-merge path; it re-runs the gate only for any `pr-open` issue the evaluator did not already auto-merge (e.g. the evaluator crashed between verdict post and gate fire). Release-please PRs are out of scope of this gate; they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` (Step 7b), unchanged. This section names ownership; do not re-document the gate body — that's evaluate-issue-pr's territory.

1. **Plan**

   **1a. Ingest attachments for the slate.** For each issue in the slate (the ready-issue set being processed this wave), run `fetch-issue-attachments.sh` so downstream classify/plan/execute/evaluate-pr agents have screenshots and binary evidence available locally:

   ```bash
   for N in <slate-issue-numbers>; do
     PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh" "$N" 2>/dev/null \
       | head -1
   done
   ```

   The helper is idempotent — repeat invocations cost zero `gh api` calls. The `head -1` cap keeps wave-log output to one line per issue. This is the autonomous-mode ingestion site; `/pipeline:run` step 0 does NOT fetch attachments. Interactive single-issue planning fetches at `/pipeline:plan-issue` step 3b instead.

   **1b. Dispatch classify and plan.** Process wave by wave per the wave plan above — before dispatching plan-issue, run `/pipeline:classify-issue N` for every ready issue that lacks a fresh Classification comment (dispatch in parallel, one Agent per issue). Each classify run writes the Classification comment AND applies the path label (`docs-only` or `multi-task`). Cached issues skip dispatch. Then run `/pipeline:plan-issue N` for every issue with no pipeline label (in parallel, one Agent per issue). Wait for all to complete.
   - **Verify plan comments:** After all plan-issue agents complete, for each issue that was targeted (had no pipeline label at the start of this step), confirm a plan comment was posted:
     ```bash
     PLAN_COUNT=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
     ```
     If any targeted issue has `PLAN_COUNT == 0` (regardless of whether `plan-pending` was added), the plan-issue agent failed. Re-run `/pipeline:plan-issue N` for that issue (max 1 retry). If still missing after retry, skip the issue and flag it in the final report as "Skipped (plan not posted)".
2. **Evaluate plans** — run `/pipeline:evaluate-issue-plan N` for every `plan-pending` issue (in parallel, one Agent per issue). Wait for all to complete.
3. **Re-plan loop** — for any issue whose evaluation verdict is "Revise": re-run `/pipeline:plan-issue N`, then `/pipeline:evaluate-issue-plan N`. Repeat until all pass (max 3 iterations per issue). If an issue still fails after 3 iterations, skip it and flag it in the final report.
4. **Approve** — for every issue now at `plan-reviewed`, run:
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-approved" --remove-label "plan-reviewed"
   ```
5. **Set up worktrees** — run `setup-worktree.sh` for each `plan-approved` issue (sequentially). Full invocation signature:

   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh [--base <base>] <branch-name> <issue-number>
   ```

   Both positional args are required. `<branch-name>` MUST be `feature/<slug>` where `<slug>` is derived from the issue title (lowercase, hyphens, short) — same convention as `skills/run/SKILL.md` ("Branch and worktree naming convention"). `<issue-number>` is the bare integer.

   Worked example:

   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/setup-worktree.sh feature/gmail-ci-filter 81
   ```

   The script defaults to `PIPELINE_BASE_BRANCH` from `pipeline.config`; pass `--base` only if you need to override (e.g., orchestrator running on a non-default branch).

   **Do NOT invoke with only the issue number** — the script will reject it as of #350. A bare integer like `setup-worktree.sh 81` fails the branch-prefix guard because `81` is not a `feature/<slug>` shape; without that guard, the worktree would silently land on a branch literally named `81` and every downstream stage would break.
6. **Execute** — launch all worktrees via the tmux queue runner with skip-permissions enabled (equivalent to user answering "tmux / y" at the launch prompt). Launch the queue runner via `Bash` with `run_in_background: true` — do NOT use a foreground `while ... sleep ... grep` poll loop. Wait for completion using: `timeout 7200 bash -c 'tail -F "$(ls -t .claude/logs/queue-*.log | head -1)" | grep -m1 "EVENT: queue-complete"'` (also via `run_in_background`). Status updates are emitted automatically by the queue runner every 3 minutes (configurable via `STATUS_INTERVAL`).
6b. CI-fix loop — gated on `[ "${PIPELINE_CI_FIX_LOOP_ENABLED:-false}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED:-false}" = "true" ]`. For each `pr-open` issue, fullsend invokes `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-ci-fix-loop.sh <N>` and parses the emitted `ACTION=` line. Act per the table:

   | ACTION | Behavior |
   |--------|----------|
   | `green` | leave the issue for step 7 (Evaluate PRs). |
   | `pending` | defer; in single-pass full send, treat as green so step 7 still runs. |
   | `red-retry` | autonomous mode: fire `PIPELINE_REPO="$PIPELINE_REPO" bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-queue.sh --ci-fix <N> <LOG>` in the background. Interactive mode: propose "re-dispatch executor on #N (CI red, retry budget <NEXT>/<BUDGET>)" as a candidate action. |
   | `red-budget-exhausted` | issue is already labelled `human` by the helper; mark "Flagged (CI persistent failure)" in the final report and skip evaluate-issue-pr for that issue. |

   `check-ci-fix-loop.sh` is the authoritative source for retry-counter encoding (`pipeline.ci-retries: <n>` issue comment), tail-truncated failure-log path (`.claude/logs/ci-fix-<N>-attempt-<n>.log`), and `human` label application on budget-exhaust.

7. **Evaluate PRs** — once all agents finish (queue complete), run `/pipeline:evaluate-issue-pr N` for every `pr-open` issue (via `run-queue.sh --skip-permissions --skill evaluate-issue-pr`). Launch this queue via `Bash` with `run_in_background: true` as described in step 6.
7b. **Auto-merge green release PRs (opt-in)** — runs after step 7 (Evaluate PRs) and before step 8 (Report). Only fires when `PIPELINE_RELEASE_PR_AUTO_MERGE=true` AND at least one release PR has `ci=pass`. Feature PRs land first; the release PR consolidates them so version bumps + CHANGELOG stay coherent.

   ```bash
   if [ "${PIPELINE_RELEASE_PR_AUTO_MERGE:-false}" = "true" ]; then
     while IFS= read -r line; do
       [ -z "$line" ] && continue
       PR_NUM=$(echo "$line" | sed -n 's/^pr=\([0-9][0-9]*\).*/\1/p')
       CI=$(echo "$line" | sed -n 's/.* ci=\([a-z]*\) .*/\1/p')
       if [ "$CI" = "pass" ] && [ -n "$PR_NUM" ]; then
         gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --squash --delete-branch \
           || echo "WARN: failed to merge release PR #$PR_NUM"
       else
         echo "SKIP: release PR #$PR_NUM ci=$CI (auto-merge only on green)"
       fi
     done <<< "$(PIPELINE_REPO="$PIPELINE_REPO" bash "$CLAUDE_PLUGIN_ROOT/scripts/list-release-prs.sh" 2>/dev/null || true)"
   fi
   ```

   Default is **off** — existing repos that gate releases behind manual review are not surprised on upgrade. Step 8's final-report table should include any merged release PRs as their own section.
8. **Report** — print a summary table of all issues with their final stage and any flags. Include a **Classification mismatch** column showing, for each issue, the current-label path vs. the recommended path when they diverged (else blank):
   ```
   FULL SEND COMPLETE
   ================================================================
   Issue  Title                    Classification mismatch   Auto-merged?   Result
   --------------------------------------------------------------------------------
   #N     <title>                  B / C (med)               no (block-ci)  PR approved / Flagged / Skipped (plan failed)
   #N     <title>                                            yes (step8)    PR merged
   ================================================================
   The `Auto-merged?` column reflects Step 8's outcome per PR: `yes (eval)` — the evaluator's Step 11 already merged it; `yes (step8)` — Step 8 merged it on the greenlight path; `no (<block-reason>)` — manual merge required.
   ```
9. **Stop** — do NOT merge unless the greenlight matrix held in Step 8. Auto-merged PRs are already listed in the report's `Auto-merged?` column. Wait for explicit user confirmation before any non-greenlight merge.

**Constraints during full send:**

Slate-pre-hygiene (housekeeping, worktree cleanup, discovery) is owned by `/pipeline:run`; fullsend assumes a clean slate and does not re-implement that flow.

- Issues labeled `PIPELINE_LABELS_EXCLUDED` are always skipped.
- Issues labeled `PIPELINE_LABELS_LATER` are shown in the final report (stage = `PIPELINE_LABELS_LATER`) but not processed.
- Issues labeled `PIPELINE_LABELS_HUMAN` are shown in the final report (stage = `PIPELINE_LABELS_HUMAN`) but never processed by autonomous full send. These need a human in the loop — usually for architecture decisions, cross-platform validation, production deploy risk, or items where the planner can't make the right call without you. They must be picked up manually with `/pipeline:plan-issue` / `/pipeline:execute-issue-plan`, never via full send.
- Issues labeled `PIPELINE_LABELS_BRAINSTORM` are shown in the final report (stage = `PIPELINE_LABELS_BRAINSTORM`) but never processed by autonomous full send — same handling as `PIPELINE_LABELS_HUMAN`. The body is open-ended discussion/architectural critique, not a commit-to-act spec. Manual pickup via `/pipeline:plan-issue` is allowed once the idea crystallizes.
- Blocked issues (blocked-by dependency not yet merged) are skipped; noted in final report as "Blocked".
- The re-plan loop cap of 3 prevents infinite loops on stubborn issues.
- If any stage fails unexpectedly (script error, API failure), stop full send and report the failure with enough detail for the user to diagnose.
