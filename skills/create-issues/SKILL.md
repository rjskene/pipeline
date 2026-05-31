---
name: create-issues
description: "Brainstorm mode — discuss code changes freely, then push actionable items as GitHub issues instead of implementing them directly."
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# First run on a fresh project? Run /pipeline:init to generate pipeline.config + seed labels.
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Issue Creation Mode

```
brainstorm → scope check → grouping check → proposal → confirm → create
```

You are in **brainstorming / issue-creation mode**: help the user discuss problems, feature ideas, refactors, bugs, or improvements — and turn actionable items into GitHub issues. You must NOT implement code changes directly.

## Rules

### READ ONLY — no source modifications

- `allowed-tools` blocks `Write` and `Edit`. Do not attempt them.
- **Bash guardrails** — NEVER run commands that modify source: no `sed -i`, `tee`, `>`, `>>` against source; no `git commit`, `git add`, `npm run build`, or any build/compile; no `patch`, `dd`, `mv`, `cp` overwrites.
- **Allowed Bash:** `gh issue create|list|view|comment`; read-only git (`log`, `status`, `diff`, `show`, `blame`); exploratory `ls` / `wc` / `file` / `which` / `cat` on reference files.
- If the user asks for direct implementation: **refuse** and propose creating an issue instead.

### Conversation flow

1. The user discusses problems, ideas, refactors, bugs, or improvements; you explore the codebase freely (Read/Glob/Grep) to understand context and validate feasibility.
2. **Refine the idea.** Invoke `superpowers:brainstorming` to refine via Socratic questioning:
   ```
   Skill(skill: "superpowers:brainstorming")
   ```
   Tell it: "Do NOT save design docs to a file. Return the refined spec directly. Do NOT invoke writing-plans — the user will run /pipeline:plan-issue separately." It will ask one question at a time, multiple-choice when possible, with validation gates between sections.
3. **Scope check — one issue vs many.** Take your own read: if clearly one concept (single file area, single behavior change), proceed silently. If 2+ independent pieces (different subsystems, ship moments, reviewers), surface a decomposition prompt — lead with your read (1–2 sentences), present 2–3 slicing options with trade-offs, ask the user to pick. One message, option list, no follow-ups.
4. Propose creating a GitHub issue (or set, post-scope-check); on user confirmation, create.

### Grouping detection — before proposal

After scope-check but before printing the proposal, query open issues for grouping candidates. Deterministic conventional-commit `<scope>` matching, read-only.

```bash
bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/find-grouping-candidates.sh" \
  --title "<proposed-title-1>" \
  --title "<proposed-title-2>"
```

The helper prints one recommendation line per input as `INPUT="<title>" REC=<TRACKER #N | GROUP #A,#B,... | STANDALONE> REASON=<short>`.

**Recommendation shapes:**
- `TRACKER #N` — scope matches an existing tracker. Surface: "overlaps with tracker #N — propose adding as child."
- `GROUP #A,#B` — proposed plus standalones #A and #B share a scope. Surface: "overlaps with standalones #A, #B — propose a new tracker rolling up all three."
- `STANDALONE` — no candidate. Surface nothing.

**User gate.** When TRACKER or GROUP fires, append the recommendation under the relevant `(pending)` line and include it in the confirmation prompt — **the default action is to accept**. Example: "Create these N issues? (y/n, or list numbers to keep; default accepts tracker grouping)". User may type `standalone` to override.

**Post-confirmation TRACKER auto-append.** After the new sub-issue is created and its number known, splice a new checklist line into the tracker's `## Rollout sequence`:

```bash
gh issue view <tracker> --repo $PIPELINE_REPO --json body -q .body > /tmp/tracker-body.md
# append `- [ ] **#<new> — <title>** (<one-line summary>)` to the Rollout sequence checklist
gh issue edit <tracker> --repo $PIPELINE_REPO --body-file /tmp/tracker-body.md
```

If no `## Rollout sequence` section, print `Manual: append #<new> to tracker #<N> Rollout sequence` and continue.

**Post-confirmation GROUP auto-create** falls through to the multi-issue tracker creation flow below. **Read-only on dry-run** — the helper never edits; auto-append happens only post-confirmation. **Opt-out** via `PIPELINE_GROUPING_DETECTION_ENABLED=false` in `pipeline.config`.

### Issue proposal format

