# Plugin architecture

Pipeline assets live outside the consumer project. The plugin installs to `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`). Hooks, scripts, and the `tdd-implementer` subagent are registered from the plugin manifest; skills auto-discover from `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` and the manifest does not enumerate them. The consumer project's `.claude/` stays clean.

## Consumer-required rendered scripts

Post-#215/#223, plugin skills invoke worktree/dispatch helpers as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh` directly; the consumer `.claude/scripts/` mirror has been retired. The doctor's legacy `.template-branch` probe (formerly retained for subtree consumers) has since been removed from `doctor.sh`.

## Consumer config

The consumer project owns exactly one pipeline file: `pipeline.config` at the project root. The plugin reads it via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims at runtime — there is no install-time template rendering anymore, and skill files reference `$PIPELINE_*` as runtime shell variables sourced from `pipeline.config` at session start (per each skill's `## Boot` section).

## Slash command namespacing

All slash commands are namespaced under `pipeline:` (`/pipeline:plan-issue`, `/pipeline:status`, …). Unprefixed command names like `plan-issue` are intentionally not registered so the plugin coexists with other plugins that might claim those names.

## Greenfield install (`/pipeline:init`)

`/pipeline:init` is the first-class bootstrap for a brand-new project that never had the subtree — the inverse of `migrate-from-subtree.sh`. Where migrate *retires* a legacy install, init *stands up* a fresh one. Entrypoint: `scripts/init.sh`; skill: `skills/init/SKILL.md`. It composes existing primitives rather than reimplementing them: label seeding delegates to `doctor.sh --fix labels` and the closing audit is the read-only `doctor.sh`. Its five phases are preflight (one `PREFLIGHT: <dep> status=<pass|fail|warn>` line per dep; `gh`/`jq`/`bash` fail-fast before any config write, `tmux` and the Windows-jq-on-bash-PATH probe warn), config generation (`PIPELINE_REPO` from `gh repo view --json nameWithOwner`, `PIPELINE_BASE_BRANCH` from `defaultBranchRef`, no-op `true`/empty defaults for projects without tests/CI, `--force` to overwrite), `.gitignore` append (idempotent), label seeding, and the doctor tail. The doctor itself remains read-only for everything except `--fix labels`; init is the write-path bootstrap that doctor was never meant to be.

## Legacy install

Legacy install (`install.sh`, the `.claude-pipeline/` subtree, and the subtree-drift tooling) has been retired. Existing subtree consumers run `scripts/migrate-from-subtree.sh` once and then install the plugin.

## Observability hooks are dogfood-only

`log-tool-use.sh` and `log_subagent.py` are registered via this repo's `.claude/settings.json` only; they are not part of the published manifest. See [observability.md](observability.md).

## Codex enforcement wiring

The pipeline runs the same enforcement gates under Codex as under Claude Code. `.codex/config.toml` is the Codex twin of `.claude-plugin/plugin.json`'s `hooks` block: **same Python scripts under `hooks/`, new wiring** — not a reimplementation. The seven Claude Code `PreToolUse`/`Stop` wirings collapse to **six** on Codex because Claude Code's two separate file-mutation matchers (`Edit`, `Write`, both wired to `enforce-path-c-delegation.py`) map onto Codex's single `apply_patch` tool, so those two wirings merge into one `apply_patch` hook. (Architecture spec: [docs/superpowers/specs/2026-06-08-codex-dual-target-design.md](superpowers/specs/2026-06-08-codex-dual-target-design.md).)

### `hooks/_run.sh` — path-agnostic launcher

Every `.codex/config.toml` hook command is `["hooks/_run.sh", "<script>.py"]`, never an absolute or `${CLAUDE_PLUGIN_ROOT}` path, so the committed manifest carries no host-specific paths and stays portable across operator clones. `hooks/_run.sh` self-resolves the plugin root at run time (sourcing `scripts/_resolve-plugin-root.sh` relative to its own location when `CLAUDE_PLUGIN_ROOT` is unset — the same var-independent anchor the Boot blocks use) and `exec`s the named hook under it, forwarding stdin and propagating the hook's exit code so the `PreToolUse` block contract (exit 2 = block) is intact.

### Hook trust (dogfood)

Codex keys hook trust to the script's **hash** and revokes it whenever a wired script is edited. Two consequences:

- **Dogfood operators** run a one-time `/hooks` re-trust after a `git pull` lands new hook code.
- **Automation transports** (`fullsend`/`campaign` via `codex exec`) pass `--dangerously-bypass-hook-trust` so they run unattended without a persisted-trust prompt.

Surfacing the Codex trust/install state in `/pipeline:doctor` is a Leg 6 follow-up, **not** part of this leg.

### Parity guard

`tests/test-codex-hook-parity.sh` is the linchpin: it parses both manifests, normalizes the `Edit`/`Write` → `apply_patch` collapse, and asserts the two normalized sets of `(event, matcher, script-basename)` tuples are equal — so the two harnesses' enforcement cannot silently diverge.

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
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The snippet locates the resolver via a var-independent cache-glob anchor rather than the old chicken-and-egg `${CLAUDE_PLUGIN_ROOT:-.}/scripts/...` form — which silently no-op'd when `CLAUDE_PLUGIN_ROOT` was unset because it collapsed to a non-existent `./scripts/...` in the consumer cwd (#810). It globs the dogfood `claude-pipeline-local` cache FIRST and falls back to the published `claude-pipeline` cache (#878), so on a dogfood host the very first resolver sourced is the live one, not a stale published copy; consumer hosts have no local cache and the published glob fires. The glob only LOCATES the resolver; sourcing it then re-derives the authoritative root (dogfood `claude-pipeline-local` tiebreak, active-project mode, highest-semver scan), so consumers and dogfood operators converge on the same root as before.

Why every skill needs it: `CLAUDE_PLUGIN_ROOT` only lives for the Bash tool's subshell. Each subsequent Bash tool call spawns a fresh subshell with no inherited env — so the orchestrator's session-start export does not propagate. Without the in-skill resolver, `bash "${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh"` collapses to `bash "/scripts/foo.sh"` or `bash "./scripts/foo.sh"`, 404'ing the plugin helper. The resolver is idempotent: a no-op when `CLAUDE_PLUGIN_ROOT` is already a valid path.

Two contract tests enforce this invariant:

- `tests/test-skills-source-resolver.sh` — line-positional: every consumer-facing `SKILL.md` MUST source the resolver in its first 30 lines.
- `tests/test-skill-bash-blocks-self-resolve.sh` — usage-anchored: every `SKILL.md` that invokes a plugin script via `bash ${CLAUDE_PLUGIN_ROOT}/...` or `python3 ${CLAUDE_PLUGIN_ROOT}/...` anywhere in its body MUST also have the Boot resolver. Catches the regression where a skill adds a new plugin-script invocation but forgets the Boot block.

Adding a new consumer-facing skill? Copy the canonical snippet verbatim from `skills/create-issues/SKILL.md` into your `## Boot` block, then add the new skill to the `SKILLS` arrays in both tests. A third test, `tests/test-skill-boot-snippet-anchor.sh`, pins the cache-glob anchor shape (no chicken-and-egg `${CLAUDE_PLUGIN_ROOT:-.}` form) across all `SKILL.md` Boot blocks.

### CLAUDE_PLUGIN_ROOT staleness — three distinct failure modes

A `CLAUDE_PLUGIN_ROOT` pointing at a stale/orphaned cache version (e.g. an old
`.../cache/claude-pipeline/pipeline/0.9.0` instead of the live dogfood
`claude-pipeline-local/...`) has two unrelated causes — diagnose before "fixing":

- **Inherited launch-time export (the common case).** The value is bound once at
  process launch; a stale value is usually an export that existed in the
  environment when `claude` started, NOT `claude` resolving wrong. A same-shell
  `/exit`+restart can keep re-inheriting it. **Disambiguate with the fresh-shell
  test:** open a brand-new shell → `echo $CLAUDE_PLUGIN_ROOT` (confirm empty) →
  launch `claude` → check again inside. Empty/correct ⇒ inherited-export (already
  fixed by the new launch; the current session stays stale until it dies — move
  work to the fresh session). Still stale ⇒ THEN it is a real resolver/install
  bug. tmux is a red herring unless the var shows in `tmux show-environment [-g]`.

- **Audits that grep `$CLAUDE_PLUGIN_ROOT/...` read the stale copy.** For drift
  audits (e.g. `doctor.sh` LABEL_TABLE, `skills/*/SKILL.md`, `tests/`), read the
  **repo-rooted** copy (`${PIPELINE_PROJECT_ROOT}/<file>` — the working tree),
  NOT `${CLAUDE_PLUGIN_ROOT}/<file>`. `_resolve-plugin-root.sh` has resolved to a
  much older cached version mid-audit, producing false "N rows missing" findings.
  The `${CLAUDE_PLUGIN_ROOT}` path IS correct for *runtime script invocation*
  (the harness resolves it), but for human reading / drift detection, prefer the
  repo tree.

- **Worktree-subagent `projectPath` miss (#878).** Distinct from the two above:
  this is the resolver picking the stale *published* cache because the
  default-mode dogfood tie-break missed. Execute/eval subagents `cd` into a
  worktree (`<root>/.claude/worktrees/wt-<N>-<slug>`), but the local-marketplace
  install's `projectPath` is the MAIN repo, so a raw worktree `$PWD` never
  matched → fall-through to the highest published cache version (silently running
  pre-merge code in every worktree subagent). `_resolve-plugin-root.sh` now
  normalizes `$PWD` up to the enclosing main-repo root (path-strip at
  `/.claude/worktrees/`, `git rev-parse --git-common-dir` fallback) before
  matching `projectPath`, and exports the matched entry's `projectPath` (the live
  working tree) rather than its `installPath` (a stale cache copy on this host,
  NOT the symlink earlier docs claimed). Regression guard:
  `tests/test-resolve-plugin-root-local-marketplace.sh` (Cases 6–7). Consumer
  hosts have no `claude-pipeline-local` install and fall through unaffected.

## Doctor

`/pipeline:doctor` is a non-mutating validator consumers run after install. It audits `pipeline.config`, `gh` auth, plugin registration, the pipeline-stage labels on the GitHub repo, residual subtree artifacts, and the base branch's local presence + remote tracking — emitting structured `CHECK: <name> status=<pass|fail|warn> detail=<msg>` lines and a final summary table. Non-zero exit signals any `fail`. The `--fix labels` flag is the one write path: it seeds the canonical pipeline labels via `gh label create --force` (idempotent upsert) and honors `PIPELINE_LABELS_*` overrides. Entrypoint: `scripts/doctor.sh`. Skill: `skills/doctor/SKILL.md`.
