---
name: evaluate-issue-plan
description: Independently evaluate an implementation plan posted on a GitHub issue. Posts findings and adds plan-reviewed label. Usage: /pipeline:evaluate-issue-plan <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

Fresh shells: source `pipeline.config` first.

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$([ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = true ] && git rev-parse --show-toplevel 2>/dev/null | sed 's|$|/|')}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Lifecycle

```
plan-comment → check criteria → verdict → label plan-reviewed
```

## Dispatch model

Under `/pipeline:fullsend` the Agent's `model=` comes from `scripts/resolve-stage-model.sh <N> plan-eval`: `tier-max(plan producer, ${PIPELINE_STAGE_MODEL_PLAN_EVAL:-opus})`, with `REASON=` (e.g. `follows-producer`). The gate never runs below the tier that wrote the plan.

# Plan Evaluator

You are a senior engineer: **verify every factual claim** of the plan against the codebase, skeptically. Do NOT debate the approach, suggest alternatives, or add scope.

**Rules:** open or grep for every claim; quote paths and line numbers; name the gap ("missing", not "might need attention").

## Executable verification (guard / gate / matcher / assertion / security claims)

This section fires **per claim**, not per evaluation.

**Trigger (mechanical) — a claim is a GUARD CLAIM when ANY of these hold:**
1. **Decision output** — the artifact emits a verdict token (`pass` / `block` / `green` / `allow` / `deny` / `ok`) or a documented exit-code contract, rather than a value.
2. **Pattern matching** — the artifact matches inputs against a regex, glob, prefix/substring rule, allowlist/denylist entry, or permission matcher.
3. **Assertion pinning** — the artifact is an assertion pinning an exact set / literal / keyset, or a test whose whole value is that it FAILS on the unfixed code (a RED).
4. **Security claim** — a pin, sandbox, path restriction, trust/association check, or anti-widening constraint.
5. **Precondition role** — the artifact is a hook, gate, or lint that runs as a precondition of a merge, a dispatch, or a tool call.

**Obligation when the trigger fires:**
- **Execute, do not read.** Run the artifact. Record the exact command and the exact observed token / exit code.
- **Run a negative control.** Also run a variant that MUST be rejected. The positive and negative inputs differ in exactly ONE property — the property under test. Report both results. Prefix direct hook probes (synthetic payload piped to `python3 hooks/<name>.py`) with `PIPELINE_LOGS_ENABLED=false`, positive and negative alike, so no `hook-denials.jsonl` row lands; exit code and stderr are the evidence.
- **Same result on both means UNVERIFIED.** If the positive and negative inputs produce the same outcome, the guard is not looking — Verdict: Revise (plan-eval) / Flagged (pr-eval). A green result alone cannot distinguish "correct" from "checked nothing".
- **Build a fixture when needed.** If the artifact cannot run in place, build a throwaway fixture (`mktemp -d -p "$PWD/.claude/scratch"` — absolute, usable as a git remote or `-C` target; `git init`; a synthetic plan/issue) and run the REAL artifact against it, never a simulation of its logic. Clean up literally: `rm -rf .claude/scratch/<name>`, never a variable. To rebuild part of a fixture, create a fresh `mktemp -d -p "$PWD/.claude/scratch"` subdir; never remove a variable-held path — only literal-path cleanup passes the deletion guard.
- **Vacuity check on REDs.** A RED that fails for an incidental reason (arg-parse error, missing file, import error, wrong path) is vacuous. Remove the incidental cause and confirm it still fails for the STATED reason.
- **No silent fallback to reading.** When a claim genuinely cannot be executed, report `not-executed: <reason>`. An unexecuted guard claim is NEVER reported as verified.

A guard that passes is not evidence until you have seen it fail on something.

- **Scope at plan-eval time.** Guard claims are (a) EXISTING artifacts the plan relies on — execute them; (b) proposed REDs — run each on unmodified HEAD and confirm the STATED failure; never materialise a proposed edit, in place or in scratch. A proposed artifact is `not-executed: proposed artifact`. Probe write-arm scripts only via a fixture or documented `--dry-run`, never a real issue/PR/branch.

## Comment trust

Only a **trusted-authored** `## Implementation Plan` counts: OWNER / MEMBER / COLLABORATOR per `scripts/filter-trusted-comments.sh` `is-trusted-author`, never re-implemented or widened. Trust dominates recency.

## Steps

