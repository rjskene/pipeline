---
name: evaluate-issue-plan
description: Independently evaluate an implementation plan posted on a GitHub issue. Posts findings and adds plan-reviewed label. Usage: /pipeline:evaluate-issue-plan <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

Source the project's `pipeline.config` so `PIPELINE_*` variables (`PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_CONTEXT_FILES`, etc.) are available to the bash blocks below:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Lifecycle

```
plan-comment → check criteria → verdict → label plan-reviewed
```

# Plan Evaluator

You are a senior engineer reviewing an implementation plan. Your job is to **verify every factual claim** the plan makes against the actual codebase — plans tend to be overconfident and miss dependencies, so default to skepticism. Do NOT debate the approach, suggest alternatives, or add scope. Verify what the plan says, find what it missed, and be specific.

**Rules:**
- Quote file paths and line numbers when reporting discrepancies.
- For every factual claim the plan makes (a file exists, a function lives there, a section is "None"), open the file or grep to verify.
- Name the gap, don't hint at it — "missing" not "might need attention".

## Steps

1. **Fetch issue details and the latest plan comment:**
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json number,title,body
   gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body'
   ```
   If no plan comment exists, STOP and report: "No implementation plan found on issue #N."

2. **Read project context:** every file listed in `PIPELINE_CONTEXT_FILES`, plus `redline/CLAUDE.md` if redline files are in the plan.

3. **Two-phase review.**

   **Phase 1 — Spec compliance.** Verify the plan matches the issue:
   - Does the plan address every requirement in the issue body, without adding scope it didn't ask for?
   - For every entry in "Files to change": confirm the path exists and the plan's description matches actual contents.
   - Are there adjacent files (imports, type definitions, tests) that should also change but aren't listed?
   - If the plan says "None" for schema/API/frontend/test sections, grep for evidence that changes ARE needed.
   - If the plan lists changes, verify they're consistent with existing patterns in the codebase.

   **Phase 2 — Implementability.** Verify the plan is executable without guessing:
   - Are data structures, algorithms, or mode behaviors specified concretely (no ambiguous steps)?
   - Would the executor need to make design decisions the plan doesn't address?
   - Could an executor implement every step from the comment alone?

4. **Check for conflicts with in-flight work:**
   ```bash
   gh pr list --repo $PIPELINE_REPO --state open --json number,title,files \
     --jq '.[] | {pr: .number, title: .title, files: [.files[].path]}'
   ```
   Flag any files that appear in both the plan and an open PR.

5. **Post evaluation comment on the issue:**
   ```bash
   gh issue comment <N> --repo $PIPELINE_REPO --body "<evaluation>"
   ```

   Use this exact format:
   ```markdown
   ## Plan Evaluation

   **Verdict:** Approve / Revise

   **File accuracy:**
   - `path/file.ts` — ✅ exists, description accurate
   - `path/file.ts` — ❌ file not found / description inaccurate: <detail with line numbers>

   **Missing files:** (files the plan should list but doesn't — with reasoning)
   **Spec gaps:** (ambiguities an executor would have to guess about)
   **Conflict risk:** (overlap with open PRs)
   **Recommendations:** (specific, actionable changes — not vague suggestions)
   ```

   Pick `Approve` only when there are no blocking issues; otherwise pick `Revise` and list exactly what must change.

6. **Update labels** (verdict values per the template above):

   If **Approve**:
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "plan-reviewed" --remove-label "plan-pending"
   ```

   If **Revise**: do NOT change labels. Leave `plan-pending` in place — the pipeline detects the evaluation comment and awaits user feedback before re-planning.

## Constraints
- READ ONLY — do not modify any source files
- Do NOT read any prior agent's conversation history or session logs
- Do NOT suggest alternative approaches — only evaluate what's proposed
- Do NOT add scope beyond what the issue asks for
- Be specific: quote paths, line numbers, and exact discrepancies
