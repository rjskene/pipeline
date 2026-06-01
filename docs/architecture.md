# Architecture — dispatch, waves, spawn-claude

Internal mechanism notes. Read this when touching dispatch code, the full-send wave planner, or `spawn-claude.sh`.

## Dispatch model (hybrid)

Pipeline stages dispatch in one of two ways, keyed off the path label written by `/pipeline:classify-issue`:

- **PATH A** (`docs-only`) — execute-issue-plan and evaluate-issue-pr run inline via `Agent(subagent_type='general-purpose', ...)` from the orchestrator session. No `spawn-claude.sh`, no `claude -p`, no tmux. The worktree is still created by `setup-worktree.sh`; only the agent launch is inline. Routing logic lives in `skills/run/SKILL.md` Step 6 and Step 7.
- **PATH B** (`standard`) — as of #748, execute-issue-plan and evaluate-issue-pr also run inline via `Agent(subagent_type='general-purpose', ...)` from the orchestrator session, exactly like PATH A — no spawned `claude -p` worker, no tmux. The worktree is still created by `setup-worktree.sh`; only the launch is inline. B's red→green discipline comes from the plan's Task 0 `superpowers:test-driven-development` bookend inside execute-issue-plan, identical to how a spawned B worker ran it — so the transport flip changes only the launch, eliminating the `claude -p` stream stall (boots, ~13s CPU, frozen log, 0 commits, `Sl+`) and the inverted cache_read:cache_creation ratio it caused, without changing the TDD discipline. The inline B execute Agent and inline B PR-eval Agent stay SEPARATE inline contexts (evaluator independence).
- **PATH C** (`multi-task`) — execute-issue-plan and evaluate-issue-pr continue to dispatch through `scripts/spawn-claude.sh` (which invokes `claude -p`) and, for multi-issue runs, `scripts/run-queue.sh` + tmux. This is unchanged from the previous behavior and remains the indefinite default for C until external pressure (deprecation or quota signals on `-p`) forces broader migration.
- **PATH D** (quick-fix) — execute-issue-plan runs inline via `Agent(subagent_type=tdd-implementer, ...)` from the orchestrator session — like PATH A/B, but the subagent type is `tdd-implementer` (leaf executor with strict red->green->commit) instead of general-purpose. evaluate-issue-pr stays unchanged (auto-routes by PATH letter, inline for A, B, and D, spawn-claude for C). PATH D ALSO skips evaluate-issue-plan entirely (the run orchestrator auto-flips `plan-pending` -> `plan-approved` when it observes a `quick-fix`+`plan-pending` issue in Step 4) and skips Step 8 (pre-PR review loop) of execute-issue-plan. The bet: evaluate-issue-pr is sufficient review at quick-fix scope. Routing precedence: A > D > C > B when multiple path labels collide.
- **Other stages** (classify-issue, plan-issue, evaluate-issue-plan, create-issues) are already invoked inline as `Agent(...)` from the orchestrator regardless of path; nothing changes for them.

Broader PATH C inline migration is intentionally deferred (see issue #80 rationale: subagent context budget, turn budget, permission inheritance, TDD discipline drift, and crash recovery risks). As of #748 those risks are accepted at PATH A and PATH B scope (B is single-context, so the budget/discipline concerns are bounded) but not yet at PATH C scope, where the multi-task `tdd-implementer` fan-out keeps the spawned transport.

## Full Send wave model

When the user invokes `/pipeline:fullsend` (or the back-compat `"full send"` magic-string in `/pipeline:run`, which delegates to the same skill), the orchestrator runs `scripts/plan-waves.sh` against the set of ready issues before dispatching any classify/plan agents. The helper groups issues into ordered waves by priority tier (`priority/P0` > `P1` > `P2` > `P3`), respecting explicit `blocked by #N` / `depends on #N` body annotations and shared-file conflicts inferred from issue bodies. Each wave is dispatched in parallel; subsequent waves wait for the prior wave to finish. Disable with `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false` to restore the legacy single-blast dispatch.

## Base-branch enforcement

Defense-in-depth across three layers:

1. Eval-time `baseRefName == $PIPELINE_BASE_BRANCH` assertion in `auto-merge-gate.sh` with a TOCTOU re-check immediately before `gh pr merge` (load-bearing zero-data-loss gate, #295).
2. Skill-level quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b at PR creation time.
3. `enforce-base-branch.py` PreToolUse hook covering both `gh pr create` and `gh pr edit --base` retargets.

The hook alone is not sufficient — it has bypassed (#295) when the consumer settings.json layout shadowed the plugin-registered matcher, or when a stale rendered spawn-claude.sh emitted an unnamespaced slash command that never loaded plugin hooks at all.

## Spawn-claude degradation behavior

`spawn-claude.sh` is intentionally fail-soft when external inputs are unreliable:

- **`gh issue view` fails** (offline/auth): logs `[spawn-claude] WARN: gh issue view failed ...` to stderr and falls back to the **standard (PATH B) skill behavior** — i.e. it proceeds without label-derived special-casing. The session still launches. Note this is `spawn-claude.sh`'s own internal default and does not imply PATH B's normal dispatch is spawned: post-#748 PATH B's normal execute/PR-eval runs inline (above), and `spawn-claude.sh` only runs for PATH C — though a manual/explicit spawn can still target a PATH B issue.
- **Skill args file configured but missing on disk**: logs `WARNING: args file not found for <skill>: <path>` to stderr and emits the `Skill()` line **without** an `args=` field. The skill still fires; it just runs without its project-specific directive. Fix the typo or restore the file to remove the warning.

**Web-surface routing.** PRs labelled `needs-browser` route through inline `Agent(general-purpose)` dispatch with the visual-proof preflight described in `scripts/visual-proof-server-start.sh`; no separate classifier is consulted.

## MCP gating for spawned agents

The repo-root `.mcp.json` registers Playwright MCP. The orchestrator session (the one running `/pipeline:run` or `/pipeline:fullsend`) loads `.mcp.json` automatically from its working directory — unaffected by this gating.

Per-issue spawned agents (planner, executor, evaluator launched via `scripts/spawn-claude.sh`) default to **zero MCP servers**: the script synthesises a transient `/tmp/claude-mcp-empty-*.json` containing `{"mcpServers": {}}` and passes `--mcp-config <file> --strict-mcp-config` to the spawned `claude` CLI. The `--strict-mcp-config` flag is essential — without it `claude` can still discover MCP servers from user- or system-level config, defeating the gate. The tempfile is unlinked by the existing deferred-cleanup trap (alongside the system-prompt file and launcher).

Opt in to the project `.mcp.json` (the previous behaviour) by labelling the issue `needs-browser` — `spawn-claude.sh` inspects labels via `gh issue view --json labels` and skips the empty-config injection. Seed the label with `/pipeline:doctor --fix labels`. The gate is **fail-safe**: if `gh issue view` fails (offline/auth/rate-limit), `HAS_NEEDS_BROWSER` stays `0` and the agent defaults to no MCP rather than silently inheriting Playwright across every spawned agent in a wave. The same `needs-browser` label is the single source of truth shared with the visual-proof-from-plan sub-skill (#368).
