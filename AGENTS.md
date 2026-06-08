# AGENTS.md — Claude Pipeline (Codex entry)

This is the **Codex-side** entry document for Claude Pipeline. It is a regular
file (deliberately **not** a symlink to `CLAUDE.md`) because `CLAUDE.md` carries
Claude-Code-only assertions; this wrapper adds the Codex preamble below, then
links the canonical project doc.

## Codex preamble

- **Tool map.** Codex tool names and their Claude-Code equivalents are documented
  in `codex-tools.md` (created in a later leg of the dual-target migration; the
  pointer here is intentional so this entry is wired up ahead of that file).
  Consult it for the Read/Write/Edit/Bash and MCP tool mappings when running the
  pipeline under Codex.
- **Multi-agent.** PATH C (multi-task) fans out one leaf executor per
  `target=<dir>`. Running it under Codex requires `multi_agent = true` in your
  Codex configuration so the orchestrator may dispatch leaf agents.
- **Hook trust.** The pipeline ships PreToolUse/Stop hooks (base-branch
  enforcement, deletion guards, PATH C delegation, CI-wait). Under Codex you must
  explicitly **trust** these hooks for them to run; an untrusted hook is silently
  skipped, removing a defense-in-depth layer. Review and trust the pipeline hooks
  before driving the lifecycle.

## Project documentation

The canonical Claude Pipeline documentation — lifecycle, label flow, dispatch
model, install paths, namespace discipline, and design principles — lives in
[`CLAUDE.md`](./CLAUDE.md). Read it before operating the pipeline; everything in
`CLAUDE.md` applies under Codex except where the Codex preamble above overrides
or supplements it.
