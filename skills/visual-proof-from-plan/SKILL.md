---
name: visual-proof-from-plan
description: Verify plan acceptance criteria against a reachable app using browser predicates; emits {satisfied, unsatisfied}. Invoked by execute-issue-plan (TDD loop) and evaluate-issue-pr (verdict).
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill, mcp__playwright_*
---

## Boot

Source `pipeline.config` first so `PIPELINE_*` variables are available:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Contract

**Input:**

- (a) The latest `## Implementation Plan` comment on issue `<N>` — this is the
  source of acceptance criteria and predicates.
- (b) A reachable HTTP base URL, supplied by a consumer-defined environment
  variable (e.g. `APP_BASE_URL`). All predicate navigation is resolved relative
  to this base.

**Output:** a single JSON object written to stdout. The literal shape is:

```
{"satisfied": ["<claim>", ...], "unsatisfied": [{"claim": "<string>", "artifact": "<path-or-error>"}, ...]}
```

- `satisfied` is an array of claim strings whose predicate evaluated truthy.
- `unsatisfied` is an array of objects, each pairing the failing `claim` with an
  `artifact` (a screenshot path on failed assertion, or an error string when the
  predicate could not be evaluated).

**Caller responsibilities:**

- (i) Ensure the browser MCP is reachable — this skill drives the app via the
  `mcp__playwright_*` tools and does not start a browser itself.
- (ii) Gate invocation on the `needs-browser` label; do not invoke this skill for
  issues that have no reachable UI.
- (iii) Interpret the result. This skill emits evidence only; the caller
  (`execute-issue-plan` for the TDD loop, `evaluate-issue-pr` for the verdict)
  decides what the `{satisfied, unsatisfied}` split means for its own outcome.

## Predicate grammar

Predicates are JavaScript expressions evaluated against the live DOM via
`mcp__playwright_*browser_evaluate`. The expression must return a value that is
truthy when the claim holds. For example:

```js
document.querySelectorAll("#events-table tbody tr").length > 0
```

A predicate may declare a navigation precondition (a URL to visit before
evaluation). See `references/predicate-syntax.md` for the full grammar:
querySelector predicates, count predicates, text predicates, and the URL
precondition syntax.

## Steps

### 4a. Parse the plan comment

Fetch the latest `## Implementation Plan` comment on issue `<N>`. Extract every
`predicate:` line that appears under an `**Acceptance criteria:**` or
`**Predicates:**` heading. Each extracted line is one claim with one predicate
expression (and an optional navigation precondition — see
`references/predicate-syntax.md`).

### 4b. Evaluate each predicate

For each predicate:

1. Navigate to the predicate-declared URL (resolved against the consumer base
   URL) using `mcp__playwright_*browser_navigate`. If no URL is declared, use the
   current page.
2. Run `mcp__playwright_*browser_evaluate` with the predicate expression.
3. Capture a screenshot to
   `.claude/scratch/visual-proof-<N>/<predicate-hash>.png` for evidence.
4. Classify the result: a truthy return value is `satisfied`; a falsy value or
   an evaluation error is `unsatisfied` (record the screenshot path or the error
   string as the `artifact`).

### 4c. Emit the result

Write the single JSON object described in `## Contract` to stdout:

```
{"satisfied": ["<claim>", ...], "unsatisfied": [{"claim": "<string>", "artifact": "<path-or-error>"}, ...]}
```

## Constraints

- This sub-skill **never edits source files** — it only reads the plan and drives
  the browser to gather evidence.
- This sub-skill **never decides a verdict**. The `{satisfied, unsatisfied}`
  split is evidence; callers (`execute-issue-plan`, `evaluate-issue-pr`) own the
  decision.
- This sub-skill **never assumes a specific framework**. Predicates are plain DOM
  expressions evaluated against whatever the consumer app serves at the base URL.
