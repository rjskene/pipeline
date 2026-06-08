# Codex Tool Mapping

Pipeline skills are authored in **Claude Code (CC) tool names** — the lingua
franca across both harnesses. When a skill names one of these tools and you are
running under Codex, use the equivalent below. Skills are *meaning-reachable*:
the CC name is canonical phrasing, this table is the bridge.

| Skill references (CC tool) | Codex equivalent |
|----------------------------|------------------|
| `Task` (dispatch subagent) | `spawn_agent` — see [Subagent dispatch requires multi-agent](#subagent-dispatch-requires-multi-agent) |
| Multiple `Task` calls (parallel) | Multiple `spawn_agent` calls |
| `Task` returns result | `wait_agent` |
| `Task` completes automatically | `close_agent` to free the slot |
| `Agent` (`Agent(subagent_type=…)` — pipeline's Task-family dispatch verb) | `spawn_agent` (same family as `Task`; the pipeline writes `Agent(subagent_type=…)` where CC docs write `Task`) |
| `TodoWrite` (task tracking) | `update_plan` |
| `Skill` (invoke a skill) | Skills load natively — just follow the instructions |
| `Read` (read a file) | Native file tool |
| `Write` (write a file) | Native file tool — **collapses to `apply_patch`** (see below) |
| `Edit` (edit a file) | Native file tool — **collapses to `apply_patch`** (see below) |
| `Bash` (run commands) | Native shell |
| `Grep` (content search) | Native search |
| `Glob` (file-glob) | Native file-glob |
| `mcp__playwright_*` (browser MCP tools) | Codex `[mcp_servers.playwright]` (TOML) MCP tools — see [Pipeline extras](#pipeline-extras) |

CC `Edit` + `Write` are two tools; on Codex both collapse to the single
`apply_patch` tool. A skill that says "use `Edit`" or "use `Write`" means
`apply_patch` under Codex.

## Subagent dispatch requires multi-agent

`spawn_agent`, `wait_agent`, and `close_agent` need multi-agent support enabled
in `~/.codex/config.toml`:

```toml
[features]
multi_agent = true
```

This is **required for PATH C fan-out** (the pipeline dispatches one
`tdd-implementer` per `target=<dir>` leaf). Without it, the parallel-leaf
dispatch in `fullsend` / `execute-issue-plan` cannot run.

Legacy note: Codex builds before `rust-v0.115.0` exposed spawned-agent waiting
as `wait`. Current Codex uses `wait_agent` for spawned agents; `wait` now
belongs to code-mode `exec/wait` (resumes a yielded exec cell by `cell_id`) and
is **not** the spawned-agent result tool.

## Pipeline extras

Codex-side tools the pipeline leans on beyond the superpowers base mapping:

| Codex tool | Used for |
|------------|----------|
| `apply_patch` | The single Codex file-mutation tool — the target of every CC `Edit` and `Write`. |
| `spawn_agent` / `wait_agent` / `close_agent` | Subagent lifecycle. Require `[features] multi_agent = true` (above). Needed for PATH C fan-out. |
| `codex exec` | Headless one-shot run — the Codex analog of `claude -p`, used by the `--spawn` run-queue transport (`spawn-codex.sh`). |

## `${CLAUDE_PLUGIN_ROOT}` Boot blocks

Every skill opens with a `## Boot` block that self-resolves
`${CLAUDE_PLUGIN_ROOT}`. These resolve under **both** harnesses via the
`_resolve-plugin-root.sh` Codex branch (#980), which anchors on `CODEX_HOME`
when present. **No per-skill Boot edits are needed** to run a skill under Codex.
