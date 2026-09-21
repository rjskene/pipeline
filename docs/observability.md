# Observability (dogfood-only)

Logging hooks and substrate for this repo's own dogfood operation. Most are registered in this repo's `.claude/settings.json` only; the published `pipeline@claude-pipeline` plugin manifest does NOT register them, so consumer installs produce no `.claude/logs/subagents/` or `.claude/logs/tool-use.log` files.

## Subagent log

**dogfood-only.** `.claude/hooks/log_subagent.py` is a PostToolUse hook that logs every Agent tool invocation. It writes per-agent JSON files to `.claude/logs/subagents/`, a consolidated TSV to `.claude/logs/subagents.log`, and errors to `.claude/logs/subagent-hook-errors.log`. All logs are gitignored and the hook uses fail-open semantics (errors are swallowed so they never block tool use).

**Result capture (#1233).** The real PostToolUse(Agent) payload carries no `result` key — the leaf's returned text is sourced from the `content` list of `{"type": "text", "text": ...}` blocks (`status == "completed"`); the legacy top-level `result` key is a back-compat fallback only, for synthetic/older payload shapes. `status == "async_launched"` (background dispatch) is a coverage hole: the leaf's result is never delivered to this hook, so `.result` is recorded empty and `.status` is the only signal that distinguishes "backgrounded, no result yet" from "the leaf genuinely returned nothing".

**CAPABILITY-REFUSED: sentinel detector (#1233).** `scripts/check-capability-refusal.sh` is the mechanical listener for the `CAPABILITY-REFUSED:` contract (`agents/tdd-implementer.md`, #1225). It scans `.result` only (never `.prompt`, which can legitimately quote the contract) and resolves exactly one of four coverage states per issue: `leaf-refused` (a real refusal — blocks auto-merge via `block-capability-refused`), `no-refusal` (the only confident clean — at least one in-scope file yielded leaf text and none carried the sentinel), `no-leaf-output` (in-scope files were opened but none yielded leaf text — proves nothing; this is the state of every record before the result-capture fix above, and of any `async_launched` record even after it), and `no-sources` (nothing scannable resolved for the issue). Only `no-refusal` is a confident clean; the other two `clear` states are surfaced with a gate-level `WARN` rather than silently treated as green.

**Source resolution from a worktree (#1246).** `evaluate-issue-pr` Step 11.2 ALWAYS runs from a feature worktree, and a linked worktree has no `.claude/logs/` of its own — resolving the sources dir as `$(pwd)/.claude/logs/subagents` left the gate arm permanently dormant. `check-capability-refusal.sh --resolve-sources [<start-dir>]` fixes this by resolving worktree-aware, via `git rev-parse --git-common-dir`, against the MAIN checkout. It emits one of three tokens: `resolved` (root and log dir both found — the knob is threaded), `no-log-dir` (root resolved but the log dir genuinely does not exist — benign, expected on `PIPELINE_LOGS_ENABLED=false` consumer installs), or `unresolvable-root` (no main checkout resolvable from cwd — the defensive, non-git-cwd case). Both `no-log-dir` and `unresolvable-root` leave `PIPELINE_CAPABILITY_REFUSAL_SOURCES` unexported, so the gate arm is skipped entirely — fail-open is structural, and a missing log dir can never hard-block a merge.

## Tool-use log

**dogfood-only.** `.claude/logs/tool-use.log` is a tab-separated per-tool-call log (timestamp, tool, session, summary) written by `.claude/hooks/log-tool-use.sh` (PostToolUse `*`). Correlate with `subagents.log` via the `session` field to reconstruct the tool sequence inside each subagent — useful for verifying TDD order (Write test → Bash pytest fail → Write impl → Bash pytest pass). Log rotation is not automated; `cleanup-worktree.sh` copies per-issue logs to the root `.claude/logs/tool-use-issue-<N>.log` on worktree teardown.

## Hook-denial log

**dogfood-only, gated (#1352).** PreToolUse guard hooks that deny (exit 2) leave no trace in `tool-use.log` — that log is written by a PostToolUse hook, which never fires for a denied call, so a false positive was previously unauditable. `hooks/_deny_log.py` closes that gap: each guard hook (`block_deletions.py`, `restrict_paths.py`, `enforce-base-branch.py`, `enforce-comment-trust.py`, `check-ci-skip-markers.py`, `enforce-ci-wait.py`, `enforce-path-c-delegation.py`) calls `log_denial(hook, tool_name, reason, command_text="")` immediately before its `sys.exit(2)` / `return 2`, appending one JSONL record to `.claude/logs/hook-denials.jsonl`:

```json
{"ts":"2026-09-21T13:05:00Z","hook":"restrict_paths","tool":"Bash","session":"<CLAUDE_SESSION_ID or unknown>","reason":"<first line of the stderr reason>","command":"<masked command text via hooks/command_mask.py, truncated to 512 chars>"}
```

`enforce-ci-wait.py` denies from a **Stop** hook, not PreToolUse — its record carries `tool:"Stop"`, a deliberate widening of the "PreToolUse denials" framing.

Gated on the same [`PIPELINE_LOGS_ENABLED`](#pipeline_logs_enabled-gate) flag as `tool-use.log` / `agent-costs.jsonl` (disabled — no file, no directory touched — until a host opts in); the log-dir resolution mirrors `capture_agent_cost.py` (`CLAUDE_PROJECT_DIR` or cwd, then `.claude/logs/`), so denials from linked worktrees land in the one durable main-checkout file. The helper is **fail-open by construction**: its entire body is wrapped in one `try/except Exception: pass`, so a logging failure can never turn a deny into a crash or an allow, and it writes no error log of its own. No guard's decision logic, exit code, or stderr text changes — this is a pure audit-trail addition.

## Runs log

`.claude/logs/runs.log` is a tab-separated per-spawn marker written by `spawn-claude.sh` at session launch (one line per spawn). Columns: timestamp, `session=<uuid>`, `issue=<N>`, `path=<A|B|C>`, `skill=<name>`, `worktree=<path>`. The session UUID matches `--session-id` passed to the claude CLI, so it joins 1:1 with `tool-use.log` and `subagents.log` rows for that session.

Use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh [--last N | --path X | --deviations | --issue N | --since DATE]` to inspect runs — the script derives signals (skill sequence vs expected, subagent dispatches, TDD commit pattern) on the fly from the raw substrate, so there's no derived-audit JSON to stale. Log rotation is not automated; at steady state (~50 spawns/week) growth is negligible.

## PIPELINE_LOGS_ENABLED gate

`PIPELINE_LOGS_ENABLED` (in `pipeline.config`) gates plugin writes to `.claude/logs/` — `runs.log`, `queue-*.log`, `queue-pending.txt`, per-issue `tool-use-issue-<N>.log` copies emitted by `cleanup-worktree.sh`, the analyze-mode shortlist JSON, and ci-fix attempt logs. **Default is `false`** so installing the plugin imposes no logging on consumer projects. **This repo's gitignored `pipeline.config` sets `PIPELINE_LOGS_ENABLED=true`** as a dogfood override so `scripts/capture-agent-costs.sh`, `scripts/review-audits.sh`, and `scripts/metrics-snapshot.sh` keep receiving the `runs.log` substrate they need.

**Carve-out:** `hooks/enforce-path-c-delegation.py` and `hooks/enforce-ci-wait.py` still write `.claude/logs/enforce-*-errors.log` on hook fail-open paths — that emergency-diagnosis stream is intentionally ungated.

## Agent cost capture + `/pipeline:tokenomics`

`scripts/capture-agent-costs.sh` (issue #642) is a retroactive parser that reads the `runs.log` (HEADLESS pass) and `subagents.log` (INLINE pass) substrate above and emits one normalized cost record per agent invocation to `.claude/logs/agent-costs.jsonl` (append-only, idempotent by `record_key`, gated by `PIPELINE_LOGS_ENABLED`). `scripts/cost-latency-report.sh` (issue #643) joins that log with merged feature PRs to render tokens/$/latency by issue, stage, and PATH.

The `usage_complete` field records token-completeness provenance, reconciled across both producers (the forward hook `hooks/capture_agent_cost.py` and the retroactive parser) per #765: **inline records (forward AND retroactive) carry `usage_complete=false`** — a lower-bound, because in this harness the inline `usage` is the subagent's final-turn snapshot, not a cumulative multi-turn total. **Orchestrator-Stop, headless, and cumulative-source (`total_usage`/`cumulative_usage`) records carry `usage_complete=true`** — those are genuine cumulative totals (transcript-summed or cumulative-field). SUM-ming consumers must treat `false` records as lower-bound, not complete.

**`/pipeline:tokenomics`** (`skills/tokenomics/SKILL.md`, dogfood-only, issue #721) is the backfill + report entrypoint over `agent-costs.jsonl`: it runs `capture-agent-costs.sh` (Step 1 backfill) then `cost-latency-report.sh --tokenomics` (Step 2), and presents every cost table — per-bucket (token-share vs cost-share), per-stage cost, session-structure (spawn vs in-session) + stage×structure cross-tab, B→D breakeven, coverage-health, per-day/per-PR trend with outlier flagging — plus the concurrency assessment. Per-model pricing is config-driven via `PIPELINE_PRICE_<MODEL>_<BUCKET>` rates (Opus list-price defaults; see `pipeline.config.example`). Reads only the `PIPELINE_LOGS_ENABLED`-gated `agent-costs.jsonl` (see [the gate above](#pipeline_logs_enabled-gate)); writes nothing to consumer `.claude/{skills,hooks,scripts,agents}/`.

Report-surface flags (forwarded to `cost-latency-report.sh`):
- **Per-day windowing** — `--since DATE` / `--until DATE` form a closed `[since, until]` window over `ts_start`; `--per-day` walks it day-by-day (default: last 5 days, UTC), one report block per `=== DAY YYYY-MM-DD ===`.
- **Token columns** — per-stage / per-structure / per-PATH tables carry per-N token-bucket columns (input / output / cache_creation / cache_read) from the reconciled substrate; the trend table adds per-N and per-LOC cost columns.
- **Durable history** — `scripts/snapshot-tokenomics-history.sh` upserts a per-day aggregate into `.claude/logs/tokenomics-history.jsonl` (keyed by date, last-write-wins) so a day survives raw-log pruning; `--emit-day-json` is its machine-mode source, and `--history [PATH]` renders the report from the persisted store (no PR join, no `gh`) once the live log is gone.

**Split-role RED/GREEN cost attribution (#1098/#1104).** Split-role PATH B runs
now emit role-attributed cost records — the Opus RED test-author and the cheaper
GREEN implementer are captured as distinct roles in `agent-costs.jsonl` — so
`/pipeline:tokenomics` can break the per-issue cost down by split-role role. This
makes the cost posture of the two-model lane (expensive authorship vs. cheap
greening) directly measurable rather than lumped into a single PATH B figure.

## Log retention (`scripts/prune-logs.sh`)

`.claude/logs/` grows without bound once `PIPELINE_LOGS_ENABLED=true` — nothing prunes the per-issue / per-queue transcripts it accumulates. `scripts/prune-logs.sh` (issue #1353) is a retention pass over that directory, **dry run by default**:

```
bash scripts/prune-logs.sh [--apply] [--days N]
```

- **Retention window** — `PIPELINE_LOGS_RETENTION_DAYS` (commented in `pipeline.config.example`, read site `${PIPELINE_LOGS_RETENTION_DAYS:-30}`, default 30 days); `--days N` overrides it for a single run. A file is a candidate only when its age is strictly greater than the window (a file exactly at the boundary survives).
- **Keep-list, checked first** — these aggregates and live streams are never candidates, no matter their age: `agent-costs.jsonl`, `tokenomics-history.jsonl`, `usage-gate.jsonl`, `metrics-timeseries.jsonl`, `metrics-snapshot.cron.log`, `agent-cost-orchestrator-state.json`, `tool-use.log`, `subagents.log`, `runs.log`, `hook-errors.log`, `dogfood-refresh.log`, and everything under `plan-drafts/`. A new aggregate file is safe by default only if it is added to this list (or if it fails to match a prune glob at all — the script is fail-safe by construction).
- **Prune set** — per-issue and per-run transcripts: `issue-<N>-*.log`, `issue-<N>-plan.md`, `queue-*.log`, `tool-use-issue-<N>.log`, `ci-fix-<N>-attempt-<k>.log`, `fullsend-*.out`, `runner-*.log`, `analyze-shortlist-*.json`, and everything under `subagents/` at any depth.
- **Output** — one `PRUNE path=<rel> age_days=<n>` line per candidate, then exactly one `SUMMARY candidates=<n> bytes=<n> mode=dry-run` (or `mode=apply`) line. Exits 0 on every non-usage path, including a missing `.claude/logs/` dir.
- **Deleting is an operator action.** `--apply` only deletes when the repo's existing `ALLOW_DELETIONS` gate is open (env `ALLOW_DELETIONS=true`, or `.env.ALLOW_DELETIONS` in `.claude/settings.local.json` — the same convention `sync-worktrees.sh` / `cleanup-worktree.sh` use); otherwise it behaves like a dry run and prints a notice to stderr. Deletes files only — empty directories (including `subagents/`) are left in place.
- **Status wiring** — `/pipeline:status` housekeeping calls the script with no flags (dry run only) when `PIPELINE_LOGS_ENABLED=true`, relaying just the `SUMMARY` line; it never passes `--apply`.
