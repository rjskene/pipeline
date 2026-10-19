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
_cpr_dir="${_cpr_dir:-$([ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = true ] && git rev-parse --show-toplevel 2>/dev/null | sed 's|$|/|')}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

State (slate, base branch, repo) is inherited from `/pipeline:fullsend`; if these variables fail to resolve, **STOP** — preconditions live in `skills/fullsend/SKILL.md`.

## Lifecycle

```
worktree spawn → inline Agent (PATH A/B, PATH C default, PATH D tdd) | inline orchestrator-owned Agent(tdd-implementer) fan-out (PATH C, `PIPELINE_PATH_C_FANOUT=true`) → push → PR
```

## Invocation mode

Steps are identical across modes; only the CWD setup differs:

| # | Mode | CWD setup | Used by |
|---|------|-----------|---------|
| 1 | Inline `Agent(...)` dispatch | `cd <worktree-absolute-path>` (prompt provides it) | PATH A (docs-only), PATH B (standard), PATH C (PIPELINE_PATH_C_FANOUT off, default) |
| 2 | Orchestrator-owned `Agent(tdd-implementer)` fan-out under `PIPELINE_PATH_C_FANOUT=true` (`spawn-claude.sh` transport only under `fullsend --spawn`) | each leaf `cd`s into its OWN per-leaf worktree; the orchestrator reassembles via cherry-pick | PATH C (multi-task, `PIPELINE_PATH_C_FANOUT=true`) |
| 3 | PATH D inline tdd-implementer | `cd <worktree-absolute-path>` (same as mode 1) | PATH D (quick-fix) |

### Collapsed inline D contract

Read [references/collapsed-inline-d.md](references/collapsed-inline-d.md) when the issue carries `quick-fix` (PATH D, mode 3): the consume-or-produce classify+plan contract, the two checkpoints, and the escalation backstop.

# Execution Agent

Argument: the issue number. CWD: the feature worktree (table above).

## Steps

**0b. CI-fix mode.** If `$PIPELINE_CI_FIX_CONTEXT` is non-empty you were dispatched to fix a red CI run on an existing PR, not to implement a new plan — read [references/ci-fix-mode.md](references/ci-fix-mode.md) for the contract.

