---
name: plan-issue
description: Produce an implementation plan for a specific GitHub issue, post it as a comment, and add the plan-pending label. Usage: /pipeline:plan-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

Source `pipeline.config` first so `PIPELINE_*` variables are available:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Lifecycle

```
issue → writing-plans superpower → PATH-aware Task shape → comment → label plan-pending
```

## Caller contract

When a caller dispatches this skill to a subagent (the `/pipeline:fullsend` Step 1b dispatch and the `/pipeline:run` dispatch — see `skills/run/references/dispatch-routing.md`), the caller MUST embed in the dispatched Agent's prompt the directive that the subagent's only valid terminal states are `post-plan.sh` exit 0 (report the success line) or `post-plan.sh` exit non-zero (report the FAILED line). Returning the plan body in chat is a skill failure — the plan does not exist until the `## Implementation Plan` comment is posted and `plan-pending` is applied.

This is defense-in-depth: when `general-purpose` is the dispatched subagent type, it may not load this SKILL.md at all — it can treat `/pipeline:plan-issue N` as a content-instruction and simulate the slash command. The caller-side directive at the dispatch site is the only binding contract it is guaranteed to see, so the two call sites (`fullsend`, `run`) carry the directive verbatim. Keep this note in sync if either dispatch site moves.

# Planning Agent

Receive an issue number as argument (or from context).

## Steps

1. **Fetch issue details and existing comments:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body
   gh issue view <N> --repo $PIPELINE_REPO --json comments --jq '.comments[] | {author: .author.login, createdAt: .createdAt, body: .body}'
   ```

2. **Analyze existing comments** — look for prior plans (containing `## Implementation Plan`) and user feedback (rjskene's non-plan comments). If feedback exists on an existing plan, this is a **plan revision**: the revised plan MUST address every point and lead with a `**Changes from previous plan:**` section.

3. **Read project context:** Read each file listed in `PIPELINE_CONTEXT_FILES`.

3a. **Determine PATH** — the plan needs a path-specific Task 0:

   ```bash
   LABELS=$(gh issue view <N> --repo $PIPELINE_REPO --json labels --jq '.labels[].name')
   if echo "$LABELS" | grep -qx "docs-only"; then
     PATH_LETTER=A
   elif echo "$LABELS" | grep -qx "quick-fix"; then
     PATH_LETTER=D
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
       | grep -oE 'recommended_path:\*\* [ABCD]' | awk '{print $2}' | head -1)
     case "$CACHED" in A|B|C|D) PATH_LETTER="$CACHED" ;; *) PATH_LETTER=B ;; esac
   fi
   echo "Planning issue #<N> as PATH $PATH_LETTER"
   ```

3b. **Ingest and read attachments.** In interactive single-issue planning (when `/pipeline:fullsend` is not the caller), run `fetch-issue-attachments.sh`, then `Read` every file under `.claude/scratch/issue-<N>/`. Idempotent — no-op if `/pipeline:fullsend` step 1a already ran.

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/fetch-issue-attachments.sh" <N> 2>/dev/null | head -1
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

   **For each file printed by `ls -1`, invoke the `Read` tool exactly once before drafting.** Mandatory for `bug`, `user-submitted`, `regression` labels; recommended otherwise. Screenshots/binary evidence steer codebase exploration in step 4 (which symbols to grep, which routes to read, which test files to touch).

3c. **needs-browser predicate requirement.** If the labels resolved in step 3a include `needs-browser`, the plan MUST include a section titled `**Predicates:**` listing acceptance criteria as machine-checkable predicates: JS expressions that the visual-proof-from-plan sub-skill can pass to mcp__playwright_*browser_evaluate. Example: `predicate: document.querySelector("#events-table tbody tr").length > 0 after navigate to /admin/events`. Prose acceptance criteria ("the table renders") are NOT acceptable for needs-browser issues. This is a planner-side requirement only; an automated label-aware lint in `post-plan.sh` is a planned follow-up and is NOT yet wired up.

4. **Explore the codebase** — use Glob, Grep, and Read to find files relevant to this issue (schemas if data, routes if API, components if UI, tests if behavior changes). (See Step 3b for attachment handling.)

   Scan the issue title/body/quoted text for GH Actions CI-blocking markers (bracketed forms of `skip ci`, `ci skip`, `skip-ci`, `ci-skip`, `no ci`, `no-ci`, plus `***NO_CI***`). If any appear in literal form, prepend a `**Heads-up — CI-blocking markers:**` line to the plan body instructing the executor to escape them in PR titles / commit subjects (backticked `` `skip ci` ``, hyphenated `skip-ci`, or `skip CI` without brackets) — the `check-ci-skip-markers` PreToolUse hook will block any unescaped occurrence.

