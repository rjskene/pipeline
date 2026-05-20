# Self-improvement loop (dogfood-only)

This repo dogfoods a **repo-only audit system** that observes pipeline behavior to surface improvement candidates. The audit is **not part of the plugin** — nothing in `.claude-plugin/` references it, no consumer sees it.

## Trigger

This repo's `.claude/settings.json` registers a `UserPromptSubmit` hook that runs `dev/hooks/audit-on-pipeline-run.sh`. When the submitted prompt starts with `/pipeline:run`, the hook backgrounds `dev/self-audit/inner-loop.sh` and returns in <200ms. The user's prompt is not blocked.

## Inner loop

`dev/self-audit/inner-loop.sh` reads `dev/audits/index.jsonl` for the last audit timestamp, queries `gh` for merged feature/* PRs since then, reads observability logs (`.claude/logs/subagents/*.json`, `.claude/logs/tool-use*.log`, `.claude/logs/runs.log`) plus the orchestrator transcript at `${AUDIT_CLAUDE_PROJECTS_DIR:-~/.claude/projects}/<project-hash>/<session-uuid>.jsonl`, and emits `dev/audits/inner-<ISO>.md`.

Every digest contains five sections: **Compliance**, **Interaction**, **Pattern → defaults** (per-run noise), **Efficiency**, and **Data quality** (which inputs were present/missing — blind spots are a first-class finding). The Interaction section ships as a `_pending subagent classification — session <uuid>_` placeholder. As of the startup-prompt strip (#317) the placeholder is no longer filled in by `/pipeline:run`; a dogfood-only follow-up will move dispatch into `inner-loop.sh` itself via `claude -p` (filed separately as a `brainstorm` issue). After every third new entry, the inner loop backgrounds `outer-loop.sh`.

## Outer loop

`dev/self-audit/outer-loop.sh` reads the last 3 inner entries from `index.jsonl` and surfaces signals consistent across ALL of them.

**Cross-run pattern detection on `Suggested default` strings:** when ≥2 of 3 runs in the window emit the same `Suggested default` (exact-string match in MVP; Jaccard ≥0.7 is the upgrade path), the outer digest names that string as a **codification candidate**. For each pattern, it names a **codification target** on a plugin surface: skill prose, `pipeline.config.example`, hooks, or scripts. **Never local-machine personal state** — that does not propagate. The outer loop is read-only: it files no issues, modifies no surfaces. A human reads the digest and files the issue when ready.

## Four lenses (MVP — interaction lens is the only one with real heuristics)

1. **Compliance** — TODO stub (TDD pattern, wave-prio, PATH-tier dispatch, hook trip counts). Deferred until interaction lens proves its 10-run success criterion (#135 / #136).
2. **Interaction** — IMPLEMENTED (subagent-classified correction events with the three-field contract above). Other interaction signals (turn count, unnecessary confirmations) remain TODO; they can be added without re-architecting.
3. **Pattern → defaults** — IMPLEMENTED in outer-loop's 2-of-3 cross-run detector on Suggested-default strings.
4. **Efficiency** — TODO stub (tokens, wall clock, re-plan loops, eval-Revise verdicts).

## Redaction discipline (load-bearing)

Every transcript quote passes through `dev/self-audit/redact.sh::redact()`, which hard-denies token-shaped strings (regex `[A-Za-z0-9]{32,}`), the case-insensitive keywords `password|token|secret|api[_-]?key|bearer|Authorization`, and URLs containing `?key=|?token=|?auth=`; caps line length at 200 chars with a `...[truncated; original N chars]` suffix; and strips triple-backtick code-block contents entirely (only surrounding prose survives). Verified by `dev/tests/test-redaction.sh`.

## Output location

All digests and `index.jsonl` live in `dev/audits/`, which is gitignored — digests may contain redacted excerpts and stay on-disk locally only.

## Plugin manifest is untouched

`dev/`, `.claude/settings.json`, and the allow-list entry in `tests/no-consumer-claude-writes.allow` are the only surfaces this system writes to in this repo. `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/`, `scripts/`, `hooks/`, `agents/` are not modified by this system.

## Internal-path dependency

The orchestrator transcript path `~/.claude/projects/<project-hash>/<session-uuid>.jsonl` is a Claude Code internal. If Anthropic changes it, set `AUDIT_CLAUDE_PROJECTS_DIR` in the environment to point at the new location.

## Tests

Tests live at `dev/tests/test-*.sh` and are run by `dev/tests/run-all.sh` (which CI invokes alongside `tests/test*.sh`).
