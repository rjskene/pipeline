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
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash code blocks below reference these variables via `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time. When prose refers to a config value by name (e.g., "the base branch is `PIPELINE_BASE_BRANCH`"), look it up in the sourced config.

# Issue Creation Mode

```
brainstorm → scope check → grouping check → proposal → confirm (auto-skipped for single standalone) → create
```

You are in **brainstorming / issue-creation mode**: help the user discuss problems, feature ideas, refactors, bugs, or improvements — and turn actionable items into GitHub issues. You must NOT implement code changes directly.

**Argv:** `--confirm` is the only flag this skill reads. It forces the confirmation gate even on the single-standalone auto-create path (see "Auto-accept the single-standalone case" below). One-off, no persistence, no config key.

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
3. **Scope check — combine bias, fewer issues by default.** Take your own read. Default toward a SINGLE issue: if the candidate slices are clearly one concept, OR they would touch **overlapping files**, share one implementation plan, or hit the **same subsystem**, propose one issue and proceed silently. Splitting clustered same-file work buys no parallelism — the execute-stage wave planner serializes same-file issues into separate waves anyway — and pays N× the fixed per-issue overhead (N× classify, N× plan, N× the shared execute-prefix cache, N× PR/merge). Worst case: pay the split cost, get none of the benefit.

   **Only split on genuinely independent surfaces:** disjoint file sets, separate ship/review/merge moments, distinct subsystems. When you do split, surface a decomposition prompt — lead with your read (1–2 sentences), **name the file overlap and the "serialize + N× overhead" cost** when you recommend combining vs splitting, present 2–3 slicing options with trade-offs, ask the user to pick. One message, option list, no follow-ups.

   **Upper bound — don't over-combine:** keep genuinely independent ship/review/merge boundaries separate; respect the single execute agent's context-window ceiling (a combined issue must still fit one agent's working set); combining reduces per-PR CHANGELOG granularity (usually fine — one logical change = one entry). The bias is toward fewer, not toward one-issue-always.

   **Path-agnostic.** Do not assign or hint a path here. A combined same-subsystem issue is fine as a single larger unit; `classify-issue` decides the path downstream.
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

**Auto-accept the single-standalone case (default-on).** Skip the confirmation gate and create immediately **only when BOTH conditions hold**:

1. scope-check produced **exactly 1 issue** (no split), AND
2. grouping-check returned **`REC=STANDALONE`** (no `TRACKER`, no `GROUP`).

This is precisely the case where no judgment is being exercised — the operator almost never rejects the body itself, and there is no split/grouping override moment to preserve. On auto-accept, do NOT print a `(y/n)` prompt; print the one-line notice verbatim:

```
Auto-creating (single standalone, no confirm gate — pass --confirm to gate)
```

then proceed straight to creation and echo the resulting `Created: #N — <title> — <url>` line. The body is NOT re-rendered (same as the rule below).

**The gate still fires on any split, tracker, or group.** Whenever scope-check produced a split (N≥2 issues), OR grouping-check returned `TRACKER` or `GROUP`, the existing confirmation prompt stays — it keeps the gate so the operator can exercise the scope/grouping override. The auto-accept path is the single-standalone case only.

**`--confirm` override.** When `--confirm` is in the create-issues argv, force the confirmation gate even on the single-standalone path (the gate stays, no notice is printed). One-off, no persistence, no config key — there is deliberately **no** config flag for this behaviour (Option C was rejected to avoid growing the config surface).

**Do NOT render the full issue body** (Context / Scope / Affected areas / Notes) inline. The user already saw the reasoning in discussion; the body is persisted on GitHub. You still build the body internally — just don't print it before creation.

**Multi-issue case — default to including a tracker.** When scope-check landed on 2+ issues, add a tracker as the last line marked `(pending tracker)`:

> Reaching this case means scope-check (step 3) already cleared the combine bias — the slices are genuinely independent surfaces, not clustered same-file work.

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
- If the user's framing is architectural critique, open-ended exploration, or "should we / could we" without a commit-to-act, propose creating with `--label brainstorm`. The label parks the issue in the discussion bucket — visible in `/pipeline:status` (stage = `brainstorm`) but never auto-planned or auto-executed. User promotes by removing the label.

### PATH D body marker (advisory)

If the issue you are drafting describes a precedent-mirror fix, one-line config flip, dogfood-mirror edit, or guard-test addition, include `<!-- pipeline:path=D -->` in the body at filing time. This is the authoritative route to PATH D — phrase heuristics in `skills/classify-issue/SKILL.md` will not reliably flip a structured body to D. See the `### PATH D (quick-fix)` section in `skills/classify-issue/SKILL.md` (and its `#### Blast-radius B→D routing` subsection) for the full list of shapes.

Filing-time backstop: when a `fix(` draft names ≤ 2 non-test source files in a single module under `## Affected areas` AND carries no high-uncertainty signal (concurrency/race/lock/deadlock/security/auth/crypto/migration/data-loss), propose adding `<!-- pipeline:path=D -->` — the filing-time mirror of the classifier's Blast-radius B→D rule, carrying the same carve-out (high-uncertainty `fix(` work stays B).

Example:

```
## Context
Same path-math family as #277 — fix one path constant in `scripts/foo.sh`.

<!-- pipeline:path=D -->
```

### PATH hint body marker (advisory)

When the combined issue's discussion gives a clear **A/B/C** signal, append `<!-- pipeline:path-hint=A|B|C -->` to the body at filing time. This is **advisory** only — `classify-issue` reads it as one prior in its score table and may override it.

This is deliberately **distinct** from the authoritative `<!-- pipeline:path=D -->` marker above: the syntax is `path-hint=` (note the `-hint`), **different from** the authoritative `path=`. The two can never be confused — the hint parser cannot match `path=` and the authoritative parser cannot match `path-hint=`.

Rules:

- **Letters A/B/C only.** `D` is NEVER a hint — D keeps its **authoritative** `<!-- pipeline:path=D -->` route (above). A `D` letter in the hint slot is malformed and silently ignored by `classify-issue`.
- **Emit only on a clear signal — silence = no hint.** This preserves create-issues' **path-agnostic** default: when there is no clear A/B/C signal, write no marker and `classify-issue` decides cold. The motivating case is a combined clustered unit that could plausibly be B or C — there the hint earns its keep.
- **Advisory, not a gate.** An explicit path label and the authoritative `pipeline:path=D` marker both outrank the hint inside `classify-issue`; it never short-circuits classification.

Example (a clustered B/C unit you read as standard B):

```
## Context
Single combined change to `scripts/foo.sh` and its one test.

<!-- pipeline:path-hint=B -->
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
