# Plugin architecture

Pipeline assets live outside the consumer project. The plugin installs to `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`). Hooks, scripts, and the `tdd-implementer` subagent are registered from the plugin manifest; skills auto-discover from `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` and the manifest does not enumerate them. The consumer project's `.claude/` stays clean.

## Consumer-required rendered scripts

Post-#215/#223, plugin skills invoke worktree/dispatch helpers as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh` directly; the consumer `.claude/scripts/` mirror has been retired. The doctor's `.template-branch` in `doctor.sh` is dead code retained for legacy subtree consumers and will be removed in a follow-up.

## Consumer config

The consumer project owns exactly one pipeline file: `pipeline.config` at the project root. The plugin reads it via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims at runtime — there is no install-time template rendering anymore, and skill files reference `$PIPELINE_*` as runtime shell variables sourced from `pipeline.config` at session start (per each skill's `## Boot` section).

## Slash command namespacing

All slash commands are namespaced under `pipeline:` (`/pipeline:plan-issue`, `/pipeline:run`, …). Unprefixed command names like `plan-issue` are intentionally not registered so the plugin coexists with other plugins that might claim those names.

## Legacy install

Legacy install (`install.sh`, the `.claude-pipeline/` subtree, and the subtree-drift tooling) has been retired. Existing subtree consumers run `scripts/migrate-from-subtree.sh` once and then install the plugin.

## Observability hooks are dogfood-only

`log-tool-use.sh` and `log_subagent.py` are registered via this repo's `.claude/settings.json` only; they are not part of the published manifest. See [observability.md](observability.md).

## Bash subshells & CLAUDE_PLUGIN_ROOT resolution

`CLAUDE_PLUGIN_ROOT` is not guaranteed to be exported into the Bash tool's subshell — Claude Code does not consistently propagate it. Every consumer-facing skill sources `scripts/_resolve-plugin-root.sh` in its `## Boot` block, which (when the env var is empty) picks the highest-version directory under `~/.claude/plugins/cache/claude-pipeline/pipeline/` and exports it.

Doctor's `claude_plugin_root` check surfaces the resolution state across four cases:

- `pass` — env pre-set + valid dir.
- `pass` — env empty, self-resolved from the plugin cache.
- `warn` — env set but path missing/invalid (likely a stale config).
- `fail` — env empty and no plugin cache exists.

## Doctor

`/pipeline:doctor` is a non-mutating validator consumers run after install. It audits `pipeline.config`, `gh` auth, plugin registration, the pipeline-stage labels on the GitHub repo, residual subtree artifacts, and the base branch's local presence + remote tracking — emitting structured `CHECK: <name> status=<pass|fail|warn> detail=<msg>` lines and a final summary table. Non-zero exit signals any `fail`. The `--fix labels` flag is the one write path: it seeds the canonical pipeline labels via `gh label create --force` (idempotent upsert) and honors `PIPELINE_LABELS_*` overrides. Entrypoint: `scripts/doctor.sh`. Skill: `skills/doctor/SKILL.md`.
