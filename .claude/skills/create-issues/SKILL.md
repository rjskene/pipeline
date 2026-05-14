---
name: create-issues
description: "Brainstorm mode \u2014 discuss code changes freely, then push actionable items as GitHub issues instead of implementing them directly."
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
```

The bash code blocks below reference these variables via `HTS-COLLAB-ORG/claude-pipeline`, `staging`, `for t in tests/test*.sh tests/test_*.sh; do [ -f "$t" ] && bash "$t" || true; done`, `CLAUDE.md`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Issue Creation Mode

You are in **brainstorming / issue-creation mode**. Your job is to help the user discuss problems, feature ideas, refactors, bugs, or improvements — and turn actionable items into GitHub issues. You must NOT implement code changes directly.

## Rules

### READ ONLY — no source modifications
- The `allowed-tools` restriction above blocks `Write` and `Edit`. Do not attempt to use them.
- **Bash guardrails** — NEVER run commands that modify source files:
  - No `sed -i`, `tee`, `>`, `>>` targeting source files
  - No `git commit`, `git add`, `npm run build`, or any build/compile commands
  - No `patch`, `dd`, `mv`, `cp` that overwrites source files
- Allowed Bash usage:
  - `gh issue create`, `gh issue list`, `gh issue view`, `gh issue comment`
  - `git log`, `git status`, `git diff`, `git show`, `git blame` (read-only git)
  - Exploratory commands: `ls`, `wc`, `file`, `which`, `cat` (for non-source reference files)
- If the user asks you to implement something directly, **refuse** and propose creating an issue for it instead.

### Conversation flow
1. The user discusses problems, feature ideas, refactors, bugs, or improvements.
2. You explore the codebase freely (Read/Glob/Grep) to understand context and validate feasibility.
3. **Refine the idea.**

   Invoke `superpowers:brainstorming` to refine the idea through Socratic questioning:
   ```
   Skill(skill: "superpowers:brainstorming")
   ```
   Tell it: "Do NOT save design docs to a file. Return the refined spec directly. Do NOT invoke writing-plans — the user will run /pipeline:plan-issue separately." It will ask one question at a time, multiple-choice when possible, with validation gates between sections.
4. **Scope check — one issue vs many.**

   Before proposing issues, take your own read on scope:
   - If the refined spec is clearly **one concept** (single file area, single behavior change, single user-visible feature), proceed directly to step 5 with no ceremony. Do not surface this gate to the user.
   - If the refined spec looks like **2+ independent pieces** (different subsystems, different ship moments, different reviewers), surface the decomposition prompt before the proposal gate:
     - Lead with your own read (1-2 sentences): why you think this is multi-issue.
     - Present 2-3 slicing options with trade-offs (e.g., "split by subsystem", "split by ship order", "keep as one and accept the scope").
     - Ask the user to pick a slicing.
   - Mirror the scope-check pattern from `superpowers:brainstorming` ("If the project is too large for a single spec, help the user decompose into sub-projects"). Keep the prompt cheap — one message, option list, no follow-ups — so small requests pay no ceremony cost.

5. When an actionable item (or set of items, post-scope-check) crystallizes, you propose creating a GitHub issue.
6. On user confirmation, you create the issue(s).

### Issue proposal format

When one or more actionable items have crystallized and you are ready to propose issues, show them as a **compact list only**:

```
Proposed issues:
- (pending) <title> — <one-line summary of scope, max ~15 words>
- (pending) <title> — <one-line summary of scope>
```

Then ask for confirmation in a single prompt, e.g. "Create these N issues? (y/n, or list numbers to keep)".

**Do NOT render the full issue body (Context / Scope / Affected areas / Notes) inline in the conversation.** The user has already seen the reasoning in the preceding discussion, and the full body will be persisted on GitHub when the issue is created. Inline rendering adds scroll noise and duplicates context.

You still build the full body internally — you just do not print it to the user before creation.

**Multi-issue case — default to including a tracker.** When the scope-check landed on a 2+ issue split, add a tracker issue as the last line of the compact list, marked `(pending tracker)`:

```
Proposed issues:
- (pending) <sub-issue 1 title> — <one-line summary>
- (pending) <sub-issue 2 title> — <one-line summary>
- (pending tracker) <tracker title> — rolls up the sub-issues above
```

The tracker is the **default** for multi-issue sets. The user can opt out by replying "skip tracker" (or listing only the sub-issue numbers to keep). Do not ask "do you want a tracker?" — assume yes unless the user opts out.

Tracker titles follow the convention `epic(<scope>): <feature> — tracker for #A, #B` (example: issue #247 rolls up #245 and #246). Fill in the sub-issue numbers **after** the children are created; the tracker is created last so its body can reference real issue numbers.

### Issue creation protocol

Before creating an issue, **check for duplicates**:
```bash
gh issue list --repo HTS-COLLAB-ORG/claude-pipeline --state open --json number,title --limit 100
```
If a similar issue exists, flag it and ask the user whether to:
- Create a new issue anyway
- Comment on the existing issue instead
- Skip

After the user confirms the compact list, create each confirmed issue in a batch (one `gh issue create` call per issue, run sequentially or in a single message). Use the same body template below for all of them. Do NOT re-render the body to the user — it is only passed to `gh`.
```bash
gh issue create --repo HTS-COLLAB-ORG/claude-pipeline --title "<title>" --body "$(cat <<'EOF'
## Context
<1-3 sentences explaining the problem or opportunity>

## Scope
- <bullet points of what this issue covers>

## Affected areas
- <file paths or system areas likely involved>

## Notes
- <any design considerations, constraints, or dependencies surfaced during discussion>
EOF
)"
```

After each issue is created, print a single line: `Created: #N — <title> — <url>`. Do not re-print the body.

**Tracker issue body template (multi-issue case only).** After all sub-issues are created and their numbers are known, create the tracker last. Use this body template:

```bash
gh issue create --repo HTS-COLLAB-ORG/claude-pipeline --title "epic(<scope>): <feature> — tracker for #A, #B" --body "$(cat <<'EOF'
## Context
<1-3 sentences explaining why this work exists and the shape of the rollup>

## Rollout sequence
<Optional 1-2 sentence note on ship order, e.g., "Ship in order — B reuses endpoints landed by A.">

- [ ] **#A — <sub-issue 1 title>** (<one-line summary of scope>)
- [ ] **#B — <sub-issue 2 title>** (<one-line summary of scope>)

## Out of scope (filed separately or deferred)

- <Item> — <one-line reason it's out of scope>
- <Item> — <one-line reason>

## Notes

- Close this tracker when all children are closed.
- If a new sub-issue surfaces during rollout, add it here as a checklist item.
EOF
)"
```

Every tracker body MUST include these sections in this order: **Context**, **Rollout sequence** (checkbox list of child issues in ship order), **Out of scope**, **Notes** ending with the closing line "Close this tracker when all children are closed." Reference issue #247 for a worked example of the shape — do not copy its title or content.

### Labels
- Newly created issues get no pipeline labels by default (they enter the pipeline as `ready` stage).
- If the user specifies a label during discussion (e.g., "this is a bug"), add it: `--label bug`.

### Session summary
When the user ends the session (says "done", "that's all", etc.), print a summary:

```
ISSUES CREATED THIS SESSION
================================================================
Issue   Title
----------------------------------------------------------------
#N      <title>
#N      <title>
================================================================
Total: X issues created
```

If no issues were created, print: "No issues created this session."
