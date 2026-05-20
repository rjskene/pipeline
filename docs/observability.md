# Observability (dogfood-only)

Logging hooks and substrate used by this repo's self-audit system. Most are registered in this repo's `.claude/settings.json` only; the published `pipeline@claude-pipeline` plugin manifest does NOT register them, so consumer installs produce no `.claude/logs/subagents/` or `.claude/logs/tool-use.log` files.

## Subagent log

**dogfood-only.** `.claude/hooks/log_subagent.py` is a PostToolUse hook that logs every Agent tool invocation. It writes per-agent JSON files to `.claude/logs/subagents/`, a consolidated TSV to `.claude/logs/subagents.log`, and errors to `.claude/logs/subagent-hook-errors.log`. All logs are gitignored and the hook uses fail-open semantics (errors are swallowed so they never block tool use).

## Tool-use log

**dogfood-only.** `.claude/logs/tool-use.log` is a tab-separated per-tool-call log (timestamp, tool, session, summary) written by `.claude/hooks/log-tool-use.sh` (PostToolUse `*`). Correlate with `subagents.log` via the `session` field to reconstruct the tool sequence inside each subagent — useful for verifying TDD order (Write test → Bash pytest fail → Write impl → Bash pytest pass). Log rotation is not automated; `cleanup-worktree.sh` copies per-issue logs to the root `.claude/logs/tool-use-issue-<N>.log` on worktree teardown.

## Runs log

`.claude/logs/runs.log` is a tab-separated per-spawn marker written by `spawn-claude.sh` at session launch (one line per spawn). Columns: timestamp, `session=<uuid>`, `issue=<N>`, `path=<A|B|C>`, `skill=<name>`, `worktree=<path>`. The session UUID matches `--session-id` passed to the claude CLI, so it joins 1:1 with `tool-use.log` and `subagents.log` rows for that session.

Use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh [--last N | --path X | --deviations | --issue N | --since DATE]` to inspect runs — the script derives signals (skill sequence vs expected, subagent dispatches, TDD commit pattern) on the fly from the raw substrate, so there's no derived-audit JSON to stale. Log rotation is not automated; at steady state (~50 spawns/week) growth is negligible.

## PIPELINE_LOGS_ENABLED gate

`PIPELINE_LOGS_ENABLED` (in `pipeline.config`) gates plugin writes to `.claude/logs/` — `runs.log`, `queue-*.log`, `queue-pending.txt`, per-issue `tool-use-issue-<N>.log` copies emitted by `cleanup-worktree.sh`, the analyze-mode shortlist JSON, and ci-fix attempt logs. **Default is `false`** so installing the plugin imposes no logging on consumer projects. **This repo's gitignored `pipeline.config` sets `PIPELINE_LOGS_ENABLED=true`** as a dogfood override so `dev/self-audit/inner-loop.sh` keeps receiving the `runs.log` substrate it needs.

**Carve-out:** `hooks/enforce-path-c-delegation.py` and `hooks/enforce-ci-wait.py` still write `.claude/logs/enforce-*-errors.log` on hook fail-open paths — that emergency-diagnosis stream is intentionally ungated.
