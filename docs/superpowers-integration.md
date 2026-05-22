# Superpowers Integration

Where pipeline stages invoke superpowers skills. Companion to `CLAUDE.md` § "Pipeline vs Superpowers".

## Mental model

- Pipeline = outer workflow; superpowers = inner tools. Pipeline orchestrates; superpowers execute.
- Pipeline skills declare superpower dependencies at point-of-use via `Skill(skill: "superpowers:<name>")` (Task tool dispatch for `superpowers:code-reviewer`).
- Composition is per-stage, not global: a single pipeline run can invoke 0–5 distinct superpowers depending on PATH.
- Pipeline owns lifecycle (labels, branches, PRs); superpowers own discipline (brainstorming, planning, TDD, review).
- Authoritative invocation sites live in each `skills/<stage>/SKILL.md`; the table below is the index, not the spec.
- See `CLAUDE.md` § "Pipeline vs Superpowers" for the framing; this doc is the per-stage map.

## Per-stage integration table

| Pipeline stage | Superpower invoked | Invocation site |
|----------------|--------------------|-----------------|
| `create-issues` | `superpowers:brainstorming` | `skills/create-issues/SKILL.md` § Step 2 "Refine the idea" |
| `plan-issue` | `superpowers:writing-plans` | `skills/plan-issue/SKILL.md` § Step 5 "Generate the implementation plan" |
| `plan-issue` | `superpowers:requesting-code-review` | `skills/plan-issue/SKILL.md` § Step 5 (emitted as final Task N in plan output) |
| `execute-issue-plan` (PATH B) | `superpowers:test-driven-development` | `skills/execute-issue-plan/SKILL.md` § Step 5 (Task 0 directive) |
| `execute-issue-plan` (PATH C) | `superpowers:test-driven-development` | `skills/execute-issue-plan/SKILL.md` § Step 5 (via `tdd-implementer` subagent dispatch with `target=<dir>` sentinel) |
| `execute-issue-plan` (PATH D) | `superpowers:test-driven-development` (inline) | `skills/execute-issue-plan/SKILL.md` § Step 5 (executor IS tdd-implementer; no subagent) |
| `execute-issue-plan` (all paths) | `superpowers:requesting-code-review` | `skills/execute-issue-plan/SKILL.md` § Step 8a "Author self-check" |
| `execute-issue-plan` (all paths) | `superpowers:code-reviewer` | `skills/execute-issue-plan/SKILL.md` § Step 8b (Task tool subagent dispatch) |
| `execute-issue-plan` (all paths) | `superpowers:receiving-code-review` | `skills/execute-issue-plan/SKILL.md` § Step 8c "Triage findings" |
| `execute-issue-plan` (post-PR feedback) | `superpowers:receiving-code-review` | `skills/execute-issue-plan/SKILL.md` § "If evaluate-issue-pr flags the PR" |
| `hotfix` | `superpowers:test-driven-development` | `skills/hotfix/SKILL.md` § red→green→commit loop |

## Worked example (PATH B issue)

Bullet timeline — one standard issue (`label: (none)`) from filed to merged. Each superpower invocation shown in order.

- Issue filed → `/pipeline:classify-issue` → no superpower (heuristic + label).
- `/pipeline:plan-issue` → invokes `superpowers:writing-plans` → returns plan body → posted as comment → `plan-pending` applied.
- `/pipeline:evaluate-issue-plan` → no superpower (independent reviewer agent).
- Human approves → `plan-approved`.
- `/pipeline:execute-issue-plan` Step 5 → invokes `superpowers:test-driven-development` (Task 0) → executor applies red→green→commit per task.
- `/pipeline:execute-issue-plan` Step 8a → invokes `superpowers:requesting-code-review` → self-verify plan compliance + green tests.
- `/pipeline:execute-issue-plan` Step 8b → Task tool dispatches `subagent_type: "superpowers:code-reviewer"` → returns findings.
- `/pipeline:execute-issue-plan` Step 8c → invokes `superpowers:receiving-code-review` → triage findings (must-fix / nice-to-have / incorrect) → fix or reject inline.
- PR opened → `/pipeline:evaluate-issue-pr` → if flagged, re-invokes `superpowers:receiving-code-review` in executor session.
- Auto-merge on green → `merged`.

## Extension guide for skill authors

How to add a new superpower dependency to a pipeline skill.

- Pick the invocation pattern:
  - `Skill(skill: "superpowers:<name>")` — in-session skill invocation. Use for brainstorming, planning, TDD, review-request, review-triage.
  - Task tool with `subagent_type: "superpowers:<name>"` — fresh-context subagent dispatch. Use for code review and other isolated-context work.
- Add the invocation at the point-of-use in `skills/<stage>/SKILL.md`. Place under the step heading the superpower supports; do not centralize in a separate section.
- Pass the minimal context the superpower needs (issue title/body, plan comment, codebase findings, PATH letter, etc.). Tell it explicitly what NOT to do (e.g., "Do NOT save to disk; return content").
- Update the per-stage table in this doc — add one row per `(stage, superpower, invocation site)` triple. Use the exact heading text from the SKILL.md so the site reference is greppable.
- Contract-test hook expectations:
  - PATH C: the `enforce-path-c-delegation` PreToolUse hook blocks orchestrator Write/Edit on impl files; superpower invocations must route through `tdd-implementer` subagent dispatch.
  - PATH D: no subagent dispatch — inline only. Hook-equivalent enforcement lives in `skills/execute-issue-plan/SKILL.md` Step 5.
  - Base-branch enforcement: any superpower that opens PRs must pass `--base "$PIPELINE_BASE_BRANCH"` (defense-in-depth at eval-time gate, skill-level, and PreToolUse hook).
- Do NOT introduce superpower invocations from pipeline scripts (`scripts/*.sh`) — superpowers are session-level skills and must be invoked from skill markdown only.
- Out of scope for this doc: graceful-degradation behavior when a superpower is not installed (see `CLAUDE.md` design principle #3); instrumentation to verify agents actually invoke documented superpowers (separate issue).
