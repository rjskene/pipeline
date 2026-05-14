---
name: plan-issue
description: Produce an implementation plan for a specific GitHub issue, post it as a comment, and add the plan-pending label. Usage: /pipeline:plan-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

# Planning Agent

You will receive an issue number as the argument (or from context). Perform these steps:

## Steps

1. **Fetch issue details and existing comments:**
   ```bash
   gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json number,title,body
   gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Analyze existing comments** — look for:
   - **Prior plans**: comments containing `## Implementation Plan` (posted by the planning agent or user)
   - **User feedback**: any comments from the repo owner (rjskene) that are NOT plans — these are revision requests
   - If user feedback exists on an existing plan, this is a **plan revision**. The revised plan MUST address every point in the user's feedback. Call out what changed with a `**Changes from previous plan:**` section at the top.

3. **Read project context:**
   - Read each file listed in the project's context files config: CLAUDE.md

3a. **Determine PATH** — the executor's discipline depends on the path label, so the plan must include a path-specific Task 0:

   ```bash
   LABELS=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json labels --jq '.labels[].name')
   if echo "$LABELS" | grep -qx "docs-only"; then
     PATH_LETTER=A
   elif echo "$LABELS" | grep -qx "multi-task"; then
     PATH_LETTER=C
   else
     PATH_LETTER=B
   fi
   # Fallback: if the label is missing AND a Classification comment exists,
   # parse `recommended_path` from its body. If still indeterminate, default
   # to B. Label always wins.
   if [ -z "$PATH_LETTER" ]; then
     CACHED=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
       --jq '[.comments[] | select(.body | contains("## Classification"))] | last | .body' \
       | grep -oE 'recommended_path:\*\* [ABC]' | awk '{print $2}' | head -1)
     case "$CACHED" in A|B|C) PATH_LETTER="$CACHED" ;; *) PATH_LETTER=B ;; esac
   fi
   echo "Planning issue #<N> as PATH $PATH_LETTER"
   ```

4. **Explore the codebase** — use Glob, Grep, and Read to find all files relevant to this issue. Look at:
   - Schema files if the issue touches data
   - Route files if the issue touches API
   - Frontend components if the issue touches UI
   - Test files if tests need updating

5. **Generate the implementation plan.**

   Invoke `superpowers:writing-plans` to structure the plan:
   ```
   Skill(skill: "superpowers:writing-plans")
   ```
   - Pass the issue title, body, any existing plan comments, your codebase findings from step 4, AND the detected `PATH_LETTER` from step 3a.
   - Tell it: "Do NOT save the plan to a file. Return the plan content directly."
   - **Important:** "Return the plan content directly" means return it to THIS agent (the plan-issue agent), NOT to the orchestrator. You (the plan-issue agent) are still responsible for posting it as a GitHub comment in step 6.
   - Take the output and reformat it into the canonical structure below, inserting the `**Tasks (ordered):**` section between `**Files to change:**` and `**DB schema changes:**`. Use the path-specific Task 0 wording from the section further down this skill.

   **In either case**, the final plan MUST use this exact format:

   ```markdown
   ## Implementation Plan

   **Changes from previous plan:** (only if revising — bullet each change and which feedback it addresses)

   **Files to change:**
   - `path/to/file.ts` — reason

   **Tasks (ordered):**
   - Task 0: <per-path directive — see the Task 0 sections below and copy the block that matches $PATH_LETTER>
   - Task 1..N-1: <the actual code work; structured per path — see the per-path guidance further down>
   - Task N: invoke `superpowers:requesting-code-review` to self-verify every plan requirement is met and all tests are green before opening the PR

   **DB schema changes:** (or "None")
   **API changes:** (or "None")
   **Frontend changes:** (or "None")
   **Test changes:** (or "None")
   **Design decisions:** (architecture, data structures, algorithms, mode behaviors — anything a developer needs to implement without ambiguity)
   **Risks/unknowns:** (or "None")
   **Estimated effort:** X hours
   ```

   **IMPORTANT — the GitHub comment IS the plan.** The `/pipeline:execute-issue-plan` skill reads ONLY the GitHub comment when implementing in a worktree. It has no access to local `.claude/plans/` files. Therefore:
   - Include ALL design detail directly in the comment — data structures, tier tables, formulas, mode behaviors, prompt strategies, etc.
   - Never summarize and point to a local plan file (e.g., "see `compressed-wibbling-sutherland.md` for details").
   - If you used Claude's plan mode internally, fold its full content into the comment before posting.
   - The executing Claude should be able to implement the feature from the comment alone, with zero missing context.

   ### Task 0 and per-path code-task guidance

   Copy the Task 0 block below that matches the detected `PATH_LETTER`. For Tasks 1..N-1, structure code tasks using the same path's code-task format so the executor can follow the right discipline.

