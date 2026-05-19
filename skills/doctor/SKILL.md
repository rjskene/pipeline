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

- `gh_installed` — `gh` CLI is on `PATH` AND `gh version` reports major >= 2. The 2.0 floor is required for `--json baseRefName` and related JSON flags that the pipeline depends on; the check parses `gh version`'s first line, extracts the `MAJOR.MINOR.PATCH` token, and fails with an actionable detail (`gh version <X.Y.Z> below the 2.0 floor required for --json baseRefName; upgrade via your package manager`) when major < 2. Pre-2.0 gh silently degrades at runtime — the doctor surfaces this at install/audit time.
- `pipeline_config` — `pipeline.config` exists at the project root and `PIPELINE_REPO` is non-empty.
- `gh_auth` — `gh auth status` succeeds.
- `gh_repo_reachable` — `gh repo view $PIPELINE_REPO` succeeds.
- `labels_exist` — all 10 pipeline labels are present on the GitHub repo (with `PIPELINE_LABELS_*` overrides honored).
- `plugin_loaded` — `claude plugin list` includes `claude-pipeline` (warn if the `claude` CLI is not on `PATH`).
- `no_residual_subtree` — no `.claude-pipeline/` directory or `.claude/skills/*/.pipeline-managed` markers left over from the retired subtree installer. Remediation companion: `scripts/migrate-from-subtree.sh` (recent versions also detect unmarkered duplicates by basename-matching consumer `.claude/skills/<name>/` and `.claude/agents/<name>.md` against the plugin's shipped content; supports `--dry-run` / `--assume-yes` / `--assume-no`).
- `claude_md_residual` — delegates to scripts/migration-cleanup-claudemd.sh; surfaces legacy pipeline section headers (Pipeline, Claude Pipeline, Worktrees, Pipeline Setup), legacy .claude-pipeline/ paths, dangling .claude/scripts/*.sh or .claude/hooks/*.py refs, and unprefixed slash commands. Warn-not-fail. Prevention: re-run `bash scripts/migrate-from-subtree.sh --keep-referenced` to preserve any `.claude/scripts/` or `.claude/hooks/` file that is still referenced from `CLAUDE.md` or other tracked surfaces — the flag turns the default advisory NOTE block into protection.
- `settings_residual` — scans .claude/settings.json for pipeline-owned hook entries and annotates each with a capability-impact note (sourced from scripts/_advisory-text.sh). Warns "jq required" if jq is missing. Warn-not-fail otherwise.
- `skill_files_residual` — enumerates files under consumer .claude/{skills,hooks,scripts,agents}/ whose basename collides with a plugin-shipped file, distinguishing duplicates from consumer-owned. Critical FAIL if any duplicate contains a hardcoded <owner>/<repo> reference that does not match $PIPELINE_REPO (stale legacy install). Now uses **relative-path comparison** (`skills/<name>/SKILL.md`, `scripts/<name>.py`, etc.) instead of basename-only, so consumer-authored skills like `skills/todo/SKILL.md` are correctly preserved even though the plugin ships `SKILL.md` files at other paths. Plugin files ending in `.template` (e.g. `scripts/spawn-claude.sh.template`) imply the rendered consumer path (consumer's `scripts/spawn-claude.sh` under `.claude/`) is `consumer-required` — load-bearing for the plugin's own skills to function — and is reported in a separate "Required — rendered from plugin templates" section rather than as a duplicate. (Interim correctness while #215 resolves the plugin-script delivery model; the `.template` branch becomes deletable once #215 lands.)
- `consumer_drift` — per-file drift classification for consumer `.claude/{scripts,hooks,agents}/` (see `## consumer_drift check` below).
- `preservation_refs` — for every consumer `.claude/{scripts,hooks}/` file with a plugin-shipped counterpart, lists each reference holding it in place and emits a `DELETE` / `KEEP` verdict (see `## preservation_refs check` below).
- `base_branch_local` — local branch named `$PIPELINE_BASE_BRANCH` exists (warn if it has no upstream).
- `base_branch_enforcement` — defense-in-depth audit (#295) for the `enforce-base-branch.py` PreToolUse hook. **Pass** when the hook file exists at `${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py` AND at least one PreToolUse Bash matcher (in the plugin manifest OR in the consumer's `.claude/settings.json`) invokes it. **Fail** in two cases: (a) hook file absent from disk (detail mentions `enforce-base-branch.py not present on disk`), (b) hook file present but unregistered — no PreToolUse Bash matcher references it (detail mentions `exists but no PreToolUse Bash matcher invokes it`). The detection scans both surfaces via `jq -r '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command'` and pattern-matches the basename, so manifest variations (`python3 ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py`, `python3 .claude/hooks/enforce-base-branch.py`, absolute paths, etc.) all resolve correctly.

The shared `scripts/_advisory-text.sh` helper is the single source of truth for capability-impact annotation copy surfaced by `settings_residual` — the same helper is sourced by `migrate-from-subtree.sh`, so the wording in doctor's warnings matches the wording in the migration tool's advisories.

## claude_plugin_root check

Validates that `CLAUDE_PLUGIN_ROOT` resolves to a real plugin install directory. The check captures a pre-resolve snapshot of the env var so it can distinguish four states:

| Env state | Path valid? | Status | Rationale |
|-----------|-------------|--------|-----------|
| Set in env | Yes | `pass` | Operator opted in to a specific plugin version; doctor stays out of the way. |
| Empty | Self-resolution from `~/.claude/plugins/cache/claude-pipeline/pipeline/<latest>/` succeeded | `pass` | env empty + self-resolved from the plugin cache IS the recommended path — it picks the highest-version directory automatically and survives upgrades. Surfacing `warn` here misled v0.7.1 consumers into hardcoding `CLAUDE_PLUGIN_ROOT` and pinning themselves to a stale version. |
| Set in env | No (path missing or not a directory) | `warn` | Likely a stale config — the operator pinned a version path that no longer exists after a plugin upgrade. Either unset the env var (recommended) or update it. |
| Empty | No plugin cache present | `fail` | The plugin isn't installed. Run `/plugin install pipeline@claude-pipeline`. |

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
- Any **A / B / C / E** row whose basename is in `LOAD_BEARING_HOOKS` → `fail` (#295: load-bearing escalation). The `LOAD_BEARING_HOOKS` array in `scripts/doctor.sh` names hooks the pipeline depends on for defense-in-depth — currently `enforce-base-branch.py`, `enforce-path-c-delegation.py`, and `block_deletions.py`. A stale local copy of any of these silently defeats the guardrail, so drift on those basenames promotes from warn to fail. The detail line names the affected basenames (`<n> load-bearing hook(s) drifted (<csv>) — defense-in-depth at risk`). Add to the list when a new hook becomes load-bearing.
- Any other **A / B / C / E** row → `warn` (drift exists but not breaking).
- Only **D / F** rows (or no rows) → `pass`.

**Worked example.** On a real consumer install (`rjskene/example-consumer`) the manual classification surfaced ~20 preserved files: 7 × A (safe to delete), 4 × B (one of which was a `B.bug` because `enforce-path-c-delegation.py` hardcoded the wrong `PIPELINE_REPO`), 1 × C (plugin had dropped a `--runs` mode), 6 × D (dogfood-only hooks), 2 × E (subtree-drift scripts), with the rest F (project-specific autoresearch hooks). ~9 of 20 were safely deletable; 1 was an active bug masked by silent preservation.

This check is intentionally **textual-diff-only** — no behavioral comparison. Interactive remediation (`--fix drift`) is out of scope; surface findings via the summary table and let humans decide.

## preservation_refs check

`consumer_drift` flags **drift** of duplicates; `preservation_refs` answers a different question: **why is each duplicate still here, and should the consumer delete it?** For every consumer `.claude/{scripts,hooks}/` file whose basename collides with a plugin-shipped file, the check delegates to `scripts/scan-preservation-refs.sh` (the same helper `migrate-from-subtree.sh --keep-referenced` uses) and emits one per-file block.

Worked example:

```
.claude/hooks/enforce-path-c-delegation.py
  References:
    - .claude/settings.json:29  → live hook entry in .claude/settings.json; deletion breaks the hook chain (active-wiring)
    - .claude/settings.json:38  → live hook entry in .claude/settings.json; deletion breaks the hook chain (active-wiring)
  Verdict: KEEP — active wiring — rewire settings then delete
```

**Reference-source buckets** (six total, classified per hit; copy from `scripts/_advisory-text.sh::advisory_for_ref_source`):

| Bucket | Definition | Verdict mapping |
|--------|-----------|-----------------|
| `active-wiring`      | Reference in `.claude/settings.json`; the file is wired into a live hook chain. | KEEP |
| `falls-away`         | Reference in `.claude/skills/<name>/SKILL.md` AND `<name>` is plugin-shipped (the migration removes the skill, so the ref disappears). | DELETE (when this is the only kind of holding ref) |
| `consumer-skill-ref` | Reference in `.claude/skills/<name>/SKILL.md` AND `<name>` is consumer-authored (the migration does NOT remove the skill). | KEEP |
| `self-only`          | Reference is inside the file itself (a usage string or docstring); no external consumer. | DELETE (when this is the only kind of holding ref) |
| `fork`               | Reference in `.claude/settings.json` AND the file's `consumer_drift` bucket is `C` (consumer maintains a divergent copy). | KEEP |
| `doc-ref`            | Reference in any other `.md` / `.txt` source — `CLAUDE.md`, `README.md`, `dev/audits/*.md`, etc. | KEEP (resolve manually post-migration) |

**Verdict rule.**
- **DELETE** when every reference is in `{self-only, falls-away}` OR no references found.
- **KEEP** when at least one reference is in `{active-wiring, fork, consumer-skill-ref, doc-ref}`. An inline hint after the verdict conveys the dominant classification — decorative, not structured.

**Doctor stays read-only.** No `--fix preservation-refs` mode. Acting on the report — deleting `DELETE` rows, rewiring `settings.json` then deleting on `KEEP/active-wiring` rows — is a human (or downstream agent) decision.

**Status mapping.** `preservation_refs` records `pass` when zero files are enumerated OR every verdict is `DELETE`. It records `warn` only when at least one verdict is `KEEP` — i.e. there is something the consumer might need to act on. The check never escalates to `fail`; the only fail-grade signal in this domain is `consumer_drift::B.bug`.

**Cache + plugin-skill match.** `scan-preservation-refs.sh` calls `diff-consumer-files.sh` exactly once at start and caches the per-path bucket so settings.json hits resolve to `active-wiring` vs `fork` without re-running the classifier. The `falls-away` vs `consumer-skill-ref` distinction requires `${CLAUDE_PLUGIN_ROOT}/skills/<name>/` to exist (basename match against the plugin's shipped skill set). When `CLAUDE_PLUGIN_ROOT` is unresolved, every SKILL.md ref defaults to `consumer-skill-ref` — conservatively correct, but the report will under-report safe-to-delete cases.

## Mutating actions

### `--fix labels`

`/pipeline:doctor --fix labels` seeds the 10 canonical pipeline labels on `$PIPELINE_REPO` via `gh label create --force`, which is an idempotent upsert — safe to re-run as many times as you like. The four configurable label rows (`excluded`, `later`, `human`, `brainstorm`) honor `PIPELINE_LABELS_*` overrides from `pipeline.config`.

### `--fix residual`

`/pipeline:doctor --fix residual` is an interactive remediation flag. It runs the three residual checks (`claude_md_residual`, `settings_residual`, `skill_files_residual`) and, for each finding, presents a `y/N` prompt before taking any action. Set `DOCTOR_FIX_NONINTERACTIVE=1` to auto-skip prompts (everything defaults to No) — useful for CI smoke runs that want to surface findings without mutating state.

For `settings_residual`, the actual patching of `.claude/settings.json` is delegated to `migrate-from-subtree.sh --patch settings`, which performs an in-place jq-driven rewrite (with a `.bak` backup; collision suffix is ISO timestamp) so both surfaces share the same JSON-rewrite logic. The flag honors `--dry-run`, `--assume-yes`, and `--assume-no`. For `claude_md_residual`, doctor surfaces the report file produced by `migration-cleanup-claudemd.sh` and does NOT edit `CLAUDE.md` directly — `CLAUDE.md` is user-authored prose and any cleanup is a human decision informed by the report.

Consumer-required paths (rendered from plugin `scripts/*.template` / `hooks/*.template`) are **never** proposed for deletion by `--fix residual` — they are load-bearing for the plugin's own skills. After #215 lands, the `.template`-branch of this exclusion becomes obsolete and may be removed.