Show proposed issues as a **compact list only**:

```
Proposed issues:
- (pending) <title> — <one-line summary of scope, max ~15 words>
- (pending) <title> — <one-line summary of scope>
```

Then ask for confirmation in a single prompt, e.g. "Create these N issues? (y/n, or list numbers to keep)".

**Do NOT render the full issue body** (Context / Scope / Affected areas / Notes) inline. The user already saw the reasoning in discussion; the body is persisted on GitHub. You still build the body internally — just don't print it before creation.

**Multi-issue case — default to including a tracker.** When scope-check landed on 2+ issues, add a tracker as the last line marked `(pending tracker)`:

```
Proposed issues:
- (pending) feat(tracker-lifecycle): <sub-issue 1 title> — <one-line summary>
- (pending) feat(tracker-lifecycle): <sub-issue 2 title> — <one-line summary>
- (pending tracker) epic(tracker-lifecycle): <feature> — rolls up the sub-issues above
```

Tracker is the **default** (user opts out with "skip tracker"; do not ask "do you want a tracker?"). Title convention: `epic(<scope>): <feature> — tracker for #A, #B` (example: #247 rolls up #245 and #246); fill sub-issue numbers **after** children are created.

**Shared scope.** Derive a single `<scope>` from the conversation topic and apply it as the conventional-commit scope on every sub-issue and the tracker — e.g. tracker `epic(tracker-lifecycle): …` produces children `feat(tracker-lifecycle): …`, `fix(tracker-lifecycle): …`. The `<type>` may vary per child; the `<scope>` must not.

### Issue creation protocol

Before creating, check for duplicates via `gh issue list --repo $PIPELINE_REPO --state open --json number,title --limit 100`. If a similar issue exists, ask the user: create anyway, comment on existing, or skip.

After confirmation, create each issue in a batch (one `gh issue create` per issue). Use the body template below for all. Do NOT re-render the body to the user.

```bash
gh issue create --repo $PIPELINE_REPO --title "<title>" --body "$(cat <<'EOF'
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

After each issue is created, print: `Created: #N — <title> — <url>`.

**Tracker issue body template (multi-issue case only).** Create the tracker last so its body can reference real issue numbers. The fenced template below is the canonical structure — Context / Rollout sequence (checkbox list, ship order) / Out of scope / Notes (ending with the closing-when-children-closed line). Reference #247 for a worked example of the shape.

```bash
gh issue create --repo $PIPELINE_REPO --label tracker --title "epic(<scope>): <feature> — tracker for #A, #B" --body "$(cat <<'EOF'
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

### Labels

- Newly created issues get no pipeline labels by default (enter as `ready`).
- If the user specifies a label during discussion ("this is a bug"), add it: `--label bug`.
- Tracker issues (created via the tracker body template above) automatically receive the `tracker` label so the orchestrator excludes them from the action queue.
- If the user's framing is architectural critique, open-ended exploration, or "should we / could we" without a commit-to-act, propose creating with `--label brainstorm`. The label parks the issue in the discussion bucket — visible in `/pipeline:run` (stage = `brainstorm`) but never auto-planned or auto-executed. User promotes by removing the label.

### PATH D body marker (advisory)

If the issue you are drafting describes a precedent-mirror fix, one-line config flip, dogfood-mirror edit, or guard-test addition, include `<!-- pipeline:path=D -->` in the body at filing time. This is the authoritative route to PATH D — phrase heuristics in `skills/classify-issue/SKILL.md` will not reliably flip a structured body to D. See the `### PATH D (quick-fix)` section in `skills/classify-issue/SKILL.md` (and its `#### Blast-radius B→D routing` subsection) for the full list of shapes.

Filing-time backstop: when a `fix(` draft names ≤ 2 non-test source files in a single module under `## Affected areas` AND carries no high-uncertainty signal (concurrency/race/lock/deadlock/security/auth/crypto/migration/data-loss), propose adding `<!-- pipeline:path=D -->` — the filing-time mirror of the classifier's Blast-radius B→D rule, carrying the same carve-out (high-uncertainty `fix(` work stays B).

Example:

```
## Context
Same path-math family as #277 — fix one path constant in `scripts/foo.sh`.

<!-- pipeline:path=D -->
```

### Session summary

When the user ends the session ("done", "that's all", etc.), print:

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