5. **Generate the implementation plan.**

   > **CRITICAL — YOU MUST post the plan yourself. DO NOT return the plan as your final message.** YOU MUST write the plan body to a draft file under `.claude/logs/plan-drafts/` AND YOU MUST invoke `scripts/post-plan.sh` to publish it. **Subagent dispatch contract — this skill is end-to-end.** Whether invoked directly or dispatched as a subagent (from `/pipeline:fullsend` or `/pipeline:run`), YOU own every step from fetch through `post-plan.sh` success; the post step is never the caller's. Returning the plan as terminal agent output is a skill failure. The only acceptable terminal states are: (a) `post-plan.sh` exited 0 and you report the success line from Step 8, or (b) `post-plan.sh` exited non-zero and you report the FAILED line from Step 7.

   Invoke `Skill(skill: "superpowers:writing-plans")`. Pass the issue title, body, prior plan comments, codebase findings from step 4, AND `PATH_LETTER` from step 3a. Tell it: "Do NOT save the plan to a file in `docs/`. Return the plan content directly so I can write it to the draft file under `.claude/logs/plan-drafts/`." Reformat its output into the canonical structure below, inserting `**Tasks (ordered):**` between `**Files to change:**` and `**DB schema changes:**`. Use the path-specific Task 0 wording further down. Final plan MUST use this exact format:

   ```markdown
   ## Implementation Plan

   **Changes from previous plan:** (only if revising — bullet each change and which feedback it addresses)
   **Files to change:**
   - `path/to/file.ts` — reason

   **Tasks (ordered):**
   - Task 0: <per-path directive — copy the block matching $PATH_LETTER below>
   - Task 1..N-1: <code work, structured per path>
   - Task N: invoke `superpowers:requesting-code-review` to self-verify plan requirements are met and tests are green before opening the PR

   **DB schema changes:** (or "None")
   **API changes:** (or "None")
   **Frontend changes:** (or "None")
   **Predicates:** (required for needs-browser-labeled issues)
   **Test changes:** (or "None")
   **Design decisions:** (architecture, data structures, algorithms, mode behaviors)
   **Risks/unknowns:** (or "None")
   **Estimated effort:** X hours
   ```

   **IMPORTANT — the GitHub comment IS the plan.** `/pipeline:execute-issue-plan` reads ONLY the comment; it has no access to local `.claude/plans/` files. Include ALL design detail directly (data structures, tier tables, formulas, mode behaviors). Never summarize and point to a local file. Fold Claude plan-mode content into the comment before posting.

   ### Per-path Task 0 — copy the block matching `PATH_LETTER`; structure Tasks 1..N-1 in the same path's format.

#### Task 0 — PATH A (docs-only)
   `Task 0: (no skill required — docs-only change; go straight to Task 1).`
   Code-task format: flat edit → commit, `Task K: edit <file> to <change>; commit as "<type>: <summary>"`. No tests, no reviewer.

#### Task 0 — PATH B (standard)
   `Task 0: invoke superpowers:test-driven-development before any code edit. Every subsequent code task must follow the red→green→commit cycle: write a failing test → run $PIPELINE_TEST_CMD → watch it fail for the RIGHT reason → write minimum impl → run $PIPELINE_TEST_CMD → watch it pass → commit.`
   Code-task format: each impl task lists all five steps explicitly — test file path, exact test command, expected FAIL, impl sketch, expected PASS, commit message. Skipping red→green is a planning defect.

#### Task 0 — PATH C (multi-task)
   `Task 0: dispatch Agent(subagent_type='tdd-implementer', description='target=<first-dir>/ ...', prompt='target=<first-dir>/ implement <first-task>') — one tdd-implementer dispatch per distinct target directory. The orchestrator must NOT Write/Edit impl files directly; the enforce-path-c-delegation hook will block unauthorized edits.`
   Code-task format: every code task is a single `tdd-implementer` dispatch with a `target=<dir>/` sentinel (real subdirectory — `target=.`, `target=./`, `target=/` are rejected by the delegation hook) and a prompt detailed enough for autonomous execution. Non-overlapping targets may run in parallel.

#### Task 0 — PATH D (quick-fix)
   PATH D plans collapse to a **single inline tdd task** — no subagent dispatch, no multi-task list. The implementer IS the `tdd-implementer` (executor applies red→green→commit directly inline). This is the contract `execute-issue-plan` Step 5 expects when it sees the `quick-fix` label.
   `Task 0: you ARE tdd-implementer (single-instance inline). Apply red→green→commit discipline directly in this session: write one failing test → run $PIPELINE_TEST_CMD → watch it fail for the RIGHT reason → write minimum impl → run $PIPELINE_TEST_CMD → watch it pass → commit. No subagent dispatch. No spawn-claude. No tmux. The evaluate-issue-pr stage is the sole review gate.`
   Code-task format: single bullet — same five steps as PATH B but inline without the `superpowers:test-driven-development` bookend.

6. **Write the plan to a draft file (YOU, not the caller).** YOU MUST use the `Write` tool (not heredoc, not `echo`) to create the draft file at the path below; YOU MUST NOT return the plan body in your final message for the caller to write.
   ```bash
   mkdir -p .claude/logs/plan-drafts
   DRAFT=".claude/logs/plan-drafts/<N>-$(date -u +%Y%m%dT%H%M%SZ).md"
   # Use the Write tool to write the canonical plan markdown to "$DRAFT".
   ```

7. **Post atomically via helper — YOU run the helper; this is the only post path.** YOU MUST invoke this from within your own turn. Do not stop, return, or summarize before the helper exits.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/post-plan.sh" <N> "$DRAFT"
   ```
   The helper posts the comment, verifies it, applies `plan-pending`, and verifies the label — each sub-step retries once. Do not retry from the skill. If the helper exits non-zero, surface its stderr AND the `$DRAFT` path verbatim, then STOP with: `FAILED: post-plan.sh exited <rc> for issue #<N>; draft preserved at <DRAFT>`. The operator can re-run the helper manually.

8. **Report back, but only AFTER `post-plan.sh` exits 0:** "Plan posted to issue #N (PATH $PATH_LETTER)." Otherwise report the FAILED line from Step 7. Your final message MUST follow one of these two templates — never the raw plan body, never a summary, never a hand-off to the caller.

## Revision handling

When revising (user feedback on a prior plan exists), `**Changes from previous plan:**` appears first. Re-derive `PATH_LETTER` from the current label in step 3a — do NOT copy the prior plan's Task 0 block verbatim, since the user may have relabeled.

## Constraints
- READ ONLY — do not modify any source files.
- Bullet points only, no prose padding.
- Do not scope-creep beyond what the issue asks for.
- If two issues share a branch (e.g. #13 and #12 both on feature/ui-polish), you may be called for both at once — post a separate comment on each issue.
