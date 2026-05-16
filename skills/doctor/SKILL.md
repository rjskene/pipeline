---
name: doctor
description: Validate consumer install state — read-only audit of pipeline.config, gh auth, GitHub labels, plugin registration, residual subtree artifacts, and base branch. `--fix labels` seeds the canonical pipeline labels idempotently. Usage: /pipeline:doctor [--fix labels]
disable-model-invocation: false
allowed-tools: Bash, Read
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
```

# Doctor

Run the doctor script with the user-supplied flags (forward `$@` verbatim so both `/pipeline:doctor` and `/pipeline:doctor --fix labels` work):

```bash
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" "$@"
```

Report the full stdout (CHECK lines + summary table) to the user. If the exit code was non-zero, finish with "One or more checks failed — see the summary above." If zero, finish with "All checks passed."

## What it checks

- `gh_installed` — `gh` CLI is on `PATH`.
- `pipeline_config` — `pipeline.config` exists at the project root and `PIPELINE_REPO` is non-empty.
- `gh_auth` — `gh auth status` succeeds.
- `gh_repo_reachable` — `gh repo view $PIPELINE_REPO` succeeds.
- `labels_exist` — all 10 pipeline labels are present on the GitHub repo (with `PIPELINE_LABELS_*` overrides honored).
- `plugin_loaded` — `claude plugin list` includes `claude-pipeline` (warn if the `claude` CLI is not on `PATH`).
- `no_residual_subtree` — no `.claude-pipeline/` directory or `.claude/skills/*/.pipeline-managed` markers left over from the retired subtree installer.
- `base_branch_local` — local branch named `$PIPELINE_BASE_BRANCH` exists (warn if it has no upstream).

## The `--fix labels` action

`/pipeline:doctor --fix labels` is the one mutating path. It seeds the 10 canonical pipeline labels on `$PIPELINE_REPO` via `gh label create --force`, which is an idempotent upsert — safe to re-run as many times as you like. The four configurable label rows (`excluded`, `later`, `human`, `brainstorm`) honor `PIPELINE_LABELS_*` overrides from `pipeline.config`.
