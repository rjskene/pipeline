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

## Agent cost capture + `/pipeline:tokenomics`

`scripts/capture-agent-costs.sh` (issue #642) is a retroactive parser that reads the `runs.log` (HEADLESS pass) and `subagents.log` (INLINE pass) substrate above and emits one normalized cost record per agent invocation to `.claude/logs/agent-costs.jsonl` (append-only, idempotent by `record_key`, gated by `PIPELINE_LOGS_ENABLED`). `scripts/cost-latency-report.sh` (issue #643) joins that log with merged feature PRs to render tokens/$/latency by issue, stage, and PATH.

The `usage_complete` field records token-completeness provenance, reconciled across both producers (the forward hook `hooks/capture_agent_cost.py` and the retroactive parser) per #765: **inline records (forward AND retroactive) carry `usage_complete=false`** — a lower-bound, because in this harness the inline `usage` is the subagent's final-turn snapshot, not a cumulative multi-turn total. **Orchestrator-Stop, headless, and cumulative-source (`total_usage`/`cumulative_usage`) records carry `usage_complete=true`** — those are genuine cumulative totals (transcript-summed or cumulative-field). SUM-ming consumers must treat `false` records as lower-bound, not complete.

**`/pipeline:tokenomics`** (`skills/tokenomics/SKILL.md`, dogfood-only, issue #721) is the backfill + report entrypoint over `agent-costs.jsonl`: it runs `capture-agent-costs.sh` (Step 1 backfill) then `cost-latency-report.sh --tokenomics` (Step 2), and presents every cost table — per-bucket (token-share vs cost-share), per-stage cost, session-structure (spawn vs in-session) + stage×structure cross-tab, B→D breakeven, coverage-health, per-day/per-PR trend with outlier flagging — plus the concurrency assessment. Per-model pricing is config-driven via `PIPELINE_PRICE_<MODEL>_<BUCKET>` rates (Opus list-price defaults; see `pipeline.config.example`). Reads only the gated log; writes nothing to consumer `.claude/{skills,hooks,scripts,agents}/`.

Report-surface flags (forwarded to `cost-latency-report.sh`):
- **Per-day windowing** — `--since DATE` / `--until DATE` form a closed `[since, until]` window over `ts_start`; `--per-day` walks it day-by-day (default: last 5 days, UTC), one report block per `=== DAY YYYY-MM-DD ===`.
- **Token columns** — per-stage / per-structure / per-PATH tables carry per-N token-bucket columns (input / output / cache_creation / cache_read) from the reconciled substrate; the trend table adds per-N and per-LOC cost columns.
- **Durable history** — `scripts/snapshot-tokenomics-history.sh` upserts a per-day aggregate into `.claude/logs/tokenomics-history.jsonl` (keyed by date, last-write-wins) so a day survives raw-log pruning; `--emit-day-json` is its machine-mode source, and `--history [PATH]` renders the report from the persisted store (no PR join, no `gh`) once the live log is gone.
