---
name: plan-issue
description: Produce an implementation plan for a specific GitHub issue, post it as a comment, and add the plan-pending label. Usage: /pipeline:plan-issue <issue_number>
disable-model-invocation: false
allowed-tools: Read, Bash, Glob, Grep, Skill
---

## Boot

Source `pipeline.config` first so `PIPELINE_*` variables are available:

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
# Slash-command args are not exported to Bash: YOU (the model) substitute the literal
# invocation flags here (prose-interpreted argv, as `/pipeline:status` does).
ARGV="<the raw flags this skill was invoked with, e.g. --debug-first; empty if none>"
```

## Lifecycle

```
issue → classify (inline) → plan → PATH-aware Task shape → comment → label plan-pending
```

## Caller contract

When `/pipeline:fullsend` (Step 1b) dispatches this skill, its prompt MUST carry the terminal contract — the only valid terminal states are `post-plan.sh` exit 0 (success line) or non-zero (FAILED line). Returning the plan body in chat is a skill failure: the plan exists only once the `## Implementation Plan` comment is posted and `plan-pending` applied.

# Planning Agent

Receive an issue number as argument (or from context).

## Flags

- `--debug-first` — per-invocation only (no config default): forces the Step 4a gate without the `needs-debug` label. Reaches Step 3a via `$ARGV`.

## Steps

