---
name: evaluate-issue-pr
description: Independently evaluate a PR's implementation against its approved plan. Run from inside the feature worktree. Can make fixes. Usage: /evaluate-issue-pr <issue_number>
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, mcp__playwright_*
---

# Issue Evaluator

You are a senior engineer performing a code review of a PR against its approved implementation plan. You have NO context from the agent that wrote this code — you see only the plan and the diff. Your job is to verify the implementation matches the spec, catch bugs the implementer missed, and make minimal fixes where possible.

**Rules:**
- Verify every plan item was implemented — check them off one by one
- Look for what the implementer DIDN'T do, not just what they did
- If you find issues: fix small ones (typos, missing imports, off-by-one), flag large ones
- "Significant rework" = changes touching more than 3 files or requiring new design decisions. Flag these for user review instead of fixing.
- Never refactor, add features, or improve code beyond what the plan specifies

## Steps

1. **Fetch the approved plan:**
   ```bash
   gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body'
   ```
   If empty, STOP: "No implementation plan found for issue #N."

2. **Fetch the PR number and diff:**
   ```bash
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   PR_NUM=$(gh pr list --repo HTS-COLLAB-ORG/claude-pipeline --head "$BRANCH" --json number --jq '.[0].number')
   gh pr diff $PR_NUM --repo HTS-COLLAB-ORG/claude-pipeline
   ```
   If no PR found, STOP: "No open PR found for branch $BRANCH."

3. **Read project context:**
   - `CLAUDE.md` in worktree root

4. **Two-phase review.**

   The pipeline orchestrator's `--append-system-prompt` (injected by `spawn-claude.sh` based on this issue's labels — see `PIPELINE_PATH_<X>_SKILLS_EVALUATE_PR` + `PIPELINE_PATH_<X>_SKILL_ARGS_EVALUATE_PR_*`) already requires you to invoke the path-specific review skills before doing anything else. Follow that skill's guidance to run the two review phases (plan compliance + code quality) and combine findings:
   - **Task 1 — Plan compliance:** For each item in the plan: verify "Files to change" were modified and changes match descriptions. Verify "DB schema changes", "API changes", "Frontend changes", "Test changes" were made or correctly skipped. Flag scope creep (implemented but not planned) and missing work (planned but not implemented).
   - **Task 2 — Code quality:** Run ` 2>&1 | head -50` and `for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done 2>&1 | tail -30`. Review the diff for: leftover debug code, console.logs, TODO comments; missing error handling at system boundaries; security issues (injection, XSS, unsanitized input); type safety issues not caught by tsc; test coverage for every implemented feature.

   If the Skill tool is unavailable, perform the review inline:

   **Phase 1 — Plan compliance.** For each item in the plan:
   - "Files to change" — verify each file was modified, and the changes match the plan's description
   - "DB schema changes" — verify schema changes were made (or correctly skipped)
   - "API changes" — verify routes/endpoints match
   - "Frontend changes" — verify components/UI match
   - "Test changes" — verify tests were added/updated as specified
   - Flag anything implemented that the plan DIDN'T specify (scope creep)
   - Flag anything the plan specified that WASN'T implemented (missing work)

   **Phase 2 — Code quality.** Run automated checks and review the diff:
   ```bash
    2>&1 | head -50
   for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done 2>&1 | tail -30
   ```
   Also review the diff for:
   - Leftover debug code, console.logs, TODO comments
   - Missing error handling at system boundaries (user input, external APIs)
   - Security issues (injection, XSS, unsanitized input)
   - Type safety issues not caught by tsc
   - Test coverage: verify tests exist for every implemented feature

