# Plugin architecture

Pipeline assets live outside the consumer project. The plugin installs to `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`). Hooks, scripts, and the `tdd-implementer` subagent are registered from the plugin manifest; skills auto-discover from `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` and the manifest does not enumerate them. The consumer project's `.claude/` stays clean.

## Consumer-required rendered scripts

Post-#215/#223, plugin skills invoke worktree/dispatch helpers as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh` directly; the consumer `.claude/scripts/` mirror has been retired. The doctor's legacy `.template-branch` probe (formerly retained for subtree consumers) has since been removed from `doctor.sh`.

## Consumer config

The consumer project owns exactly one pipeline file: `pipeline.config` at the project root. The plugin reads it via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims at runtime — there is no install-time template rendering anymore, and skill files reference `$PIPELINE_*` as runtime shell variables sourced from `pipeline.config` at session start (per each skill's `## Boot` section).

## Slash command namespacing

All slash commands are namespaced under `pipeline:` (`/pipeline:plan-issue`, `/pipeline:run`, …). Unprefixed command names like `plan-issue` are intentionally not registered so the plugin coexists with other plugins that might claim those names.

## Greenfield install (`/pipeline:init`)

`/pipeline:init` is the first-class bootstrap for a brand-new project that never had the subtree — the inverse of `migrate-from-subtree.sh`. Where migrate *retires* a legacy install, init *stands up* a fresh one. Entrypoint: `scripts/init.sh`; skill: `skills/init/SKILL.md`. It composes existing primitives rather than reimplementing them: label seeding delegates to `doctor.sh --fix labels` and the closing audit is the read-only `doctor.sh`. Its five phases are preflight (one `PREFLIGHT: <dep> status=<pass|fail|warn>` line per dep; `gh`/`jq`/`bash` fail-fast before any config write, `tmux` and the Windows-jq-on-bash-PATH probe warn), config generation (`PIPELINE_REPO` from `gh repo view --json nameWithOwner`, `PIPELINE_BASE_BRANCH` from `defaultBranchRef`, no-op `true`/empty defaults for projects without tests/CI, `--force` to overwrite), `.gitignore` append (idempotent), label seeding, and the doctor tail. The doctor itself remains read-only for everything except `--fix labels`; init is the write-path bootstrap that doctor was never meant to be.

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

### Boot-block resolver pattern

Every consumer-facing `SKILL.md` opens with a `## Boot` block that pairs a `pipeline.config` source with a `_resolve-plugin-root.sh` source. The canonical form is:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The snippet locates the resolver via a var-independent cache-glob anchor (`~/.claude/plugins/cache/claude-pipeline/pipeline/*/`) rather than the old chicken-and-egg `${CLAUDE_PLUGIN_ROOT:-.}/scripts/...` form — which silently no-op'd when `CLAUDE_PLUGIN_ROOT` was unset because it collapsed to a non-existent `./scripts/...` in the consumer cwd (#810). The glob only LOCATES the resolver; sourcing it then re-derives the authoritative root (dogfood `claude-pipeline-local` tiebreak, active-project mode, highest-semver scan), so consumers and dogfood operators converge on the same root as before.

Why every skill needs it: `CLAUDE_PLUGIN_ROOT` only lives for the Bash tool's subshell. Each subsequent Bash tool call spawns a fresh subshell with no inherited env — so the orchestrator's session-start export does not propagate. Without the in-skill resolver, `bash "${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh"` collapses to `bash "/scripts/foo.sh"` or `bash "./scripts/foo.sh"`, 404'ing the plugin helper. The resolver is idempotent: a no-op when `CLAUDE_PLUGIN_ROOT` is already a valid path.

Two contract tests enforce this invariant:

- `tests/test-skills-source-resolver.sh` — line-positional: every consumer-facing `SKILL.md` MUST source the resolver in its first 30 lines.
- `tests/test-skill-bash-blocks-self-resolve.sh` — usage-anchored: every `SKILL.md` that invokes a plugin script via `bash ${CLAUDE_PLUGIN_ROOT}/...` or `python3 ${CLAUDE_PLUGIN_ROOT}/...` anywhere in its body MUST also have the Boot resolver. Catches the regression where a skill adds a new plugin-script invocation but forgets the Boot block.

Adding a new consumer-facing skill? Copy the canonical snippet verbatim from `skills/create-issues/SKILL.md` into your `## Boot` block, then add the new skill to the `SKILLS` arrays in both tests. A third test, `tests/test-skill-boot-snippet-anchor.sh`, pins the cache-glob anchor shape (no chicken-and-egg `${CLAUDE_PLUGIN_ROOT:-.}` form) across all `SKILL.md` Boot blocks.

## Doctor

`/pipeline:doctor` is a non-mutating validator consumers run after install. It audits `pipeline.config`, `gh` auth, plugin registration, the pipeline-stage labels on the GitHub repo, residual subtree artifacts, and the base branch's local presence + remote tracking — emitting structured `CHECK: <name> status=<pass|fail|warn> detail=<msg>` lines and a final summary table. Non-zero exit signals any `fail`. The `--fix labels` flag is the one write path: it seeds the canonical pipeline labels via `gh label create --force` (idempotent upsert) and honors `PIPELINE_LABELS_*` overrides. Entrypoint: `scripts/doctor.sh`. Skill: `skills/doctor/SKILL.md`.
