---
name: evaluate-issue-pr
description: Independently evaluate a PR's implementation against its approved plan. Run from inside the feature worktree. Can make fixes. Posts the verdict and stops — the orchestrator fires the auto-merge gate; --manual-merge records the opt-out for it. Direct invocation never merges: finish by hand with scripts/finish-manual-merge.sh. Usage: /pipeline:evaluate-issue-pr <issue_number> [--manual-merge]
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, mcp__playwright_*
---

## Boot

Source `pipeline.config` so `PIPELINE_*` variables are available:

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

Dispatch: `skills/fullsend/SKILL.md` Step 7. Model: `PIPELINE_STAGE_MODEL_PR_EVAL` (unset ⇒ `opus`, a pin; never gated). Rationale: `docs/evaluate-issue-pr-design-notes.md`.

# Issue Evaluator

Review the PR against its approved plan with only the plan and the diff. Check off every plan item; look for what was NOT done. **Fix-vs-flag:** fix small issues yourself (typos, missing imports, off-by-one); flag anything touching **more than 3 files** or needing new design decisions. Never refactor or improve beyond the plan.

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

- **Scope at pr-eval time.** Guard claims are claims about artifacts the diff adds or modifies, plus any pre-existing guard the PR claims now covers a case. Execute from the feature worktree. Run the positive and negative probe of ONE guard claim in one Bash call (`cmd A; echo "rc=$?"; cmd B; echo "rc=$?"`); never re-run the suite per probe. **CI is the oracle for pre-existing failures:** read the head's settled CI status (Step 5) and verify only the diff's own claims — never re-prove an untouched failure in a base clone. **`PRE-EXISTING:` list check:** for each entry in the PR body's `## Pre-existing failures` list run the subject check (`grep -F -e <basename> -e <dir>/ <test>` per touched path). A listed subject test is Flagged and fixed in-eval; a body claiming untouched failures without the list is Flagged.

## Steps

1. **Fetch the approved plan.** Only a **trusted-authored** `## Implementation Plan` comment counts (`OWNER` / `MEMBER` / `COLLABORATOR`); trust is delegated to `filter-trusted-comments.sh`, which drops other authors before selection, so trust dominates recency. On rc 1 STOP: "No implementation plan found for issue #N."
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-pr-fetch-plan.sh" <N>
   ```
   **Plan amendments:** when it prints `PLAN-AMENDMENTS` (verdict `Revise`), the `**Recommendations:**` join the plan of record: Phase 1 scores plan + amendments, an implemented amendment is on-plan, and an unimplemented one is a Phase 1 `**Dropped amendment:** <recommendation>` finding, BLOCKING like a missing plan item.

2. **Fetch the PR diff.** Prints `PR_NUM=<PR>` and the diff; rc 1 ⇒ STOP.
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-pr-diff.sh"
   ```

3. **Read context:** `CLAUDE.md`, and for each file printed by `ls -1 .claude/scratch/issue-<N>/`, invoke `Read` exactly once before scoring.

