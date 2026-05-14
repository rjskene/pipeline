---
name: execute-issue-plan
description: Implement the approved plan for a GitHub issue. Run from inside the feature worktree. Usage: /pipeline:execute-issue-plan <issue_number>
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, mcp__playwright_*
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Execution Agent

You will receive an issue number as the argument (or from context). You should be running inside the correct feature worktree already. Perform these steps:

## Steps

**0b. CI-fix mode.** If `$PIPELINE_CI_FIX_CONTEXT` is non-empty, you were dispatched to fix a red CI run on an existing PR — not to implement a new plan. Skip steps 1–4 and step 9. Read the failure log at `$PIPELINE_CI_FIX_CONTEXT` and run `gh pr diff` to see the PR so far. Diagnose the failure, apply red→green→commit TDD discipline for the fix, run step 6 (Validate) once, then push the follow-up commit to the existing branch with `git push`. Do NOT call `gh pr create`. Do NOT change the `pr-open` label. Report the new commit SHA back to the orchestrator.

1. **Fetch the approved plan** — find the latest comment containing `## Implementation Plan`:
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body'
   ```
   This finds the LATEST plan comment (supports revisions — latest plan wins).
   If the output is empty or `null`, **STOP** and report: "No implementation plan found on issue #N. Run `/pipeline:plan-issue N` first."
   Read the plan carefully before proceeding.

2. **Read project conventions:**
   Read `CLAUDE.md` in the current working directory (worktree root).

3. **Dependency check — issue #5 only:**
   If this is issue #5 (project-numbers), verify that `feature/schema-cleanup` has been merged:
   ```bash
   gh pr list --repo $PIPELINE_REPO --state merged --json headRefName --jq '[.[].headRefName]'
   ```
   If `feature/schema-cleanup` is NOT in the list, **STOP** and report: "Issue #5 is blocked — feature/schema-cleanup has not been merged yet."

4. **Mark as in-progress:**
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "in-progress" --remove-label "plan-approved"
   ```

5. **Implement the approved plan.**

   The plan's `**Tasks (ordered):**` section tells you the path-specific Task 0 directive (PATH A: flat edits, PATH B: invoke `superpowers:test-driven-development`, PATH C: dispatch `tdd-implementer` subagents with `target=<dir>` sentinels). Follow it exactly.

   The pipeline orchestrator's `--append-system-prompt` (injected by `spawn-claude.sh` based on this issue's labels — see `PIPELINE_PATH_<X>_SKILLS_EXECUTE` + `PIPELINE_PATH_<X>_SKILL_ARGS_EXECUTE_*`) may also inject path-specific skill invocations. Earlier versions additionally used `PIPELINE_PATH_<X>_REVIEWER_EXECUTE` to dispatch `code-reviewer` as the FINAL tool call of the session. This skill now owns the review flow explicitly (step 8 below, BEFORE `gh pr create`). Leaving `PIPELINE_PATH_<X>_REVIEWER_EXECUTE` unset in `pipeline.config` is the recommended configuration; if it is set, the system prompt's end-of-session dispatch becomes a belt-and-suspenders redundancy, which is harmless.

   In all cases:
   - Implement ONLY what the plan specifies. No scope creep.
   - Never commit directly to main.
   - Never use `--no-verify` or `--force`.
   - When the plan or issue references a GH Actions CI-blocking marker (the bracketed forms of `skip ci`, `ci skip`, `skip-ci`, `ci-skip`, `no ci`, `no-ci`, plus `***NO_CI***`), do NOT propagate the literal marker into any `git commit -m`, `gh pr create --title`, or `gh pr create --body` argument. Substitute a safe form: backticked `` `skip ci` ``, hyphenated `skip-ci`, or `skip CI` (no brackets). The `check-ci-skip-markers` PreToolUse hook blocks the literal form to prevent silent workflow skips on the very PR that is fixing CI behavior.

6. **Validate — types, tests, server, and UI:**

   **6a. Type check:**
   ```bash
   $PIPELINE_TYPECHECK_CMD
   ```
   Fix any type errors before proceeding.

   **6b. Run tests:**
   ```bash
   $PIPELINE_TEST_CMD
   ```
   Fix any failures before proceeding.

   **6c. Visual validation with Playwright** (Linux only):
   Use the Playwright MCP tools to verify the UI renders correctly. The MCP server is configured in `.mcp.json`.
   - Navigate to the frontend URL (e.g., `http://localhost:<frontend-port>`)
   - Take a screenshot to verify the page loads without errors
   - If your changes affect specific UI elements, navigate to those views and verify they render
   - Check the browser console for JavaScript errors (use `browser_console_messages` tool)
   - If visual issues are found, fix them and re-validate

   **Important:** Do not skip visual validation for UI changes. For backend-only changes, server health check + tests are sufficient.

7. **Self-review checkpoint before opening PR.**

   Before opening the PR, perform a self-review:
   - Re-read the plan from step 1 and verify every item was implemented
   - Run `git diff --stat` to check no unintended files were modified
   - Grep for leftover debug code (`console.log`, `print(`, `debugger`, `TODO`, `FIXME`)
   - Verify no scope creep — nothing implemented beyond what the plan specifies

   Fix any issues found before proceeding.