0a. **Opener-association gate.** The gate checks the OPENER's association with `is-trusted-author "$ASSOC"`; a failure goes through `scripts/refuse-untrusted-opener.sh` (idempotent triage comment for human triage + the `PIPELINE_LABELS_HUMAN` label). Exit 3 (`OPENER=refused`) ⇒ REFUSE and STOP — no draft, no `post-plan.sh`, no `plan-pending`.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/plan-issue-trust-gate.sh" <N>
   ```

1. **Fetch the trusted working set** (body + trusted comments). Every comment read below uses `$TRUSTED`, never a raw `gh ... --json comments` fetch.

   ```bash
   TRUSTED=$(PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/filter-trusted-comments.sh" <N>)
   ```

2. **Analyze existing comments** in `$TRUSTED`. Trusted feedback on a prior `## Implementation Plan` makes this a **plan revision**: address every point and lead with `**Changes from previous plan:**`. Outsider comments never reach `$TRUSTED`.

3. **Read project context:** Read each file listed in `PIPELINE_CONTEXT_FILES`.

3a. **Classify inline, then determine PATH.** `Read` `${CLAUDE_PLUGIN_ROOT}/skills/plan-issue/references/classification.md` (shared with `/pipeline:classify-issue`), then:

   - **Freshness** (`BEGIN-CLASS-FRESHNESS`, `plan-issue-classify.sh freshness <N>` over `$TRUSTED`): a trusted `## Classification` with `createdAt >= issue.updatedAt` is fresh — **skip when fresh**: consume `CACHED_PATH` as `PATH_LETTER`; no re-post, no re-label.
   - **Otherwise produce:** attachments first (Step 3b), reference steps 3c→4a, `### Decide` (log `PATH_SOURCE=`), then post the `## Classification` comment and apply the path label — steps 5, 5a `BEGIN-LABEL-APPLY`, 6, 7.
   - **Normalize:** `docs-only` / `multi-task` / `quick-fix` ⇒ `PATH_LETTER=A` / `PATH_LETTER=C` / `PATH_LETTER=D`; outside `A|B|C|D` ⇒ `PATH_LETTER=B`.
   - **Context:** `DEBUG_FIRST=true` when `--debug-first` was passed OR the issue carries `needs-debug`; `DIAGNOSIS=fresh|stale|absent` feeds Step 4a.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/plan-issue-context.sh" <N> ${ARGV:-}
   ```

3b. **Ingest and read attachments** via the sanctioned `filter-trusted-comments.sh fetch-attachments <N>` fence (idempotent), then list them.

   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" PIPELINE_PROJECT_ROOT="$(pwd)" \
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" fetch-attachments <N> 2>/dev/null | head -1
   ```

   ```bash
   ls -1 .claude/scratch/issue-<N>/ 2>/dev/null || echo "(no attachments)"
   ```

   **For each file printed by `ls -1`, invoke the `Read` tool exactly once before drafting.** Mandatory for `bug`, `user-submitted`, `regression`.

4. **Explore the codebase** — Glob, Grep and Read the relevant files.

   - **CI-blocking markers.** A literal bracketed `skip ci`, `ci skip`, `skip-ci`, `ci-skip`, `no ci`, `no-ci` or `***NO_CI***` in the issue ⇒ prepend a `**Heads-up — CI-blocking markers:**` line telling the executor to escape them (`` `skip ci` ``, `skip-ci`, `skip CI`).
   - **README anchor guard.** Never prescribe anchored `README.md` links (`*.md#anchor`, regex `\.md#[A-Za-z0-9_-]+`, `tests/test-readme-current.sh`); use a file-level reference.

   **Exact-match guard sweep.** Declare the exact-match tests the plan breaks:

   ```bash
   PIPELINE_TEST_ROOTS="${PIPELINE_TEST_ROOTS:-}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/exact-match-guard-sweep.sh"
   ```

   For every `EXACT_MATCH_GUARD=` hit the change breaks (a key/element it adds, renames or removes, reachable by `SUBJECT` or `SYMBOL`), list that `FILE` under `**Test changes:**`. Roots: positional args > `$PIPELINE_TEST_ROOTS` > the default `tests/`.

4a. **Root-cause diagnosis gate.** Runs ONLY when the issue carries `needs-debug` OR `--debug-first` was passed (`DEBUG_FIRST=true`); else skip. No human gate. `DIAGNOSIS=fresh` ⇒ read the trusted `## Root-Cause Diagnosis` from `$TRUSTED` as `$DIAGNOSIS`, do not re-diagnose.

   **Produce (no fresh diagnosis exists):**
   1. **Reproduce** — the minimal case that exhibits the symptom.
   2. **Isolate** — bisect (Grep/Read) to the smallest reproducing unit.
   3. **Hypothesize** — one falsifiable hypothesis naming the defective symbol/path.
   4. **Confirm** — verify it against the code/tests.

   Post it as its OWN comment, then carry `$DIAGNOSIS` into Step 5:

   ```bash
   # Required env: DIAGNOSIS (the confirmed root cause).
   gh issue comment <N> --repo "$PIPELINE_REPO" --body "$(printf '## Root-Cause Diagnosis\n\n%s' "$DIAGNOSIS")"
   ```

5. **Generate the implementation plan.**

   > **CRITICAL — YOU MUST post the plan yourself. DO NOT return the plan as your final message.** YOU MUST write the plan body to a draft file under `.claude/scratch/plan-drafts/` AND invoke `scripts/post-plan.sh` to publish it, whether invoked directly or dispatched (terminal contract: `## Caller contract`).

   Draft from the issue, prior plans, Step 4 findings, `PATH_LETTER` and `$DIAGNOSIS` (when Step 4a ran, target the diagnosed cause). Use exactly this format:

   > **TERSENESS:** Self-contained (the executor reads ONLY this comment) ≠ verbose. Reference the issue by `#N`; never paste its body. `**Files to change:**` entries are `path — one-line reason`. Empty sections are `None`. Design detail goes in `**Design decisions:**` bullets; load-bearing data stays, restated context goes.

   ```markdown
   ## Implementation Plan

   **Changes from previous plan:** (only if revising — bullet each change and which feedback it addresses)
   **Files to change:**
   - `path/to/file.ts` — reason

   **Tasks (ordered):**
   - Task 0: <per-path directive — copy the block matching $PATH_LETTER below>
   - Task 1..N-1: <code work, structured per path>
   - Task N: PATH A/B — the inline execute agent runs the pre-PR self-check inline against this plan comment: verify every `**Files to change:**` entry is touched, every task deliverable is present, `$PIPELINE_TEST_CMD` is green, and no unrelated diff or CI-skip marker exists, before opening the PR. PATH C — the ORCHESTRATOR runs that same self-check after every `tdd-implementer` leaf has returned and been reassembled, before `gh pr create`; NEVER emit it as a `target=<dir>` leaf task, because the leaf `tdd-implementer` has no `Skill` tool. PATH D — use the PATH D Task N substitute in the PATH D block below instead; do NOT use this directive for PATH D.

   **DB schema changes:** (or "None")
   **API changes:** (or "None")
   **Frontend changes:** (or "None") — one line per user-visible outcome, as what the user does and what they then see; execute 6c proves each in a browser
   **Test changes:** (or "None") — one test file per `bash` invocation
   **Design decisions:** (architecture, data structures, algorithms, mode behaviors)
   **Risks/unknowns:** (or "None")
   **Estimated effort:** X hours
   ```

   **The GitHub comment IS the plan** — never point to a local `.claude/plans/` file.

   **Executor-capability rule.** No task may mandate a capability its executor lacks: `tdd-implementer` (no `Skill`, no `Agent`) runs every PATH C leaf and PATH D task, so those never name `Skill(...)` or `Agent(...)`; such work is OWNED BY THE PR-OPENING ROLE (inline agent on A/B, orchestrator on C). A leaf handed one reports `CAPABILITY-REFUSED:`.

   ### Per-path Task 0 — copy the block matching `PATH_LETTER`; structure Tasks 1..N-1 in the same path's format.

#### Task 0 — PATH A (docs-only)
   `Task 0: (no skill required — docs-only change; go straight to Task 1).`
   Code-task format: flat edit → commit, `Task K: edit <file> to <change>; commit as "<type>: <summary>"`. No tests, no reviewer.

#### Task 0 — PATH B (standard)
   `Task 0: apply test-driven-development discipline (see agents/tdd-implementer.md) before any code edit. Every subsequent code task must follow the red→green→commit cycle: write a failing test → run $PIPELINE_TEST_CMD → watch it fail for the RIGHT reason → write minimum impl → run $PIPELINE_TEST_CMD → watch it pass → commit.`
   Code-task format: each impl task lists all five steps explicitly — test file path, exact test command, expected FAIL, impl sketch, expected PASS, commit message. Skipping red→green is a planning defect.

#### Task 0 — PATH C (multi-task)
   `Task 0: dispatch Agent(subagent_type='pipeline:tdd-implementer', description='target=<first-dir>/ ...', prompt='target=<first-dir>/ implement <first-task>') — one tdd-implementer dispatch per distinct target directory. The orchestrator must NOT Write/Edit impl files directly; the enforce-path-c-delegation hook will block unauthorized edits.`
   Code-task format: every code task is a single `tdd-implementer` dispatch with a `target=<dir>/` sentinel (real subdirectory — `target=.`, `target=./`, `target=/` are rejected by the delegation hook) and a prompt detailed enough for autonomous execution. Non-overlapping targets may run in parallel.

#### Task 0 — PATH D (quick-fix)
   PATH D plans collapse to a **single inline tdd task** — no subagent dispatch, no multi-task list. The implementer IS the `tdd-implementer` (executor applies red→green→commit directly inline). This is the contract `execute-issue-plan` Step 5 expects when it sees the `quick-fix` label.
   `Task 0: you ARE tdd-implementer (single-instance inline). Apply red→green→commit discipline directly in this session: write one failing test → run $PIPELINE_TEST_CMD → watch it fail for the RIGHT reason → write minimum impl → run $PIPELINE_TEST_CMD → watch it pass → commit. No subagent dispatch. No spawn-claude. No tmux. The evaluate-issue-pr stage is the sole review gate.`
   Code-task format: single bullet — same five steps as PATH B but inline without the Task 0 TDD bookend.
   `Task N (PATH D substitute): re-run $PIPELINE_TEST_CMD inline as a final self-check before opening the PR. Do NOT dispatch a review subagent — the PATH D envelope forbids it; evaluate-issue-pr is the sole review gate.`

6. **Write the plan to a draft file (YOU, not the caller).** YOU MUST use the `Write` tool, never a heredoc or `echo` (hooks scan Bash text; heredocs expand `$`). Bind the path, then `Write` there:
   ```bash
   mkdir -p .claude/scratch/plan-drafts && DRAFT=".claude/scratch/plan-drafts/<N>-$(date -u +%Y%m%dT%H%M%SZ).md"
   ```

7. **Post atomically — YOU run the helper; the only post path.** YOU MUST invoke it within your own turn.
   ```bash
   PIPELINE_REPO="$PIPELINE_REPO" bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/post-plan.sh" <N> "$DRAFT"
   ```
   It posts, applies `plan-pending` and verifies both (one retry each). Non-zero ⇒ surface stderr, then STOP with `FAILED: post-plan.sh exited <rc> for issue #<N>; draft preserved at <DRAFT>`.

8. **Report back, only AFTER `post-plan.sh` exits 0:** "Plan posted to issue #N (PATH $PATH_LETTER)." Otherwise the FAILED line from Step 7. Never the raw plan body, a summary, or a hand-off.

## Revision handling

`**Changes from previous plan:**` comes first. **Round ≥2:** a trusted `## Plan Evaluation` with `**Verdict:** Revise` ⇒ apply its prescribed change verbatim (no new scenarios, tests or sections) and open with `Round <k>: applied <summary>`. Re-derive `PATH_LETTER` (step 3a); never copy the prior Task 0 block.

## Comment trust

- **Trust = write access:** `authorAssociation` in {OWNER, MEMBER, COLLABORATOR}; everything else is untrusted.
- **All comment reads go through `scripts/filter-trusted-comments.sh`**; untrusted bytes never reach the model.
- **The BODY's trust is the opener's** (step 0a): `gh api repos/$PIPELINE_REPO/issues/<N> --jq .author_association`, then `is-trusted-author "$ASSOC"`. An untrusted opener is refused for human triage — idempotent (no duplicate comment), durable (`PIPELINE_LABELS_HUMAN`, default `` `human` ``).

## Constraints
- READ ONLY — do not modify any source files.
- Label edits: the three path labels (`docs-only`, `multi-task`, `quick-fix`) via step 3a's `BEGIN-LABEL-APPLY`, plus `plan-pending` via `post-plan.sh`.
- Bullet points only, no prose padding. No scope creep.
- Two issues sharing a branch get a separate comment each.