4. **Two-phase review.** Run the orchestrator-injected review skills (`PIPELINE_PATH_<X>_SKILLS_EVALUATE_PR`) first if present.

   **Phase 1 — Plan compliance.** Every "Files to change" entry modified as described; schema / API / frontend / test changes made or skipped; flag scope creep and missing work. A planned non-test artifact path not tracked by `git ls-files` is missing work.

   **Phase 2 — Code quality.** Read CI status from the preflight line (Step 5) first; never `--watch` here. One foreground call, at most once per eval, never via `run_in_background`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-pr-checks.sh" <PR> --preflight "<PREFLIGHT line>"
   ```
   It typechecks if configured, trusts a green rollup, else runs touched tests. Look for debug leftovers, missing boundary error handling, injection/XSS, untested features.

   - **Executable verification:** verify every diff claim matching the trigger list by EXECUTING it plus a negative control, never by reading; an unexecuted claim is never reported verified.

<!-- BEGIN CI_CHECK -->
5. **CI status — trust the preflight line, re-arm after a push.** A red PR never receives Approved. Act on the `PREFLIGHT=`/`REASON=` line from `scripts/pr-eval-preflight.sh`:

   - `PREFLIGHT=ok` + `none`/`mergeable` — green: NO rollup read, NO `--watch`.
   - `ok` + `ci-pending` — emit the triple below, then judge it.
   - `ok` + `no-ci`/`ci-disabled` — Step 4 ran tests.
   - no line — run `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/pr-eval-preflight.sh" <N> --pr <PR>` once.
   - `block` — STOP: no verdict, report `block-<REASON>`.

   The line is STALE after any `git push` (Step 7 fixes, Step 8 rebase): then, and on `ci-pending`, re-emit the triple as THREE SEPARATE foreground `bash` calls (the hook compares row timestamps), PR number for `<PR>`:
   ```bash
   gh pr view <PR> --repo $PIPELINE_REPO --json statusCheckRollup
   ```
   ```bash
   timeout 600 gh pr checks <PR> --repo $PIPELINE_REPO --watch --fail-fast --interval 30
   ```
   ```bash
   gh pr view <PR> --repo $PIPELINE_REPO --json statusCheckRollup \
     --jq '.statusCheckRollup[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED") | {name: .name, conclusion: .conclusion, url: .detailsUrl}'
   ```
   Any FAILURE/CANCELLED forbids Approved: fix within budget, push, re-emit; else Flagged, failing jobs and first error line in `**CI status:**`.

   **Hook-enforced.** `hooks/enforce-ci-wait.py`, once a session reads the rollup, blocks Stop until a later `--watch` row and rollup row follow, and blocks Approved on red: emit all three or none.
<!-- END CI_CHECK -->

6. **Browser check.** If the diff changes anything a user sees in a browser, verify the executor's screenshot or take your own: start the app on a free port, open it with the Playwright MCP tools, screenshot the affected views, check the console for errors, attach the screenshot to the evaluation comment, and stop the server.

7. **Fix** (≤3 files, no new design): `git commit -m "fix: evaluation fixes for #<N> — <summary>"`, `git push`, re-run the checks.

8. **Rebase only when needed** — read mergeability here, never from `REASON`:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/evaluate-issue-pr-rebase-check.sh" <PR>
   ```
   Only on `REBASE=needed`: `git rebase origin/$PIPELINE_BASE_BRANCH`, push, re-arm Step 5. Textual conflict ⇒ `git rebase --abort`, evaluate the un-rebased branch, record `REBASE=conflict` (merge stage fixes it). Flag semantic conflicts.

9. **Post** `gh pr comment <PR> --repo $PIPELINE_REPO --body "<evaluation>"`:

   > **TERSENESS:** decisions, not narration. Reference `#N` / `#PR`; never paste the plan or diff. ≤3 one-line bullets per prose row; drop "None" rows.

   ```markdown
   ## Evaluation

   **Verdict:** Approved / Flagged for user review

   **Plan compliance:**
   - [x] <plan item> — implemented correctly
   - [ ] <plan item> — missing or incorrect: <detail>

   **Code quality:** <findings or "No issues found">

   **Guard claims verified:** (one line per guard claim: `<claim> - <positive cmd> -> <observed>; <negative cmd> -> <observed>`; `None` when the trigger did not fire)

   **CI status:** All checks passed / No CI configured / FAILED: <job names> — <first error line> / Timed out

   **Screenshots:** <links, or None>

   **Fixes applied:** `<commit hash>` — <description> (or "None")

   **Remaining issues:** (if flagged) <what needs human attention and why>
   ```

10. **Report:** "PR #X approved — ready for merge." or "PR #X flagged for review: <summary>" — terminal; the orchestrator fires the gate. End with zero or more `HARNESS-FRICTION: <what the doc/hook said> | <what was true>` lines.

## Constraints
- Never read executor logs. Only inputs: the trust-gated plan comment plus its trusted `## Plan Evaluation` when the verdict is `Revise`, PR diff, worktree code.
- Fixes stay minimal; never skip tsc or tests. Commits go to the feature branch; PRs target `PIPELINE_BASE_BRANCH`.
- Never merge, close issues, or change `pr-open` labels.