1. **Fetch the approved plan (trust-gated)** — the ONLY plan source is the latest **trusted-authored** (`OWNER` / `MEMBER` / `COLLABORATOR`) `## Implementation Plan` comment; other authors are dropped before selection, so trust dominates recency. **PATH D:** skip this fetch ONLY when the collapsed agent produced the plan in-context (see the Collapsed inline D contract); otherwise consume the upstream plan here.

   The helper (trust via `filter-trusted-comments.sh --json`; never widen the tier set inline) prints the plan, `PLAN-AMENDMENTS` plus the evaluation on a `Revise` verdict, and the files in `.claude/scratch/issue-<N>/` (attachments the planner saw):

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-issue-plan-fetch-plan.sh" <N>
   ```

   On exit 1 (no trusted plan), **STOP** and report its `No implementation plan found` line.

   **Plan amendments:** on `**Verdict:** Revise` the evaluation's `**Recommendations:**` are BINDING amendments; on conflict the recommendation WINS. Append `PLAN-AMENDMENTS: <k>` to Step 11's report line, `k` = recommendations APPLIED. `Approve`, or no evaluation, changes nothing.

   **For each file the helper lists, invoke the `Read` tool exactly once before implementing.**

2. **Read project conventions:** Read `CLAUDE.md` in the worktree root.

3. **Dependency check — issue #5 only:** verify `feature/schema-cleanup` merged; if absent, **STOP** (blocked).
   ```bash
   gh pr list --repo $PIPELINE_REPO --state merged --json headRefName --jq '[.[].headRefName]'
   ```

4. **Mark as in-progress:**
   ```bash
   gh issue edit <N> --repo $PIPELINE_REPO --add-label "in-progress" --remove-label "plan-approved"
   ```

5. **Implement the approved plan.** Follow the plan's `**Tasks (ordered):**` exactly; Task 0 carries the path directive.

   **PATH B single execute agent.** One `pipeline:stage-executor` agent applies the `tdd-implementer` discipline inline per plan task: failing test → `$PIPELINE_TEST_CMD` red → minimum impl → green → commit; it may edit any test the plan names under `**Test changes:**`; runs the FULL suite green before `gh pr create`.

   **Turn discipline.** (1) Send a task's independent edits (test + impl) as parallel calls in ONE message. (2) Inside RED/GREEN run only the targeted test file (`bash tests/<file>.sh </dev/null`), never the suite; the suite runs at 6b or when a GREEN breaks another file. (3) GREEN and commit share one Bash call, the `&& git commit` form, anchored: `timeout 600 bash <wt>/tests/<file>.sh </dev/null && git -C <wt> add <paths> && git -C <wt> commit -m "…"`. (4) Batch one-line reads into one Bash call.

   **PATH C (`multi-task`) — fan-out knob.** Branch on the prompt's `PATH_C_FANOUT=` token (no token: `${PIPELINE_PATH_C_FANOUT:-false}`; `true`/`on` ⇒ on, else off). **`off` (DEFAULT):** you are the single execute agent, exactly as PATH B — run the tasks in sequence here, one task per `target=<dir>`; no `tdd-implementer` leaves, no `path-c-split-worktree.sh`; you own Steps 8–10. `--spawn` changes only the transport.

   **`PIPELINE_PATH_C_FANOUT=true` — orchestrator-owned fan-out with per-leaf worktrees.** The orchestrator dispatches one `Agent(subagent_type='pipeline:tdd-implementer', ...)` leaf per `target=<dir>`, each in its own per-leaf worktree, and owns Steps 8–10; it MUST NOT `Edit`/`Write` impl files (`enforce-path-c-delegation` blocks it). Read [references/path-c-per-leaf-worktrees.md](references/path-c-per-leaf-worktrees.md) before dispatching.

   On PATH D (`quick-fix`) you ARE tdd-implementer: one inline red→green→commit pass, no subagent, no other skill; PATH D skips only Step 8. If the change exceeds D's envelope, escalate per the Collapsed inline D contract.

   Leave `PIPELINE_PATH_<X>_REVIEWER_EXECUTE` unset: Step 8 owns review.

   A test committing in a temp git repo must stamp an identity (`git_init_sandbox`, `tests/_lib/git-sandbox.sh`).

   Implement ONLY what the plan specifies; never commit to main; never use `--no-verify` or `--force`. Never put a bracketed CI-skip marker (`skip ci`, `no ci`, …) literally into a commit message, PR title or body; write `` `skip ci` `` (hook-enforced).

6. **Validate — types, tests, server, and UI.** 6a and 6b run as ONE chain (fence under 6b).

   **6a. Type check** — `$PIPELINE_TYPECHECK_CMD` (first link).

   **6b. Run tests (single sequential pass, stdin-guarded).** Run the configured `$PIPELINE_TEST_CMD` — the targeted/relevant test command for this project. Do NOT improvise an unbounded `for t in tests/test*.sh; do bash "$t"; done` sweep. Always redirect stdin from `/dev/null` and bound each run with `timeout`:
   ```bash
   $PIPELINE_TYPECHECK_CMD \
     && timeout 600 bash -c "$PIPELINE_TEST_CMD" </dev/null
   ```
   ONE verification pass at a time — never concurrent suite runs. The issue's targeted test must already be green; never commit past a red targeted test.
   **Run the suite in the foreground and read its exit code directly.** Never background a test monitor and `Read` its `/tmp/...` output, and never narrate "I'll wait" and stop: the suite is done when the Bash call returns. **Monitor-yield ban:** never yield on a background `Monitor`; if async monitoring is unavoidable, block via a bounded `BashOutput` poll to a sentinel under `.claude/logs/` or `.claude/scratch/`, never `/tmp`. **Never `run_in_background` a test run.** Run `$PIPELINE_TEST_CMD` in the FOREGROUND; if the runner supports splitting, run its slices as sequential foreground calls, every slice green before `gh pr create`. **Dogfood split (this repo only):** `$PIPELINE_TEST_CMD` is `bash scripts/run-test-suite.sh`. When base CI is green, run ONE foreground call — `bash scripts/run-test-suite.sh --changed-only "$PWD/tests"` (touched + subject tests) — and read `RESULT=` from its `CHANGED-ONLY:` summary line; it must report `RESULT=pass`. ONLY when base CI is red, or that call prints `CHANGED-ONLY: base … unresolved`, run `--chunk 1/4` … `--chunk 4/4`, one foreground call each; every chunk must report `RESULT=pass` (or fail only on `PRE-EXISTING:` files). Chunk it instead of backgrounding it. **CI is the oracle for untouched failures:** a failing file the diff leaves untouched (`git diff --name-only origin/<base>...HEAD` names neither it nor its subject script) while base CI is green is skipped with ONE line `PRE-EXISTING: <file> (untouched; base CI green)`. **Subject:** a test that reads, greps, sources or execs a touched path by path, basename, or containing glob/directory (`hooks/*.py`); check: `grep -rlF -e <basename> -e <dir>/ tests/` per touched path. A failing subject test is never `PRE-EXISTING:`; make it green locally. The PR body carries every `PRE-EXISTING:` line under `## Pre-existing failures`, or `PRE-EXISTING: none`.
   **6c. Browser check.** If the diff changes anything a user sees in a browser, start the app on a free port, open it with the Playwright MCP tools, screenshot the affected views, check the console for errors, fix what you find, attach the screenshot to the PR, and stop the server.

   **Cross-cutting guards always run:** even when 6b verified only a subset, `scripts/check-cross-cutting-guards.sh` runs pre-PR (Step 9a).

7. **Self-review checkpoint before opening PR.** Every plan item implemented; `git diff --stat` shows no unintended files; no debug leftovers (`console.log`, `print(`, `TODO`, `FIXME`); no scope creep.

8. **Pre-PR code review loop.** Read [references/pre-pr-review-loop.md](references/pre-pr-review-loop.md) before `gh pr create` on PATH A/B/C (8a–8e). Skip Step 8 in its entirety and go to Step 9 on PATH D (`quick-fix`), or when your dispatch prompt carries `PRE_PR_REVIEW=off` (no dispatch prompt: `${PIPELINE_PRE_PR_REVIEW:-false}` is `false`) — then emit `PRE-PR-REVIEW: skipped reason=knob` as assistant text, not `echo`.

   **Step 8 owner — the role that opens the PR:** the inline execute `Agent`, or under `PIPELINE_PATH_C_FANOUT=true` the orchestrator (after `path-c-split-worktree.sh reassemble`). A `tdd-implementer` leaf NEVER runs Step 8: it refuses with `CAPABILITY-REFUSED:`.

9. **Open a pull request.**

   **9a. Derive the title and run the guards.** One call from inside the worktree: `scripts/derive-pr-title.sh` yields a Conventional-Commits title (its rule table is the source of truth; `exit 2` = tracker (epic title), never a PR), then ONE `check-cross-cutting-guards.sh` call runs `scripts/check-branch-cruft.sh`, `scripts/check-config-drift.sh` and the namespace / golden-seed / README-anchor invariants. Any ABORT line (including an INERT cruft arm) stops the open; add no standalone guard fences. Success ends with `PR_TITLE=<title>`:

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT}/scripts/execute-issue-plan-pre-pr.sh" <N>
   ```

   **9b. Open the PR.** Quote `--base` and guard an unset base: even when `enforce-base-branch.py` is absent, `auto-merge-gate.sh` (`skills/fullsend/references/auto-merge-gate.md`) needs a real base. Pass the 9a title literally:

   ```bash
   if [ -z "$PIPELINE_BASE_BRANCH" ]; then echo "FATAL: PIPELINE_BASE_BRANCH unset; refusing to call gh pr create" >&2; exit 1; else \
     gh pr create \
       --repo "$PIPELINE_REPO" \
       --title "<PR_TITLE from 9a>" \
       --base "$PIPELINE_BASE_BRANCH" \
       --body "$(cat <<'EOF'
   Closes #<N>

   ## Summary
   <bullet points summarising what changed>

   ## Test plan
   - [ ] `PIPELINE_TEST_CMD` — all tests pass
   - [ ] Feature works end to end

   ## Pre-existing failures
   PRE-EXISTING: none
   EOF
   )"; fi
   ```

   `PR_TITLE` is normalized by `scripts/derive-pr-title.sh` (any `../` becomes `..⁄`, U+2044). Both `--title` and `--body` are also scanned by the `check-ci-skip-markers` hook; to *describe* a marker, wrap it in backticks.

10. **Mark as pr-open:**
    ```bash
    gh issue edit <N> --repo $PIPELINE_REPO --add-label "pr-open" --remove-label "in-progress"
    ```

11. **Report:** "PR opened for #N: <PR URL>"

12. **Terminal state — STOP (Step 12).** After Steps 10–11 this is the agent's terminal state — STOP here: once the `pr-open` label is applied, run no re-check, cleanup, or wait/poll loop: a lingering session blocks `evaluate-issue-pr`.

## Handling evaluation feedback

- If `evaluate-issue-pr` flags the PR while you are still active, verify each claim against the code, fix what is right, push back with evidence on the rest.

## Constraints
- Implement ONLY what the approved plan says.
- Stage ONLY the explicit plan-related paths with `git add <path> [<path>...]`. NEVER `git add -A`, `git add .`, or `git add -u` (they sweep in cruft; `scripts/check-branch-cruft.sh` backstops).
- **Git-anchoring + branch-assert.** Anchor every git command `git -C <worktree-abs-path>` (cwd does not persist). Before ANY commit, ASSERT `git -C <worktree-abs-path> symbolic-ref --short HEAD` equals the feature branch; if not, **STOP and report**. Every `git add` is `git -C <worktree-abs-path> add <paths>` — never a bare `git add`, never `git -C <main-repo> add`.
- **No hypothesised concurrent writer.** If your changes turn up somewhere you did not expect (main checkout, another branch or worktree, or reset), report the OBSERVED facts and STOP: `git -C <dir> status --short`, `git -C <dir> log --oneline -5`, and the exact git commands you ran. Never blame a concurrent writer you have not directly observed; the likely cause is your own unanchored `git` command.
- Never commit to main; never `--no-verify` or `--force`.
- All PRs target `PIPELINE_BASE_BRANCH`, never `main`: always `--base "$PIPELINE_BASE_BRANCH"` (quoted).
- Verification (Step 6b) is a single sequential `$PIPELINE_TEST_CMD` pass with `</dev/null` + `timeout`; never an unbounded `for t in tests/test*.sh` sweep, never concurrent suite runs.
- Never inline unbounded sentinel-file polls; use `scripts/wait-for-sentinel.sh <file> <token> [--timeout N]`.
- The executor never merges PRs.
- Terminal after `pr-open`: STOP — never a post-`pr-open` re-verify, wait or poll loop.
