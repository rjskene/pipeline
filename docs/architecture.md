# Architecture — dispatch, waves, spawn-claude

Internal mechanism notes. Read this when touching dispatch code, the full-send wave planner, or `spawn-claude.sh`.

## Dispatch model (hybrid)

Pipeline stages dispatch in one of two ways, keyed off the path label written by `/pipeline:classify-issue`:

- **PATH A** (`docs-only`) — execute-issue-plan and evaluate-issue-pr run inline via `Agent(subagent_type='general-purpose', ...)` from the orchestrator session. No `spawn-claude.sh`, no `claude -p`, no tmux. The worktree is still created by `setup-worktree.sh`; only the agent launch is inline. Routing logic lives in `skills/run/SKILL.md` Step 6 and Step 7.
- **PATH B / PATH C** — execute-issue-plan and evaluate-issue-pr continue to dispatch through `scripts/spawn-claude.sh` (which invokes `claude -p`) and, for multi-issue runs, `scripts/run-queue.sh` + tmux. PATH B uses spawn-claude.sh; PATH C uses spawn-claude.sh. This is unchanged from the previous behavior and remains the indefinite default for B/C until external pressure (deprecation or quota signals on `-p`) forces broader migration.
- **Other stages** (classify-issue, plan-issue, evaluate-issue-plan, create-issues) are already invoked inline as `Agent(...)` from the orchestrator regardless of path; nothing changes for them.

Broader PATH B/C inline migration is intentionally deferred (see issue #80 rationale: subagent context budget, turn budget, permission inheritance, TDD discipline drift, and crash recovery risks are accepted at PATH A scope but not at B/C scope).

## Full Send wave model

When the user invokes `/pipeline:fullsend` (or the back-compat `"full send"` magic-string in `/pipeline:run`, which delegates to the same skill), the orchestrator runs `scripts/plan-waves.sh` against the set of ready issues before dispatching any classify/plan agents. The helper groups issues into ordered waves by priority tier (`priority/P0` > `P1` > `P2` > `P3`), respecting explicit `blocked by #N` / `depends on #N` body annotations and shared-file conflicts inferred from issue bodies. Each wave is dispatched in parallel; subsequent waves wait for the prior wave to finish. Disable with `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false` to restore the legacy single-blast dispatch.

## Base-branch enforcement

Defense-in-depth across three layers:

1. Eval-time `baseRefName == $PIPELINE_BASE_BRANCH` assertion in `auto-merge-gate.sh` with a TOCTOU re-check immediately before `gh pr merge` (load-bearing zero-data-loss gate, #295).
2. Skill-level quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b at PR creation time.
3. `enforce-base-branch.py` PreToolUse hook covering both `gh pr create` and `gh pr edit --base` retargets.

The hook alone is not sufficient — it has bypassed (#295) when the consumer settings.json layout shadowed the plugin-registered matcher, or when a stale rendered spawn-claude.sh emitted an unnamespaced slash command that never loaded plugin hooks at all (see `dev/audits/295-root-cause.md`).

## Spawn-claude degradation behavior

`spawn-claude.sh` is intentionally fail-soft when external inputs are unreliable:

- **`gh issue view` fails** (offline/auth): logs `[spawn-claude] WARN: gh issue view failed ...` to stderr and falls back to **PATH B** (the standard path). The session still launches.
- **Skill args file configured but missing on disk**: logs `WARNING: args file not found for <skill>: <path>` to stderr and emits the `Skill()` line **without** an `args=` field. The skill still fires; it just runs without its project-specific directive. Fix the typo or restore the file to remove the warning.

There is one **fail-closed** counterpart: when `PIPELINE_EVAL_CLASSIFIER` is set AND the skill is `evaluate-issue-pr` AND `--container-mode=<name>` was NOT passed, spawn-claude re-invokes the classifier inline. If the classifier would emit a `--container-mode=<name>` token, spawn-claude exits **5** with actionable stderr instead of silently launching a bare-host evaluator — fixing the race where a stale consumer copy of the script pre-empts container dispatch (#238). Fail-open when the classifier is unset, `mock-web-eval/scripts/eval-classifier-invoke.sh` is missing, or the classifier exits non-zero / emits nothing.

When `--container-mode=<name>` IS passed, spawn-claude forwards `PIPELINE_PROJECT_ROOT=<repo-root>` and `PIPELINE_WORKTREE_PATH=<worktree-abs>` into `docker compose run -e` (#241). The compose file binds `${PIPELINE_PROJECT_ROOT}:${PIPELINE_PROJECT_ROOT}` (same-path) and pins `working_dir` to `${PIPELINE_WORKTREE_PATH:-${PIPELINE_PROJECT_ROOT}}`. Same-path binding is required because Claude Code's plugin discovery is keyed off the `projectPath` field in `~/.claude/plugins/installed_plugins.json` — slash commands resolve only when the container's `working_dir` lives under a registered project path. `mock-web-eval/scripts/mock-web-eval-probe-port.sh` also seeds both env vars into `mock-web-eval/target/.env.mock-web-eval` for operators who invoke `docker compose run` directly without going through `spawn-claude.sh`.
