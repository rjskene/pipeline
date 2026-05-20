---
name: plan-issue
description: Produce an implementation plan for a specific GitHub issue, post it as a comment, and add the plan-pending label. Usage: /pipeline:plan-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
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

# Planning Agent

You will receive an issue number as the argument (or from context). Perform these steps:

## Steps

1. **Fetch issue details and existing comments:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body
   gh issue view <N> --repo $PIPELINE_REPO --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Analyze existing comments** — look for:
   - **Prior plans**: comments containing `## Implementation Plan` (posted by the planning agent or user)
   - **User feedback**: any comments from the repo owner (rjskene) that are NOT plans — these are revision requests
   - If user feedback exists on an existing plan, this is a **plan revision**. The revised plan MUST address every point in the user's feedback. Call out what changed with a `**Changes from previous plan:**` section at the top.

3. **Read project context:**
   - Read each file listed in the project's context files config: `PIPELINE_CONTEXT_FILES`

3a. **Determine PATH** — the executor's discipline depends on the path label, so the plan must include a path-specific Task 0:

   ```bash
   LABELS=$(gh issue view <N> --repo $PIPELINE_REPO --json labels --jq '.labels[].name')
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
     CACHED=$(gh issue view <N> --repo $PIPELINE_REPO --json comments \
       --jq '[.comments[] | select(.body | contains("## Classification"))] | last | .body' \
       | grep -oE 'recommended_path:\*\* [ABC]' | awk '{print $2}' | head -1)
     case "$CACHED" in A|B|C) PATH_LETTER="$CACHED" ;; *) PATH_LETTER=B ;; esac
   fi
   echo "Planning issue #<N> as PATH $PATH_LETTER"
   ```

3b. **Ingest and read attachments.** In interactive single-issue planning (when `/pipeline:fullsend` is not the caller), run `fetch-issue-attachments.sh` for this issue, then list and `Read` every file. The helper is idempotent — if `/pipeline:fullsend` step 1a already ran, this is a no-op fetch.

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh" <N> 2>/dev/null | head -1
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

   **For each file printed by `ls -1`, invoke the `Read` tool exactly once before drafting.** Mandatory for issues labeled `bug`, `user-submitted`, or `regression`; recommended for others. Screenshots steer the codebase exploration in step 4 toward the right files.

4. **Explore the codebase** — use Glob, Grep, and Read to find all files relevant to this issue. Look at:
   - Schema files if the issue touches data
   - Route files if the issue touches API
   - Frontend components if the issue touches UI
   - Test files if tests need updating
   - Scan the issue title, body, and any quoted text for GitHub Actions CI-blocking markers (the bracketed forms of `skip ci`, `ci skip`, `skip-ci`, `ci-skip`, `no ci`, `no-ci`, plus `***NO_CI***`). If any are present in literal form, prepend a `**Heads-up — CI-blocking markers:** the issue text quotes <marker(s)>. The executor must escape them when writing PR titles or commit subjects (e.g. backticked `` `skip ci` ``, hyphenated `skip-ci`, or `skip CI` without brackets). The `check-ci-skip-markers` PreToolUse hook will block any unescaped occurrence.` line to the plan body, in addition to the standard `Files to change` / `Tasks (ordered)` / etc. sections.

