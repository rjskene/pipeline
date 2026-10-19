# Architecture — dispatch, waves, transport

Internal mechanism notes.

**When to read:** touching dispatch code, the full-send wave planner, or the transports.

**Transports:**
- inline `Agent()` — default; PATH A/B/C/D.
- `spawn-claude.sh` → `claude -p` — PATH C under `--spawn` (legacy escape hatch).

## Dispatch model (hybrid)

Dispatch is keyed off the path label written by the classification procedure (inline in `/pipeline:plan-issue` since #1485; `/pipeline:classify-issue` is the standalone form). Inline `Agent()` in the orchestrator session is the default for ALL paths (A/B/C/D); `spawn-claude.sh` is the `--spawn` opt-in (PATH C only).

```
path        transport                         subagent           notes
----        ---------                         --------           -----
A docs-only inline Agent()                    stage-executor     worktree by setup-worktree.sh; launch inline
B standard  inline Agent() (#748)             stage-executor     TDD via plan Task 0 bookend; separate exec/PR-eval contexts
C multi     inline Agent() (#1486)            stage-executor     one execute agent as on B; PIPELINE_PATH_C_FANOUT=true -> tdd-implementer per target=<dir> leaf, per-leaf worktree + cherry-pick reassemble (#896); --spawn -> spawn-claude.sh run-queue
D quick-fix inline Agent()                    tdd-implementer    skips eval-issue-plan + Step 8 pre-PR review (opt-in on every path since #1482); PR-eval is sole gate
precedence: A > D > C > B  (when path labels collide)
PR-eval on every path (and plan / plan-eval): stage-reader (#1530); stage types carry no Skill tool, the prompt's absolute SKILL.md path is Read (#1534)
```

- **PATH A** (`docs-only`) — execute-issue-plan + evaluate-issue-pr run inline via `Agent(subagent_type='pipeline:stage-executor', ...)` / `Agent(subagent_type='pipeline:stage-reader', ...)` (#1530). No `spawn-claude.sh` / `claude -p` / tmux. Worktree still created by `setup-worktree.sh`; only the launch is inline. Routing in `skills/status/SKILL.md` Step 6 + Step 7.
- **PATH B** (`standard`) — as of #748, execute-issue-plan + evaluate-issue-pr also run inline via `Agent(pipeline:stage-executor)` / `Agent(pipeline:stage-reader)`, exactly like A — no spawned `claude -p` worker, no tmux. Worktree still by `setup-worktree.sh`.
  - Red→green discipline comes from the plan's Task 0 inline TDD bookend inside execute-issue-plan, identical to a spawned B worker. Transport flip changes only the launch — TDD discipline unchanged.
  - The flip eliminated the `claude -p` stream stall (boots, ~13s CPU, frozen log, 0 commits, `Sl+`) and the inverted cache_read:cache_creation ratio it caused.
  - Inline B execute Agent and inline B PR-eval Agent stay SEPARATE inline contexts (evaluator independence).
- **PATH C** (`multi-task`) — as of #1486, execute-issue-plan runs as **one inline execute agent by default**, exactly like B (`Agent(pipeline:stage-executor)`; the plan's `target=<dir>` tasks run sequentially under red→green→commit in one context). The per-leaf fan-out shipped in #749/#891/#896 sits behind `PIPELINE_PATH_C_FANOUT=true`: the orchestrator reads the plan and dispatches one orchestrator-owned `Agent(subagent_type=pipeline:tdd-implementer, ...)` per `target=<dir>` leaf, each in its OWN per-leaf worktree (`scripts/path-c-split-worktree.sh` setup/reassemble/teardown) so concurrent leaves never share a git index, then reassembles each leaf's commits onto the feature branch by **cherry-pick** (disjoint targets ⇒ conflict-free, #896). `--spawn` (#750) reverts C to the legacy `scripts/spawn-claude.sh` (→ `claude -p`) run-queue/tmux transport (per-worker isolation, no split-worktree step; the spawned session honors the knob) — the reversible escape hatch.
- **PATH D** (`quick-fix`) — execute-issue-plan runs inline via `Agent(subagent_type=pipeline:tdd-implementer, ...)` — like A/B but subagent is `tdd-implementer` (leaf executor, strict red→green→commit) not stage-executor.
  - evaluate-issue-pr auto-routes by PATH letter: inline for A/B/C/D by default; spawn-claude for C under `--spawn`.
  - D ALSO skips evaluate-issue-plan entirely (orchestrator auto-flips `plan-pending` → `plan-approved` on a `quick-fix`+`plan-pending` issue in Step 4) and skips Step 8 (pre-PR review loop) of execute-issue-plan unconditionally — since #1482 Step 8 is opt-in on A/B/C as well (`PIPELINE_PRE_PR_REVIEW=true`; default `false`).
  - Bet: evaluate-issue-pr is sufficient review at quick-fix scope.
- **Other stages** (plan-issue — which runs classification inline since #1485 — evaluate-issue-plan, create-issues, and the standalone `/pipeline:classify-issue`) already invoked inline as `Agent(...)` regardless of path; nothing changes.

**PATH C inline migration (#80 → shipped #749/#891/#896).** Originally deferred over risks at C scope:
- subagent context budget
- turn budget
- permission inheritance
- TDD discipline drift
- crash recovery

As of #748 those risks were accepted at A and B scope. As of #749/#891/#896 they are accepted at C scope too: the per-leaf-worktree fan-out (#896) gives each `target=<dir>` leaf an isolated git index, so concurrency is bounded by orchestrator context (max-3 foreground), not a git-index cap, and leaf returns are ~one line each (negligible context cost — the #894/#896 live branch test). `--spawn` remains the reversible escape hatch back to the legacy spawned transport. As of #1486 the fan-out is opt-in (`PIPELINE_PATH_C_FANOUT=true`); the default C execute is one inline agent, as on B.

## Worktree isolation

Every path executes in its own git worktree — the main orchestrator workspace stays clean (Design Principle 4: *isolation by default*). One feature worktree is created per issue by `scripts/setup-worktree.sh` (the launch transport differs by path, but worktree creation is identical across A/B/C/D — see the dispatch table above).

```
orchestrator workspace (base branch)  --- stays clean, never edited by executors
       |
       +-- setup-worktree.sh <branch> [issue] --> feature/<slug> worktree (one per issue)
                |
                +-- PATH C, PIPELINE_PATH_C_FANOUT=true only: path-c-split-worktree.sh --> per-leaf worktrees
                        (one per target=<dir>; isolated git index; cherry-pick reassemble)
```

- `scripts/setup-worktree.sh` does the atomic per-issue worktree setup (`--base <branch>` selects the base; defaults to `$PIPELINE_BASE_BRANCH`). Worktrees live under `.claude/worktrees/` (runtime allow-list, consumer-owned).
- PATH C under `PIPELINE_PATH_C_FANOUT=true` additionally splits each `target=<dir>` leaf into its OWN per-leaf worktree via `scripts/path-c-split-worktree.sh`, so concurrent leaves never share a git index; leaf commits are cherry-picked back onto the feature branch (disjoint targets ⇒ conflict-free, #896).
- The orchestrator session itself never edits implementation files — with the fan-out on, `hooks/enforce-path-c-delegation.py` blocks orchestrator-side Edit/Write on impl files during PATH C dispatch; with it off (the default) the hook is a no-op, because the single execute agent edits impl files itself (#1486).

## Hotfix lane (in-session emergency)

`/pipeline:hotfix` is the **emergency lane**: an in-session worktree fix that bypasses ALL pipeline lifecycle gates. Distinct from PATH D — D is still a normal lifecycle issue (classified, executed, PR-evaluated); hotfix skips the lifecycle entirely and the operator observes the test/fix loop live, merging by hand. Authoritative spec: [skills/hotfix/SKILL.md](../skills/hotfix/SKILL.md).

```
parse args -> file/lookup audit-anchor issue -> setup-worktree.sh -> fix loop (red->green->commit, in-session) -> open PR -> manual merge
```

- **Runs in the current orchestrator session** (not a spawned/dispatched agent by default; `--inline`/`--subagent` selects the fix dispatch). The user watches the red→green loop live.
- **No evaluator gates.** No classify-issue, plan-issue, evaluate-issue-plan, evaluate-issue-pr, or fullsend dispatch — and no pipeline labels (no `plan-pending`/`in-progress`/`pr-open`), so the PR is invisible to the auto-merge gate by design.
- **Auto-merge: manual by default, opt-in CI-only.** With no flag the user merges by hand. With `--auto-merge`, Step 6.5 runs `scripts/auto-merge-gate.sh` in `NO_VERDICT=1` mode (CI-only greenlight — CI rollup SUCCESS + `mergeable == MERGEABLE` + `mergeStateStatus == CLEAN` + base `== $PIPELINE_BASE_BRANCH`, skipping the evaluator-verdict condition the emergency lane never produces). Never the default.
- Files an audit-anchor issue (or uses an existing one) so the bypass is recorded; the PR body notes it was filed via the emergency lane.

## Full Send wave model

On `/pipeline:fullsend`, the orchestrator runs `scripts/plan-waves.sh` against ready issues before dispatching any plan agents (classification runs inside plan-issue).

```
ready issues --> plan-waves.sh --> [ P0 > P1 > P2 > P3 tiers ]
                                     |
                                     v
      ordered waves (respect: blocked-by/depends-on #N, shared-file conflicts)
                                     |
                                     v
      wave N dispatched in PARALLEL --> wait --> wave N+1
disable: PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false (legacy single-blast)
```

- Groups issues into ordered waves by priority tier (`priority/P0` > `P1` > `P2` > `P3`).
- Respects explicit `blocked by #N` / `depends on #N` body annotations + shared-file conflicts inferred from issue bodies.
- Each wave dispatched in parallel; subsequent waves wait for the prior wave to finish.
- Disable with `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false` → legacy single-blast dispatch.

## Base-branch enforcement

Defense-in-depth across three layers:

```
layer 1: eval-time   auto-merge-gate.sh  baseRefName==$PIPELINE_BASE_BRANCH + TOCTOU re-check pre-merge (#295)
layer 2: skill       execute-issue-plan Step 9b  --base "$PIPELINE_BASE_BRANCH" at PR create
layer 3: hook        enforce-base-branch.py PreToolUse  (gh pr create + gh pr edit --base)
```

1. **Eval-time** — `baseRefName == $PIPELINE_BASE_BRANCH` assertion in `auto-merge-gate.sh` with a TOCTOU re-check immediately before `gh pr merge` (load-bearing zero-data-loss gate, #295).
2. **Skill-level** — quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b at PR creation.
3. **Hook** — `enforce-base-branch.py` PreToolUse, covering both `gh pr create` and `gh pr edit --base` retargets.

**Hook alone insufficient (#295 bypass cases):**
- consumer `settings.json` layout shadowed the plugin-registered matcher; or
- a stale rendered `spawn-claude.sh` emitted an unnamespaced slash command that never loaded plugin hooks at all.

## Spawn-claude degradation behavior

`spawn-claude.sh` is intentionally fail-soft when external inputs are unreliable:

- **`gh issue view` fails** (offline/auth) → logs `[spawn-claude] WARN: gh issue view failed ...` to stderr, falls back to standard (PATH B) skill behavior (proceeds without label-derived special-casing). Session still launches.
  - Note: this is `spawn-claude.sh`'s own internal default — it does NOT imply PATH B's normal dispatch is spawned. Post-#748 B's normal execute/PR-eval runs inline; `spawn-claude.sh` only runs for C — though a manual/explicit spawn can target a B issue.
- **Skill args file configured but missing on disk** → logs `WARNING: args file not found for <skill>: <path>` to stderr, emits the `Skill()` line WITHOUT an `args=` field. Skill still fires; just runs without its project-specific directive. Fix the typo / restore the file to clear the warning.

## MCP gating for spawned agents

- Orchestrator session (running `/pipeline:status` or `/pipeline:fullsend`) auto-loads repo-root `.mcp.json` (Playwright MCP) from its working directory — unaffected by this gating.
- Per-issue spawned agents (planner/executor/evaluator via `scripts/spawn-claude.sh`) default to ZERO MCP servers:
  - synthesises a transient `/tmp/claude-mcp-empty-*.json` = `{"mcpServers": {}}`, passes `--mcp-config <file> --strict-mcp-config` to the spawned `claude` CLI.
  - `--strict-mcp-config` is essential — without it `claude` can still discover user-/system-level MCP servers, defeating the gate.
  - tempfile unlinked by the deferred-cleanup trap (alongside system-prompt file + launcher).
- Spawned agents always get zero MCP servers (no label opt-in) — so the browser directive in execute/pr-eval is unavailable to `--spawn` agents; UI issues should run on the inline default.
