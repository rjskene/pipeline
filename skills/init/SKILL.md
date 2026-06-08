---
name: init
description: Bootstrap the pipeline plugin into a fresh (non-subtree) project — preflight dependency checks, interactive pipeline.config generation, .gitignore, label seeding, and a doctor audit tail. The greenfield counterpart to migrate-from-subtree.sh. Usage: /pipeline:init
disable-model-invocation: false
allowed-tools: Bash, Read
---

# Pipeline Init

Stand up the pipeline in a brand-new repository that never had the retired
subtree installer. This is the inverse of `migrate-from-subtree.sh`: migrate
retires a legacy install, init creates a fresh one.

## Boot

Init runs *before* `pipeline.config` exists, so source it tolerantly — its
absence is the normal first-run state, not an error:

```bash
source ./pipeline.config 2>/dev/null || true
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline-local/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

## Platform

Skills use Claude Code tool names; on Codex see [references/codex-tools.md](../references/codex-tools.md) for equivalents.

## What it does

Init composes existing primitives rather than reimplementing them. The backing
script `scripts/init.sh` runs five phases:

1. **Preflight** — checks `gh`, `jq`, `bash` (≥4) and `tmux`, emitting one
   `PREFLIGHT: <dep> status=<pass|fail|warn>` line each. `gh`/`jq`/`bash` are
   hard deps (fail-fast with a platform-appropriate install hint *before* any
   config is written); `tmux` and the Windows "jq on Windows PATH but not bash
   PATH" probe are advisory warns.
2. **Config** — detects `PIPELINE_REPO` (`gh repo view --json nameWithOwner`)
   and `PIPELINE_BASE_BRANCH` (`defaultBranchRef`), asks a small set of
   questions (base branch, test/typecheck/install commands, has-tests?,
   has-CI?), and writes `pipeline.config` with sane defaults for everything
   else. Answering "no tests" writes no-op `PIPELINE_TEST_CMD="true"` /
   `PIPELINE_TYPECHECK_CMD="true"`; answering "no CI" writes
   `PIPELINE_CI_CHECK_ENABLED=""`. Refuses to clobber an existing config
   without `--force`.
3. **Gitignore** — appends `pipeline.config` to `.gitignore` (host-specific;
   idempotent).
4. **Labels** — seeds the canonical GitHub labels via `doctor.sh --fix labels`.
5. **Doctor** — runs the read-only `doctor.sh` audit so init ends in a known
   state.

## Steps

Run the backing script from the project root. It is interactive by default;
the prompts collect the small required answer set.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"
```

To preview dependency readiness without writing anything:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" --preflight-only
```

To regenerate `pipeline.config` over an existing one, pass `--force`.

After init reports `bootstrap complete`, run `/pipeline:status` to start the
workflow.
