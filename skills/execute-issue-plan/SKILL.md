---
name: execute-issue-plan
description: Implement the approved plan for a GitHub issue. Run from inside the feature worktree. Usage: /pipeline:execute-issue-plan <issue_number>
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, Skill, mcp__playwright_*
---

## Boot

Subagent invocations run in fresh shells, so source `pipeline.config` first:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

State (slate, base branch, repo) is inherited from `/pipeline:fullsend`; if these variables fail to resolve, **STOP** — preconditions live in `skills/fullsend/SKILL.md`.

## Platform

Skills use Claude Code tool names; on Codex see [references/codex-tools.md](../references/codex-tools.md) for equivalents.

## Lifecycle

```
worktree spawn → inline orchestrator-owned Agent(tdd-implementer) fan-out (PATH C, DEFAULT; spawn-claude tdd-implementer only under `--spawn`) | inline Agent (PATH A/B, PATH D tdd) → push → PR
```

## Invocation mode

Every step below behaves identically across modes — only the working-directory setup differs:

| # | Mode | CWD setup | Used by |
|---|------|-----------|---------|
| 1 | Inline `Agent(...)` dispatch | `cd <worktree-absolute-path>` (prompt provides it) | PATH A (docs-only), PATH B (standard) |
| 2 | Inline orchestrator-owned `Agent(tdd-implementer)` fan-out (DEFAULT); `spawn-claude.sh` / `claude -p` dispatch only under `fullsend --spawn` | each leaf `cd`s into its OWN per-leaf worktree (`path-c-split-worktree.sh setup`); orchestrator reassembles into the feature worktree via cherry-pick (#896) | PATH C (multi-task) |
| 3 | PATH D inline tdd-implementer | `cd <worktree-absolute-path>` (same as mode 1) | PATH D (quick-fix) |

### Collapsed inline D contract

When dispatched as the collapsed PATH D agent (mode 3), this agent is the PRODUCER of the classify + plan stages, not a downstream consumer of upstream-posted comments. It RUNS classify and plan inline FIRST — emitting the two stage records as inline side-effect checkpoints (see below) — and THEN carries that context straight into execution. So this agent **carries the classify+plan context forward** within its own single session and **does NOT re-read the plan comment** from GitHub: there is no separate plan-comment fetch (step 1's `gh issue view ... ## Implementation Plan` read is skipped on PATH D, and because the plan is already in-context the STOP-on-empty guard never fires). The two inline side-effect **checkpoints**, byte-shaped exactly as the standalone classify/plan stages would have posted them, are:

- a `## Classification` checkpoint carrying the recommended **path label** (`quick-fix` / PATH D);
- a `## Implementation Plan` checkpoint with the `plan-pending` marker.

**Escalation backstop.** The collapsed D agent runs inside D's small **envelope** (the `## Affected areas` prediction: one file, ≤ ~20 LOC, single precedent). If mid-run it discovers the change **exceeds D's envelope** — it touches more files than `## Affected areas` predicted, needs a real plan, or hits unforeseen coupling — it does NOT force a too-large change through the D lane. It **aborts up** / **escalates** to a **full PATH B run**: real planning plus a full execute session (per #748 PATH B execute now runs as an inline `Agent`, not a spawned `claude -p` worker). This is what makes a wrong B→D down-route cheap and recoverable — the backstop reverses it rather than shipping a too-large diff through D.

# Execution Agent

You will receive an issue number as the argument. Ensure CWD is the feature worktree (per the table above), then perform these steps:

## Steps

**0b. CI-fix mode.** If `$PIPELINE_CI_FIX_CONTEXT` is non-empty, you were dispatched to fix a red CI run on an existing PR — not to implement a new plan. Skip steps 1–4 and step 9. Read the failure log at `$PIPELINE_CI_FIX_CONTEXT` and run `gh pr diff` to see the PR so far. Diagnose the failure, apply red→green→commit TDD discipline for the fix, run step 6 (Validate) once, then push the follow-up commit to the existing branch with `git push`. Do NOT call `gh pr create`. Do NOT change the `pr-open` label. Report the new commit SHA back to the orchestrator.

1. **Fetch the approved plan** — find the latest comment containing `## Implementation Plan` (latest wins, supports revisions). **PATH D skip:** the collapsed inline D agent carries the classify+plan context forward and does NOT re-read the plan comment (see the Collapsed inline D contract above) — skip this fetch on PATH D and use the in-context plan.
   ```bash
   gh issue view <N> --repo $PIPELINE_REPO --json comments \
     --jq '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body'
   ```
   If empty/`null`, **STOP**: "No implementation plan found on issue #N. Run `/pipeline:plan-issue N` first."

   Then list every file under `.claude/scratch/issue-<N>/` — screenshots/binary evidence the planner saw, mirrored into this worktree by `setup-worktree.sh` / `sync-worktrees.sh` (this skill does NOT re-fetch):

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

   **For each file printed by `ls -1`, invoke the `Read` tool exactly once before implementing.** If the directory is empty or absent, continue.

2. **Read project conventions:** Read `CLAUDE.md` in the worktree root.

3. **Dependency check — issue #5 only:** If this is issue #5 (project-numbers), verify `feature/schema-cleanup` has merged:
   ```bash
   gh pr list --repo $PIPELINE_REPO --state merged --json headRefName --jq '[.[].headRefName]'
   ```
   If absent, **STOP**: "Issue #5 is blocked — feature/schema-cleanup has not been merged yet."

4. **Mark as in-progress:**
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "in-progress" --remove-label "plan-approved"
   ```

5. **Implement the approved plan.** Follow the plan's `**Tasks (ordered):**` section exactly — it carries the path-specific Task 0 directive (PATH A: flat edits; PATH B: invoke `superpowers:test-driven-development`; PATH C: dispatch `tdd-implementer` subagents with `target=<dir>` sentinels).

   **PATH C (`multi-task`) — inline orchestrator-owned fan-out with per-leaf worktrees (DEFAULT).** On PATH C the orchestrator itself reads the `## Implementation Plan` and, for each `target=<dir>` in the plan, dispatches one leaf `Agent(subagent_type='tdd-implementer', description='target=<dir>/ ...', prompt='cd <leaf-worktree>; target=<dir>/ ...')`, then handles push + `gh pr create` + label flip itself (Steps 9–10). The orchestrator MUST NOT `Edit`/`Write` impl files directly: the `enforce-path-c-delegation` hook blocks direct orchestrator Edit/Write and authorizes only files under a dispatched `target=<dir>` sentinel. `tdd-implementer` stays a hard leaf executor (the `Agent` tool is removed from its toolset) dispatched from the top level — no grandchild dispatch. Each dispatch carries a real-subdirectory `target=<dir>/` sentinel (`target=.`/`./`/`/` are rejected by the hook) and applies red→green→commit autonomously.

   **Per-leaf worktrees (the #896 fix — eliminates the shared-index race).** Each leaf gets its OWN worktree+branch off the feature-branch worktree HEAD, so concurrent leaves never share a git index. Without this, leaves committing in the same worktree race: transient `index.lock` collisions and one leaf's files swept into another leaf's commit (the #894 c+d collision), breaking per-target commit isolation and the per-PR CHANGELOG granularity contract. Drive it with `scripts/path-c-split-worktree.sh`:
   - **Setup** — for each `target=<dir>`: `LEAF=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" setup <feature-worktree> <target>)`; dispatch that target's leaf with `cd $LEAF` in its prompt.
   - **Reassemble** — after ALL leaves report committed: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" reassemble <feature-worktree> <target> [<target> ...]` cherry-picks each leaf's commits onto the feature branch (disjoint targets ⇒ conflict-free; cherry-pick is a git op so it does NOT trip `enforce-path-c-delegation`). A conflict means the targets were not actually disjoint — the helper aborts and errors; re-plan the overlap rather than forcing it.
   - **Teardown** — `bash "${CLAUDE_PLUGIN_ROOT}/scripts/path-c-split-worktree.sh" teardown <feature-worktree> <target> [<target> ...]` removes the leaf worktrees + branches before push.

   Because each leaf has an isolated index, **concurrency is bounded only by orchestrator context, not by a git-index cap** — the live branch test (#894/#896) confirmed leaf returns are ~one line each with negligible context cost, so non-overlapping targets may fan out fully concurrently (keep leaf returns terse). **Under `fullsend --spawn`, PATH C reverts to the legacy `spawn-claude.sh` → `tdd-implementer` fan-out** (the reversible escape hatch, #750) — same per-target sentinel + TDD discipline, different transport; the spawned path already isolates per worker so it needs no split-worktree step.

   On PATH D (label `quick-fix`), you ARE tdd-implementer — apply red→green→commit directly inline in a single pass: single failing test → impl → pass → commit, once. No subagent dispatch, no skill invocations beyond this one. This is single-pass discipline, not ceremony: the failing-test gate (red→green→commit) is mandatory and is NOT skipped — what PATH D drops is the redundant pre-PR review double-check (Step 8, see the PATH D early-return contract below), since `evaluate-issue-pr` is D's sole external review gate. (And if the change turns out to exceed D's envelope mid-run, escalate per the Collapsed inline D contract above rather than forcing it through.)

   On `needs-browser` issues, each `tdd-implementer` dispatch (PATH C) or inline TDD task (PATH B/D) treats the predicates section as the test specification.

   `spawn-claude.sh`'s `--append-system-prompt` may inject path-specific skill invocations via `PIPELINE_PATH_<X>_SKILLS_EXECUTE` + `PIPELINE_PATH_<X>_SKILL_ARGS_EXECUTE_*`. Step 8 below owns the review flow explicitly, so leave `PIPELINE_PATH_<X>_REVIEWER_EXECUTE` unset; if set, the end-of-session dispatch becomes a harmless redundancy.

   In all cases: implement ONLY what the plan specifies (no scope creep); never commit to main; never use `--no-verify` or `--force`. If the plan/issue references a GH Actions CI-blocking marker (bracketed forms of `skip ci`, `ci skip`, `skip-ci`, `ci-skip`, `no ci`, `no-ci`, plus `***NO_CI***`), do NOT propagate the literal marker into any `git commit -m`, `gh pr create --title`, or `--body` — substitute a safe form: backticked `` `skip ci` ``, hyphenated `skip-ci`, or `skip CI` (no brackets). The `check-ci-skip-markers` PreToolUse hook blocks the literal form.

6. **Validate — types, tests, server, and UI.** Fix any failures at each sub-step before proceeding.

   **6a. Type check:**
   ```bash
   $PIPELINE_TYPECHECK_CMD
   ```
   **6b. Run tests (single sequential pass, stdin-guarded).** Run the configured `$PIPELINE_TEST_CMD` — the targeted/relevant test command for this project. Do NOT improvise an unbounded `for t in tests/test*.sh; do bash "$t"; done` sweep over unrelated tests: it pulls in tests this issue did not touch, any one of which may block on an interactive `read`. Always redirect stdin from `/dev/null` and bound each run with `timeout` so a single interactive or hanging test cannot wedge the executor:
   ```bash
   timeout 600 bash -c "$PIPELINE_TEST_CMD" </dev/null
   ```
   Run exactly ONE verification pass at a time — never launch concurrent full-suite invocations. Concurrent runs of stub/temp-file-sharing tests collide and report spurious failures, driving wasteful retry spins (issue #677). Before reaching this phase, the issue's OWN targeted test MUST already be green: a source edit that leaves the targeted test red is a red→green→commit violation — fix it (red→green→commit) before verification. Never commit past a red targeted test.

   **Run the suite SYNCHRONOUSLY in the foreground and read its exit code directly** (the `timeout 600 bash -c ...` line above runs in the foreground; its exit code is the result). Do NOT background a test monitor and then `Read` its `/tmp/...` output to learn the result: the dogfood boundary hook (`restrict_paths.py`) blocks reads under `/tmp` (outside the project boundary), so the `Read` fails and the agent narrate-and-yields — narrating an intention to "wait" ends the turn and strands committed-but-unpushed work (the #752 / #759 / #750 drop-out that the #764 dispatch-prompt band-aid did NOT durably fix). Never narrate "I'll wait for the suite" and stop; the suite has already finished synchronously when the Bash call returns. If async monitoring is ever genuinely required, write monitor output INSIDE the project boundary (`.claude/logs/` or `.claude/scratch/`, both allow-listed), never `/tmp`. **Monitor-yield ban (#912):** an agent must NEVER yield on a background `Monitor` it cannot resume across a turn boundary. The #912 recurrence (#838/#904) was exactly this — the agent narrated *"...Waiting for the sweep Monitor..."* and ended its turn; a dispatched Agent's turn ends the moment it stops emitting tool calls, so this strands committed-but-unpushed work. The suite runs SYNCHRONOUSLY in the foreground and its exit code is read directly (the contract above); if async monitoring is genuinely required, the agent MUST instead block via a bounded `BashOutput` poll to a terminal sentinel inside the project boundary — never narrate-and-yield on an un-awaitable background `Monitor`.
   **6c. Visual validation with Playwright** (Linux only, UI changes only): use Playwright MCP tools (configured in `.mcp.json`) to navigate to the frontend URL, screenshot affected views, and check `browser_console_messages` for JS errors. Fix and re-validate any visual issues. Backend-only changes do not require this step. (When clicking, prefer the `ref=` from `browser_snapshot` over CSS selectors with embedded quotes like `[type="submit"]` — the MCP server rejects the latter on the literal string; as of 2026-05-26.)

   **6d. Visual proof loop (needs-browser issues only):** If the issue carries the needs-browser label, after each plan section invoke `Skill(skill: "pipeline:visual-proof-from-plan")` passing the plan comment body. Iterate code→proof→code per section until the sub-skill reports `unsatisfied = []`. Commit the section. Proceed to the next section. This is the executor-side TDD loop with browser predicates standing in for unit tests; it does NOT replace 6a/6b which still run.

7. **Self-review checkpoint before opening PR.** Re-read the plan from step 1 and verify every item was implemented; run `git diff --stat` to check no unintended files were modified; grep for leftover debug code (`console.log`, `print(`, `debugger`, `TODO`, `FIXME`); verify no scope creep. Fix any issues found before proceeding.

8. **Pre-PR code review loop.**

   **PATH D early-return contract.** If labels contain `quick-fix` (PATH D), SKIP Step 8 in its entirety (8a–8e) and proceed to Step 9. What is skipped: the **pre-PR code review loop** — author self-check, independent reviewer dispatch, triage, fix commits, re-validate. Why: PATH D issues delegate review entirely to `evaluate-issue-pr` to keep the lane fast (one external review gate, not two). This is the contract `classify-issue` depends on when applying the `quick-fix` label — see `skills/classify-issue/SKILL.md` (PATH D row).

   For all other paths, Step 8 runs BEFORE `gh pr create` to catch plan-compliance gaps and real bugs while the branch is still local-only.

   **8a. Author self-check.** Invoke `superpowers:requesting-code-review` with the plan comment body (from step 1) as context. The skill verifies plan requirements are met, tests pass, and CI-equivalent checks are green locally. Fix any gaps and re-run step 6 before continuing.
   ```
   Skill(skill: "superpowers:requesting-code-review")
   ```

   **8b. Independent reviewer dispatch.** Dispatch a separate code-reviewer subagent (returns a list of findings or "LGTM"):
   ```
   Agent(
     subagent_type: "superpowers:code-reviewer",
     description: "Independent review of the implementation for issue #<N> against the approved plan",
     prompt: "<full plan comment body + git diff $PIPELINE_BASE_BRANCH..HEAD — flag plan-compliance gaps and real bugs; do not refactor>"
   )
   ```

   Step 8's review flow is synchronous — `Skill(...)` and `Agent(...)` calls block until they return, so there is no poll loop to bound here. If a future revision adds background-task coordination, it MUST wait via `scripts/wait-for-sentinel.sh` (bounded timeout), never an inline `until grep ...; do sleep N; done` poll (see Constraints).

   **8c. Triage findings.** Invoke `superpowers:receiving-code-review` with the reviewer's output. The skill classifies each finding as **must-fix** (plan-compliance gap, test gap, real bug → fix), **nice-to-have** (style, rename → skip unless trivial), or **incorrect** (reviewer misread → reject with a one-line rationale in the follow-up commit message).
   ```
   Skill(skill: "superpowers:receiving-code-review")
   ```

   Path-specific constraints when applying must-fixes:
   - **PATH C (`multi-task`):** any must-fix touching impl code MUST go through a fresh inline `Agent(tdd-implementer)` dispatch (or a spawned worker under `--spawn`) — the `enforce-path-c-delegation` hook blocks direct orchestrator `Edit`/`Write` on impl files regardless of transport.
   - **PATH B (standard):** must-fix code edits follow red→green→commit discipline.
   - **PATH A (`docs-only`):** must-fix edits are direct.
   - **PATH D (quick-fix):** step 8 is skipped entirely (see early-return contract above); this row only applies on forced re-entry.

   **8d. Commit fixes.** Commit each must-fix as its own `fix(review): ...` commit (skip if zero must-fixes).

   **8e. Re-validate.** Re-run step 6 once more to confirm the review fixes did not regress anything.

9. **Open a pull request.**

   **9a. Derive the PR title from the issue.** The PR title must be a strict Conventional-Commits string (`feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert(<scope>)?: <summary>`) so release-please can drive versioning + CHANGELOG. Issue titles are intentionally expressive (`bug(...)`, `epic(...)`, `skill: ...`) and must NOT pass through verbatim. Run the helper:

   ```bash
   PR_TITLE=$("${CLAUDE_PLUGIN_ROOT}/scripts/derive-pr-title.sh" <N>)
   rc=$?
   if [ "$rc" -eq 2 ]; then
     # exit 2 = tracker (epic title or `tracker` label) — these never get PRs.
     echo "ABORT: Issue #<N> is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
     exit 1
   elif [ "$rc" -ne 0 ]; then
     echo "ABORT: derive-pr-title.sh failed with exit $rc for issue #<N>" >&2
     exit 1
   fi
   ```

   Rule table (source of truth: `scripts/derive-pr-title.sh`):

   | Order | Condition | Action |
   |-------|-----------|--------|
   | 1 | Labels include `tracker` | exit 2 (refusal) |
   | 2 | Title matches `^epic\(` | exit 2 (refusal) |
   | 3 | Title is already Conventional Commits | passthrough |
   | 4 | Title matches `^bug\(<scope>\):` | rewrite to `fix(<scope>): <rest>` |
   | 5 | Labels include `bug` | `fix(<scope-or-general>): <summary>` |
   | 6 | Labels include `enhancement` | `feat(<scope-or-general>): <summary>` |
   | 7 | default | `chore(general): <summary>` |

   **9b. Open the PR.** Quote the `--base` value and guard against an unset `PIPELINE_BASE_BRANCH`: even when `enforce-base-branch.py` is absent or unregistered, the executor must pass `--base` quoted and non-empty so the eval-time `baseRefName` assertion in `evaluate-issue-pr` Step 11 has a meaningful base to compare against. This is the second of three defense-in-depth layers (PreToolUse hook → this guard → eval-time check).

   ```bash
   if [ -z "$PIPELINE_BASE_BRANCH" ]; then echo "FATAL: PIPELINE_BASE_BRANCH unset; refusing to call gh pr create" >&2; exit 1; fi
   gh pr create \
     --repo $PIPELINE_REPO \
     --title "$PR_TITLE" \
     --base "$PIPELINE_BASE_BRANCH" \
     --body "$(cat <<'EOF'
   Closes #<N>

   ## Summary
   <bullet points summarising what changed>

   ## Test plan
   - [ ] `PIPELINE_TEST_CMD` — all tests pass
   - [ ] Feature works end to end
   EOF
   )"
   ```

   `$PR_TITLE` is normalized by `scripts/derive-pr-title.sh`: any literal `../` substring is rewritten to `..⁄` (U+2044) before reaching this site — defense-in-depth against any PreToolUse hook that scans for path-escape substrings. Both `--title` and `--body` are also scanned by the `check-ci-skip-markers` hook; to *describe* a marker in the PR body, wrap it in backticks (e.g. `` `[skip ci]` ``) so GH Actions does not honor it.

10. **Mark as pr-open:**
    ```bash
    gh issue edit <N> --repo $PIPELINE_REPO --add-label "pr-open" --remove-label "in-progress"
    ```

11. **Report:** "PR opened for #N: <PR URL>"

12. **Terminal state — STOP (Step 12).** Once Step 10 has applied the `pr-open` label and Step 11 has emitted the report line, the executor's work is DONE: the PR is confirmed open and all commits are pushed. This is the agent's terminal state — STOP here. Do NOT run any post-PR self-verification, "confirm PR opened" re-check, cleanup, or wait/poll loop: once the `pr-open` label is applied and the PR is confirmed open, the worktree handoff to `evaluate-issue-pr` is the orchestrator's job, and any lingering session holds the worktree + a concurrency slot and BLOCKS PR evaluation (a second `claude` session cannot safely run in the same worktree — issue #631). There is nothing left to wait for; emit the report line and end the session. (CI-fix mode (Step 0b) has its own terminal contract — report the new commit SHA and stop — and never reaches Step 10/11, so it is unaffected.)

## Handling evaluation feedback

If `evaluate-issue-pr` flags the PR while the executor session is still active, invoke `superpowers:receiving-code-review` with the evaluation comment as context: `Skill(skill: "superpowers:receiving-code-review")`.

## Constraints
- Implement ONLY what the approved plan says.
- Never commit to main.
- All PRs target `PIPELINE_BASE_BRANCH` (the configured base), never `main`. Always pass `--base "$PIPELINE_BASE_BRANCH"` (quoted) to `gh pr create`.
- Never use `--no-verify` or `--force`.
- Never skip build verification (`PIPELINE_TEST_CMD` from the sourced config).
- Verification (Step 6b) is a single sequential `$PIPELINE_TEST_CMD` pass wrapped with `</dev/null` + `timeout`; never improvise an unbounded `for t in tests/test*.sh` sweep over unrelated tests, and never launch concurrent full-suite runs (concurrent self-colliding suite runs report spurious failures — issue #677).
- Never inline unbounded sentinel-file polls (e.g. `until grep -q TOKEN file; do sleep N; done`). Use `scripts/wait-for-sentinel.sh <file> <token> [--timeout N]` (default 600s) — on timeout it exits non-zero with an actionable error so the Bash tool surfaces failure instead of wedging. The `check-unbounded-sentinel-polls` lint enforces this in CI.
- Executor does NOT merge PRs. All merging is handled by the pipeline orchestrator.
- Terminal after `pr-open`: once the `pr-open` label is applied and the PR is confirmed open, STOP. Never run a post-`pr-open` self-verification, "confirm PR opened" re-check, or wait/poll loop — a lingering executor holds the worktree + concurrency slot and blocks `evaluate-issue-pr` (issue #631).