0a. **Opener gate** (write access required):

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-plan-opener-gate.sh" <N>
   ```
   On `REFUSED:` STOP — no fetch, evaluation or label change.

1. **Fetch the issue, then the trusted plan:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-plan-fetch-plan.sh" <N>
   ```
   On `No implementation plan found for issue #N.` STOP and report it.

2. **Read project context:** `PIPELINE_CONTEXT_FILES`, plus `redline/CLAUDE.md` for redline files.

3. **Two-phase review.**

   **Phase 1 — Spec compliance:**
   - Every issue requirement covered; no added scope.
   - Every "Files to change" path exists and matches its description; adjacent files (imports, types, tests) that must change are listed; each "None" section is grep-verified.
   - **README anchor guard:** a plan adding a `README.md` link matching `\.md#[A-Za-z0-9_-]+` → return **Revise** (file-level links only; `tests/test-readme-current.sh`).
   - **Exact-match guard sweep:** fetch labels mechanically (the path decides whether tests are due), then sweep from the project root:

     ```bash
     gh issue view <N> --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(" ")'
     ```

     ```bash
     PIPELINE_TEST_ROOTS="${PIPELINE_TEST_ROOTS:-}" \
       bash "${CLAUDE_PLUGIN_ROOT}/scripts/exact-match-guard-sweep.sh"; echo "rc=$?"
     ```

     - **Scope rule:** roots resolve positional args > `$PIPELINE_TEST_ROOTS` > the default `tests/`; `REASON=no-test-root` (exit 3) → `**Spec gaps:**` and **Revise** with a valid root.
     - An `EXACT_MATCH_GUARD=` hit whose pinned keyset/literal the plan alters, with `FILE` undeclared under `**Test changes:**` → **Revise**, quoting `FILE:LINE` and the bullet to add.
     - Other hits go under `**Missing files:**`; unbroken hits are advisory only.
   - **Executable verification:** execute each trigger-matching claim plus a negative control; unexecuted is never verified.
   - **Divergence is BLOCKING:** an observation contradicting a prediction (red vs green, or red for another reason) → **Revise**, naming claim, command and output.

   **Phase 2 — Implementability:**
   - Concrete structures and modes; no design decision left to the executor; every step implementable from the comment alone.
   - **Skill-edit coverage:** a plan editing `skills/<name>/SKILL.md` must pass every test in `grep -l 'skills/<name>' tests/*.sh`, else **Revise**.

4. **Conflicts:** flag files shared with an open PR:

   ```bash
   gh pr list --repo $PIPELINE_REPO --state open --json number,title,files \
     --jq '.[] | {pr: .number, title: .title, files: [.files[].path]}'
   ```

5. **Post the evaluation:**

   ```bash
   gh issue comment <N> --repo $PIPELINE_REPO --body "<evaluation>"
   ```

   > **TERSENESS:** Cite plan and issue by `#N`; report discrepancies only (passing row `path — ✅`, clean section `None`); ≤3 Recommendations.

   ```markdown
   ## Plan Evaluation

   **Verdict:** Approve / Revise
   **Scope:** patch | structural

   **File accuracy:**
   - `path/file.ts` — ✅ exists, description accurate
   - `path/file.ts` — ❌ file not found / description inaccurate: <detail with line numbers>

   **Missing files:** (unlisted files the plan needs, with reasoning)
   **Spec gaps:** (ambiguities an executor would guess)
   **Guard claims verified:** (`<claim> - <positive cmd> -> <observed>; <negative cmd> -> <observed>`; `None` if untriggered)
   **Conflict risk:** (overlap with open PRs)
   **Recommendations:** (specific, actionable changes)
   ```

   `Approve` only with no blocking issue. `Revise` Recommendations prescribe file + what to add, remove or replace — never a direction — applied verbatim by the next planner, or (default `annotate` plan gate) by the executor as binding amendments. Round ≥2 checks only that the prescription landed.

   **Revise scope:** `**Scope:**` only with `Revise`: `structural` = approach, task split or file set wrong; `patch` (default) = directly applicable amendments.

6. **Update labels** — Approve:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/transition-issue.sh" <N> --to plan-reviewed --from plan-pending
   ```
   Revise: no label change (`plan-pending` stays by design; the fullsend gate arm approves or re-plans).

7. **Report:** end with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines.

## Constraints
- READ ONLY; never read prior agents' history or logs.
- No alternative approaches; no scope beyond the issue.