#### Task 0 — PATH A (docs-only)

   `Task 0: (no skill required — docs-only change; go straight to Task 1).`

   Code-task format for PATH A: flat edit → commit. Each task is a single bullet like `Task K: edit <file> to <change>; commit as "<type>: <summary>"`. No test cycle, no reviewer dispatch.

#### Task 0 — PATH B (standard)

   `Task 0: invoke superpowers:test-driven-development before any code edit. Every subsequent code task must follow the red→green→commit cycle: write a failing test → run for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done → watch it fail for the RIGHT reason → write minimum impl → run for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done → watch it pass → commit.`

   Code-task format for PATH B: each task that modifies impl code includes all five steps explicitly — the test file path, the exact pytest/test command to run, the expected FAIL output, the impl code sketch, the expected PASS output, and the commit message. No step may be skipped; a task that does not follow red→green is a planning defect.

#### Task 0 — PATH C (multi-task)

   `Task 0: dispatch Agent(subagent_type='tdd-implementer', description='target=<first-dir>/ ...', prompt='target=<first-dir>/ implement <first-task>') — one tdd-implementer dispatch per distinct target directory. The orchestrator must NOT Write/Edit impl files directly; the enforce-path-c-delegation hook will block unauthorized edits.`

   Code-task format for PATH C: every code task is a single `tdd-implementer` dispatch. Each dispatch includes a `target=<dir>/` sentinel (must be a real subdirectory — `target=.`, `target=./`, or `target=/` are rejected by the delegation hook) and a prompt detailed enough for the subagent to execute autonomously (what file, what behavior, what test, what commit message). Multiple dispatches may run in parallel when their targets don't overlap.

6. **Post the plan as a GitHub comment:**
   ```bash
   gh issue comment <N> --repo HTS-COLLAB-ORG/claude-pipeline --body "<plan markdown>"
   ```

7. **Verify the plan comment was posted:**
   ```bash
   PLAN_COUNT=$(gh issue view <N> --repo HTS-COLLAB-ORG/claude-pipeline --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | length')
   echo "Plan comments found: $PLAN_COUNT"
   ```
   - If `$PLAN_COUNT` >= 1, proceed to step 8.
   - If `$PLAN_COUNT` is 0: the comment failed to post. Retry once by re-running the `gh issue comment` from step 6. Then re-check. If still 0, STOP and report: "FAILED: Plan was generated but could not be posted as a GitHub comment on issue #N." Include the full plan text in your response so the orchestrator can recover. Do NOT add the `plan-pending` label.

8. **Update labels** — add `plan-pending`:
   ```bash
   gh issue edit <N> --repo HTS-COLLAB-ORG/claude-pipeline --add-label "plan-pending"
   ```

9. **Report back:** "Plan posted to issue #N (PATH $PATH_LETTER)."

## Revision handling

When revising (user feedback on a prior plan exists), the `**Changes from previous plan:**` section still appears first. Re-derive `PATH_LETTER` from the current label in step 3a — do NOT copy the Task 0 block from the prior plan verbatim, since the user may have relabeled since.

## Constraints
- READ ONLY — do not modify any source files.
- Bullet points only, no prose padding.
- Do not scope-creep beyond what the issue asks for.
- If two issues share a branch (e.g. #13 and #12 both on feature/ui-polish), you may be called for both at once — post a separate comment on each issue.