5. **Generate the implementation plan.**

   > **CRITICAL — YOU MUST post the plan yourself. DO NOT return the plan as your final message.** YOU MUST write the plan body to a draft file under `.claude/logs/plan-drafts/` AND YOU MUST invoke `scripts/post-plan.sh` to publish it. This applies whether you were invoked by the orchestrator directly or dispatched as a subagent — the post step is always your responsibility, never the caller's. Returning the plan as terminal agent output is a skill failure — the orchestrator will see no comment and no `plan-pending` label, and will have to redo the work that was already inside your turn.

   > **Subagent dispatch contract.** This skill is end-to-end. Regardless of how you were invoked (top-level `/pipeline:plan-issue` or `Agent(subagent_type=...)` dispatch from `/pipeline:fullsend` or `/pipeline:run`), YOU own every step from issue fetch through `post-plan.sh` success. You do NOT return the plan text for the caller to post. You do NOT save the plan to `docs/` for the caller to read. The only acceptable terminal states are: (a) `post-plan.sh` exited 0 and you report the success line from Step 8, or (b) `post-plan.sh` exited non-zero and you report the FAILED line from Step 7. There is no third option.

   Invoke `superpowers:writing-plans` to structure the plan:
   ```
   Skill(skill: "superpowers:writing-plans")
   ```
   - Pass the issue title, body, any existing plan comments, your codebase findings from step 4, AND the detected `PATH_LETTER` from step 3a.
   - Tell it: "Do NOT save the plan to a file in `docs/`. Return the plan content directly so I can write it to the draft file under `.claude/logs/plan-drafts/`."
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

   `Task 0: invoke superpowers:test-driven-development before any code edit. Every subsequent code task must follow the red→green→commit cycle: write a failing test → run $PIPELINE_TEST_CMD → watch it fail for the RIGHT reason → write minimum impl → run $PIPELINE_TEST_CMD → watch it pass → commit.`

   Code-task format for PATH B: each task that modifies impl code includes all five steps explicitly — the test file path, the exact pytest/test command to run, the expected FAIL output, the impl code sketch, the expected PASS output, and the commit message. No step may be skipped; a task that does not follow red→green is a planning defect.

#### Task 0 — PATH C (multi-task)

   `Task 0: dispatch Agent(subagent_type='tdd-implementer', description='target=<first-dir>/ ...', prompt='target=<first-dir>/ implement <first-task>') — one tdd-implementer dispatch per distinct target directory. The orchestrator must NOT Write/Edit impl files directly; the enforce-path-c-delegation hook will block unauthorized edits.`

   Code-task format for PATH C: every code task is a single `tdd-implementer` dispatch. Each dispatch includes a `target=<dir>/` sentinel (must be a real subdirectory — `target=.`, `target=./`, or `target=/` are rejected by the delegation hook) and a prompt detailed enough for the subagent to execute autonomously (what file, what behavior, what test, what commit message). Multiple dispatches may run in parallel when their targets don't overlap.

6. **Write the plan to a draft file (YOU, not the caller).** YOU MUST use the `Write` tool to create the draft file at the path below; YOU MUST NOT return the plan body in your final message and ask the caller to write the file.
   ```bash
   mkdir -p .claude/logs/plan-drafts
   DRAFT=".claude/logs/plan-drafts/<N>-$(date -u +%Y%m%dT%H%M%SZ).md"
   # Use the Write tool to write the canonical plan markdown to "$DRAFT".
   ```
   Use the `Write` tool (not heredoc, not `echo`) so the full plan body is preserved verbatim and the file path is logged.

7. **Post atomically via helper — YOU run the helper; this is the only post path.** YOU MUST invoke the command below from within your own turn. Do not stop, return, or summarize before the helper exits.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/post-plan.sh" <N> "$DRAFT"
   ```
   The helper posts the comment, verifies it, applies `plan-pending`, and verifies the label — each sub-step retries once on failure. Do not retry from the skill; the helper already retries.

   If the helper exits non-zero, surface its stderr AND the `$DRAFT` path verbatim, then STOP with: `FAILED: post-plan.sh exited <rc> for issue #<N>; draft preserved at <DRAFT>`. The draft is on disk and the operator can re-run the helper manually.

8. **Report back, but only AFTER `post-plan.sh` exits 0:** "Plan posted to issue #N (PATH $PATH_LETTER)." If the helper exited non-zero, do not report this success line; report the FAILED line from Step 7 instead. Your final message MUST follow either the success template above or the FAILED template from Step 7 — never the raw plan body, never a summary, never a hand-off note to the caller.

## Revision handling

When revising (user feedback on a prior plan exists), the `**Changes from previous plan:**` section still appears first. Re-derive `PATH_LETTER` from the current label in step 3a — do NOT copy the Task 0 block from the prior plan verbatim, since the user may have relabeled since.

## Constraints
- READ ONLY — do not modify any source files.
- Bullet points only, no prose padding.
- Do not scope-creep beyond what the issue asks for.
- If two issues share a branch (e.g. #13 and #12 both on feature/ui-polish), you may be called for both at once — post a separate comment on each issue.