5. **Check CI workflow status.**

   Verify every required GitHub Actions check passes before posting a verdict. A red PR must never receive an Approved verdict.

   **5a. Detect CI presence.** If the PR has no checks configured, skip this step entirely:
   ```bash
   CHECK_COUNT=$(gh pr view $PR_NUM --repo HTS-COLLAB-ORG/claude-pipeline --json statusCheckRollup --jq '.statusCheckRollup | length')
   ```
   If `CHECK_COUNT` is 0, log `"CI: none configured — skipping status check"` and proceed to Step 6.

   **5b. Wait for in-progress checks to settle.** Use a single bounded wait via `Bash` with `run_in_background: true`:
   ```bash
   timeout 600 gh pr checks $PR_NUM --repo HTS-COLLAB-ORG/claude-pipeline --watch --fail-fast --interval 30
   ```
   This is a one-shot 10-minute wait (30-second poll interval). You will receive a completion notification when all checks finish, a check fails (`--fail-fast`), or the timeout expires. Do NOT wrap this in a `while ... sleep ... grep` poll loop — the project convention is `Bash run_in_background` for bounded waits.

   **5c. Inspect final check state.** After the background wait completes (or times out), read the rollup:
   ```bash
   gh pr view $PR_NUM --repo HTS-COLLAB-ORG/claude-pipeline --json statusCheckRollup \
     --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED") | {name: .name, conclusion: .conclusion, url: .detailsUrl}'
   ```

   For each failed check, extract the run ID from `detailsUrl` and fetch the first error line:
   ```bash
   RUN_ID=$(echo "$DETAILS_URL" | sed 's|.*/runs/\([0-9]*\)/.*|\1|')
   gh run view "$RUN_ID" --repo HTS-COLLAB-ORG/claude-pipeline --log-failed 2>&1 | head -20
   ```
   Fallback if `detailsUrl` parsing yields an empty or non-numeric RUN_ID:
   ```bash
   BRANCH=$(git rev-parse --abbrev-ref HEAD)
   RUN_ID=$(gh run list --repo HTS-COLLAB-ORG/claude-pipeline --branch "$BRANCH" --status failure --limit 1 --json databaseId --jq '.[0].databaseId')
   gh run view "$RUN_ID" --repo HTS-COLLAB-ORG/claude-pipeline --log-failed 2>&1 | head -20
   ```

   **5d. Decide verdict interaction:**
   - Any check FAILURE or CANCELLED → you MUST NOT post an "Approved" verdict, regardless of plan compliance and code quality findings.
   - If the failure looks fixable within the existing fix budget (≤3 files, no new design decisions): attempt the fix in-worktree, commit, `git push`, and re-run the bounded wait from 5b with a fresh 10-minute timeout.
   - If the failure exceeds the fix budget, persists after one fix attempt, or the wait timed out with checks still in progress: post a "Flagged" verdict that includes the failing job names and the first error line from 5c in the `**CI status:**` section of the evaluation comment (see Step 9).

6. **Visual validation** (if UI changes exist in the diff):
   Check if Playwright MCP is available:
   ```bash
   cat .mcp.json 2>/dev/null
   ```
   If available and the platform supports it (Linux):
   - Navigate to affected views, take screenshots
   - Check browser console for JS errors
   - Verify the UI matches the plan's description

   If unavailable, note: "Visual validation skipped — Playwright MCP not available."

7. **If fixable issues found (3 files or fewer, no new design decisions):**
   - Fix them in the worktree
   - Commit: `git commit -m "fix: evaluation fixes for #<N> — <summary>"`
   - Push to the feature branch: `git push`
   - Re-run tsc + tests to confirm fixes don't break anything

8. **Check for branch divergence before merge decision:**
   ```bash
   git fetch origin staging
   git log --oneline HEAD..origin/staging | head -5
   ```
   If staging has advanced, rebase:
   ```bash
   git rebase origin/staging
   ```
   If conflicts are complex (semantic, not whitespace), flag for user review.

9. **Post evaluation comment on the PR:**
   ```bash
   gh pr comment $PR_NUM --repo HTS-COLLAB-ORG/claude-pipeline --body "<evaluation>"
   ```

   Format:
   ```markdown
   ## Evaluation

   **Verdict:** Approved / Flagged for user review

   **Plan compliance:**
   - [x] <plan item> — implemented correctly
   - [ ] <plan item> — missing or incorrect: <detail>

   **Code quality:** <findings or "No issues found">

   **CI status:** All checks passed / No CI configured / FAILED: <job names> — <first error line> / Timed out (checks still in progress)

   **Fixes applied:**
   - `<commit hash>` — <description>
   (or "None")

   **Remaining issues:** (if flagged)
   - <what needs human attention and why>
   ```

10. **Report verdict:**
    - If **Approved**: "PR #X approved — ready for merge."
    - If **Flagged**: "PR #X flagged for review: <summary of remaining issues>"
    The evaluator never merges. Merging is handled by the pipeline orchestrator (step 8 of the pipeline skill) only after the user explicitly confirms.

## Constraints
- Do NOT read the executor's session logs or conversation history
- Only inputs: plan comment, PR diff, codebase in worktree
- Fixes must be minimal: typos, missing imports, small bugs. NOT refactoring.
- If fix requires touching >3 files or making design decisions, flag instead of fixing
- Never skip tsc or test validation
- All PRs target staging. All commits go to the feature branch.
- Evaluator does NOT merge, close issues, or change `pr-open` labels — only reviews, posts verdict, and (optionally) rebases against the base branch.