8. **Pre-PR code review loop.**

   This step runs BEFORE `gh pr create`. The goal is to catch plan-compliance gaps and real bugs while the branch is still local-only, so the first external reviewer (pipeline `evaluate-issue-pr` or a human) sees a polished PR.

   **8a. Author self-check.** Invoke `superpowers:requesting-code-review` as the author self-check:
   ```
   Skill(skill: "superpowers:requesting-code-review")
   ```
   Pass the plan comment body (from step 1) as context. The skill verifies plan requirements are met, tests pass, and CI-equivalent checks are green locally. If it flags a gap, fix it and re-run step 6 (validate) before continuing.

   **8b. Independent reviewer dispatch.** Dispatch a separate code-reviewer subagent:
   ```
   Agent(
     subagent_type: "superpowers:code-reviewer",
     description: "Independent review of the implementation for issue #<N> against the approved plan",
     prompt: "<full plan comment body + git diff $PIPELINE_BASE_BRANCH..HEAD — flag plan-compliance gaps and real bugs; do not refactor>"
   )
   ```
   The reviewer returns a list of findings (or "LGTM").

   **8c. Triage findings.** Invoke `superpowers:receiving-code-review`:
   ```
   Skill(skill: "superpowers:receiving-code-review")
   ```
   Pass the reviewer's output. The skill classifies each finding as:
   - **must-fix** (plan-compliance gap, test gap, real bug) → fix
   - **nice-to-have** (style, rename) → skip unless trivial
   - **incorrect** (reviewer misread) → reject with a one-line rationale in the follow-up commit message

   Path-specific constraints when applying must-fixes:
   - **PATH C (`multi-task`):** any must-fix that touches impl code MUST go through a NEW `tdd-implementer` dispatch. The orchestrator cannot `Edit`/`Write` impl files directly — the `enforce-path-c-delegation` hook will block it.
   - **PATH B (standard):** must-fix code edits must still follow red→green→commit discipline (write a test for the missed behavior, watch fail, fix, watch pass, commit).
   - **PATH A (`docs-only`):** must-fix edits are direct.

   **8d. Commit fixes.** Commit each must-fix as its own `fix(review): ...` commit so the PR history shows the review loop. If zero must-fixes were applied, skip this sub-step.

   **8e. Re-validate.** Re-run step 6 (type check + tests + visual validation) once more to confirm the review fixes did not regress anything.

9. **Open a pull request.**

   **9a. Derive the PR title from the issue.** The PR title must be a strict
   Conventional-Commits string (`feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert(<scope>)?: <summary>`)
   so release-please can drive versioning + CHANGELOG. Issue titles are intentionally
   expressive (`bug(...)`, `epic(...)`, `skill: ...`) and must NOT pass through verbatim.
   Run the helper to derive it:

   ```bash
   PR_TITLE=$("${CLAUDE_PLUGIN_ROOT}/scripts/derive-pr-title.sh" <N>)
   rc=$?
   if [ "$rc" -eq 2 ]; then
     # exit 2 = tracker (epic title or `tracker` label) — these never get PRs.
     echo "ABORT: Issue #<N> is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
     exit 1
   elif [ "$rc" -ne 0 ]; then
     echo "ABORT: derive-pr-title.sh failed with exit $rc for issue #<N>" >&2
     exit 1
   fi
   ```

   The helper applies this rule table (source of truth lives in `scripts/derive-pr-title.sh`):

   | Order | Condition | Action |
   |-------|-----------|--------|
   | 1 | Labels include `tracker` | exit 2 (refusal) |
   | 2 | Title matches `^epic\(` | exit 2 (refusal) |
   | 3 | Title is already Conventional Commits | passthrough |
   | 4 | Title matches `^bug\(<scope>\):` | rewrite to `fix(<scope>): <rest>` |
   | 5 | Labels include `bug` | `fix(<scope-or-general>): <summary>` |
   | 6 | Labels include `enhancement` | `feat(<scope-or-general>): <summary>` |
   | 7 | default | `chore(general): <summary>` |

   **9b. Open the PR:**

   ```bash
   gh pr create \
     --repo $PIPELINE_REPO \
     --title "$PR_TITLE" \
     --base $PIPELINE_BASE_BRANCH \
     --body "$(cat <<'EOF'
   Closes #<N>

   ## Summary
   <bullet points summarising what changed>

   ## Test plan
   - [ ] `PIPELINE_TEST_CMD` — all tests pass
   - [ ] Feature works end to end
   EOF
   )"
   ```

   Both `--title` and `--body` values are scanned by the `check-ci-skip-markers` hook before this command runs. If you need to *describe* a marker in the PR body, wrap it in backticks (e.g. `` `[skip ci]` ``) so GH Actions does not honor it.

10. **Mark as pr-open:**
    ```bash
    gh issue edit <N> --repo $PIPELINE_REPO --add-label "pr-open" --remove-label "in-progress"
    ```

11. **Report:** "PR opened for #N: <PR URL>"

## Handling evaluation feedback

If the evaluate-issue-pr agent flags the PR with actionable feedback and the executor session is still active:

Invoke `superpowers:receiving-code-review` to handle the feedback:
```
Skill(skill: "superpowers:receiving-code-review")
```
Pass the evaluation comment as context. It will guide you through verifying each feedback item with technical rigor before implementing changes.

## Constraints
- Implement ONLY what the approved plan says.
- Never commit to main.
- All PRs target `PIPELINE_BASE_BRANCH` (the configured base), never `main`. Always pass `--base $PIPELINE_BASE_BRANCH` to `gh pr create`.
- Never use `--no-verify` or `--force`.
- Never skip build verification (`PIPELINE_TEST_CMD` from the sourced config).
- Executor does NOT merge PRs. All merging is handled by the pipeline orchestrator.
