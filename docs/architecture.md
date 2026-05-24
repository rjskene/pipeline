# Architecture — dispatch, waves, spawn-claude

Internal mechanism notes. Read this when touching dispatch code, the full-send wave planner, or `spawn-claude.sh`.

## Dispatch model (hybrid)

Pipeline stages dispatch in one of two ways, keyed off the path label written by `/pipeline:classify-issue`:

- **PATH A** (`docs-only`) — execute-issue-plan and evaluate-issue-pr run inline via `Agent(subagent_type='general-purpose', ...)` from the orchestrator session. No `spawn-claude.sh`, no `claude -p`, no tmux. The worktree is still created by `setup-worktree.sh`; only the agent launch is inline. Routing logic lives in `skills/run/SKILL.md` Step 6 and Step 7.
- **PATH B / PATH C** — execute-issue-plan and evaluate-issue-pr continue to dispatch through `scripts/spawn-claude.sh` (which invokes `claude -p`) and, for multi-issue runs, `scripts/run-queue.sh` + tmux. PATH B uses spawn-claude.sh; PATH C uses spawn-claude.sh. This is unchanged from the previous behavior and remains the indefinite default for B/C until external pressure (deprecation or quota signals on `-p`) forces broader migration.
- **PATH D** (quick-fix) — execute-issue-plan runs inline via `Agent(subagent_type=tdd-implementer, ...)` from the orchestrator session — like PATH A, but the subagent type is `tdd-implementer` (leaf executor with strict red->green->commit) instead of general-purpose. evaluate-issue-pr stays unchanged (auto-routes by PATH letter, inline for A and D, spawn-claude for B/C). PATH D ALSO skips evaluate-issue-plan entirely (the run orchestrator auto-flips `plan-pending` -> `plan-approved` when it observes a `quick-fix`+`plan-pending` issue in Step 4) and skips Step 8 (pre-PR review loop) of execute-issue-plan. The bet: evaluate-issue-pr is sufficient review at quick-fix scope. Routing precedence: A > D > C > B when multiple path labels collide.
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

There is one **fail-closed** counterpart: when `PIPELINE_EVAL_CLASSIFIER` is set AND the skill is `evaluate-issue-pr` AND `--container-mode=<name>` was NOT passed, spawn-claude re-invokes the classifier inline. If the classifier would emit a `--container-mode=<name>` token, spawn-claude exits **5** with actionable stderr instead of silently launching a bare-host evaluator — fixing the race where a stale consumer copy of the script pre-empts container dispatch (#238). Fail-open when the classifier is unset, the helper at `${CLAUDE_PLUGIN_ROOT}/scripts/eval-classifier-invoke.sh` is missing, or the classifier exits non-zero / emits nothing. This guarantee applies to both `scripts/spawn-claude.sh` and `scripts/run-queue.sh` (#325 reconciled the run-queue.sh path from fail-closed to fail-open).

When `--container-mode=<name>` IS passed, spawn-claude forwards `PIPELINE_PROJECT_ROOT=<repo-root>` and `PIPELINE_WORKTREE_PATH=<worktree-abs>` into `docker compose run -e` (#241). The compose file binds `${PIPELINE_PROJECT_ROOT}:${PIPELINE_PROJECT_ROOT}` (same-path) and pins `working_dir` to `${PIPELINE_WORKTREE_PATH:-${PIPELINE_PROJECT_ROOT}}`. Same-path binding is required because Claude Code's plugin discovery is keyed off the `projectPath` field in `~/.claude/plugins/installed_plugins.json` — slash commands resolve only when the container's `working_dir` lives under a registered project path. `mock-web-eval/scripts/mock-web-eval-probe-port.sh` also seeds both env vars into `mock-web-eval/target/.env.mock-web-eval` for operators who invoke `docker compose run` directly without going through `spawn-claude.sh`.

**Container-eligible skills (#321).** Container dispatch via `--container-mode=<name>` is allowlisted per skill via `PIPELINE_CONTAINER_SKILLS`. Default (unset) is `evaluate-issue-pr` only, preserving the #218 behavior. Explicit empty (`""`) disables container dispatch for all skills. To route additional skills (e.g. `execute-issue-plan`) through the container, list them in `pipeline.config` — see `pipeline.config.example` for syntax and the unset-vs-empty contract. The doctor's `container_skills_validity` check warns when an unknown skill name appears in the allowlist. **Narrowing decision:** the issue body originally proposed `PIPELINE_CONTAINER_CMD` (consumer-supplied dispatch command) and `PIPELINE_CONTAINER_ENV` (extra in-container env) as siblings; both were intentionally dropped to avoid a parallel dispatch path duplicating #218. Consumer container ENV continues to flow through `PIPELINE_EVAL_CONTAINER_<MODE>_ENV_FILE`; consumer compose shape continues through `PIPELINE_EVAL_CONTAINER_<MODE>_{COMPOSE_FILE,SERVICE}`. A follow-up issue can revisit if the narrowing proves insufficient for consumers like bomon-web. **Asymmetry caveat:** #238's classifier-required guard only covers `evaluate-issue-pr` — opting other skills into the allowlist does NOT extend classifier enforcement to those skills.

## MCP gating for spawned agents

The repo-root `.mcp.json` registers Playwright MCP. The orchestrator session (the one running `/pipeline:run` or `/pipeline:fullsend`) loads `.mcp.json` automatically from its working directory — unaffected by this gating.

Per-issue spawned agents (planner, executor, evaluator, classifier launched via `scripts/spawn-claude.sh`) default to **zero MCP servers**: the script synthesises a transient `/tmp/claude-mcp-empty-*.json` containing `{"mcpServers": {}}` and passes `--mcp-config <file> --strict-mcp-config` to the spawned `claude` CLI. The `--strict-mcp-config` flag is essential — without it `claude` can still discover MCP servers from user- or system-level config, defeating the gate. The tempfile is unlinked by the existing deferred-cleanup trap (alongside the system-prompt file and launcher).

Opt in to the project `.mcp.json` (the previous behaviour) by labelling the issue `needs-browser` — `spawn-claude.sh` inspects labels via `gh issue view --json labels` and skips the empty-config injection. Seed the label with `/pipeline:doctor --fix labels`. The gate is **fail-safe**: if `gh issue view` fails (offline/auth/rate-limit), `HAS_NEEDS_BROWSER` stays `0` and the agent defaults to no MCP rather than silently inheriting Playwright across every spawned agent in a wave. The same `needs-browser` label is the single source of truth shared with the visual-proof-from-plan sub-skill (#368).
