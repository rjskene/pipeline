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
- `no_residual_subtree` — no `.claude-pipeline/` directory or `.claude/skills/*/.pipeline-managed` markers left over from the retired subtree installer. Remediation companion: `scripts/migrate-from-subtree.sh` (recent versions also detect unmarkered duplicates by basename-matching consumer `.claude/skills/<name>/` and `.claude/agents/<name>.md` against the plugin's shipped content; supports `--dry-run` / `--assume-yes` / `--assume-no`).
- `claude_md_residual` — delegates to scripts/migration-cleanup-claudemd.sh; surfaces legacy pipeline section headers (Pipeline, Claude Pipeline, Worktrees, Pipeline Setup), legacy .claude-pipeline/ paths, dangling .claude/scripts/*.sh or .claude/hooks/*.py refs, and unprefixed slash commands. Warn-not-fail. Prevention: re-run `bash scripts/migrate-from-subtree.sh --keep-referenced` to preserve any `.claude/scripts/` or `.claude/hooks/` file that is still referenced from `CLAUDE.md` or other tracked surfaces — the flag turns the default advisory NOTE block into protection.
- `settings_residual` — scans .claude/settings.json for pipeline-owned hook entries and annotates each with a capability-impact note (sourced from scripts/_advisory-text.sh). Warns "jq required" if jq is missing. Warn-not-fail otherwise.
- `skill_files_residual` — enumerates files under consumer .claude/{skills,hooks,scripts,agents}/ whose basename collides with a plugin-shipped file, distinguishing duplicates from consumer-owned. Critical FAIL if any duplicate contains a hardcoded <owner>/<repo> reference that does not match $PIPELINE_REPO (stale legacy install).
- `consumer_drift` — per-file drift classification for consumer `.claude/{scripts,hooks,agents}/` (see `## consumer_drift check` below).
- `base_branch_local` — local branch named `$PIPELINE_BASE_BRANCH` exists (warn if it has no upstream).

The shared `scripts/_advisory-text.sh` helper is the single source of truth for capability-impact annotation copy surfaced by `settings_residual` — the same helper is sourced by `migrate-from-subtree.sh`, so the wording in doctor's warnings matches the wording in the migration tool's advisories.

## consumer_drift check

`skill_files_residual` flags **presence** of duplicates; `consumer_drift` adds **per-file drift classification**. For every consumer `.claude/{scripts,hooks,agents}/` file, the check delegates to `scripts/diff-consumer-files.sh` (a stateless helper that's also reusable from `migrate-from-subtree.sh`) and assigns one of six buckets:

| Bucket | Definition | Detection | Action |
|--------|-----------|-----------|--------|
| **A** | Byte-identical to plugin counterpart | `cmp -s` returns equal | `delete-local` |
| **B** | Drifted; plugin strictly more capable | Plugin counterpart sources `pipeline.config` / `_resolve-plugin-root.sh` / `_pipeline_config`; local does not | `delete-local` |
| **B.bug** | Bucket B + hardcoded literal disagrees with runtime config | Extracted `PIPELINE_REPO` / `PIPELINE_WORKTREE_PREFIX` / `PIPELINE_TMUX_SESSION` literal ≠ value from `pipeline.config` | `fail-active-bug` (escalates check to FAIL) |
| **C** | Plugin removed a feature the local copy still uses | Any function name or `--flag` token in local missing from plugin counterpart (`grep -qF`) | `leave-flag-as-fork` |
| **D** | Plugin-author dogfood, not shipped | Basename only present under `${CLAUDE_PLUGIN_ROOT}/.claude/`, never under `scripts/`/`hooks/`/`agents/` | `no-op` |
| **E** | Retired tooling | Basename on hardcoded deny-list (`RETIRED_BASENAMES` in `diff-consumer-files.sh`) | `delete-local` |
| **F** | Genuine consumer-owned | No plugin counterpart anywhere | `no-op` |

**B-vs-C tie-break.** If both heuristics fire, C wins — preserves consumer functionality when uncertain.

**Check verdict.**
- Any **B.bug** row → `fail` (active bug — stale local overrides correct plugin behavior).
- Any **A / B / C / E** row → `warn` (drift exists but not breaking).
- Only **D / F** rows (or no rows) → `pass`.

**Worked example.** On a real consumer install (`rjskene/bomon-train`) the manual classification surfaced ~20 preserved files: 7 × A (safe to delete), 4 × B (one of which was a `B.bug` because `enforce-path-c-delegation.py` hardcoded the wrong `PIPELINE_REPO`), 1 × C (plugin had dropped a `--runs` mode), 6 × D (dogfood-only hooks), 2 × E (subtree-drift scripts), with the rest F (project-specific autoresearch hooks). ~9 of 20 were safely deletable; 1 was an active bug masked by silent preservation.

This check is intentionally **textual-diff-only** — no behavioral comparison. Interactive remediation (`--fix drift`) is out of scope; surface findings via the summary table and let humans decide.

## Mutating actions

### `--fix labels`

`/pipeline:doctor --fix labels` seeds the 10 canonical pipeline labels on `$PIPELINE_REPO` via `gh label create --force`, which is an idempotent upsert — safe to re-run as many times as you like. The four configurable label rows (`excluded`, `later`, `human`, `brainstorm`) honor `PIPELINE_LABELS_*` overrides from `pipeline.config`.

### `--fix residual`

`/pipeline:doctor --fix residual` is an interactive remediation flag. It runs the three residual checks (`claude_md_residual`, `settings_residual`, `skill_files_residual`) and, for each finding, presents a `y/N` prompt before taking any action. Set `DOCTOR_FIX_NONINTERACTIVE=1` to auto-skip prompts (everything defaults to No) — useful for CI smoke runs that want to surface findings without mutating state.

For `settings_residual`, the actual patching of `.claude/settings.json` is deferred to `migrate-from-subtree.sh --patch settings` so both surfaces share the same JSON-rewrite logic. For `claude_md_residual`, doctor surfaces the report file produced by `migration-cleanup-claudemd.sh` and does NOT edit `CLAUDE.md` directly — `CLAUDE.md` is user-authored prose and any cleanup is a human decision informed by the report.
