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

```
gh auth → plugin install → pipeline.config → labels → settings wiring → allow-list → CLAUDE.md residual → base branch
```

Run the doctor script with the user-supplied flags (forward `$@` verbatim so both `/pipeline:doctor` and `/pipeline:doctor --fix labels` work):

```bash
[ -f "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" ] \
  && source "${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh" 2>/dev/null || true
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" "$@"
```

Report the full stdout (CHECK lines + summary table) to the user. If the exit code was non-zero, finish with "One or more checks failed — see the summary above." If zero, finish with "All checks passed."

## Checks

State table — each row names a check, the trigger that fires it, the worst-case severity, and the remediation. Complex checks have their own sub-section below with the full state machine.

| Check | Trigger / what it audits | Severity | Remediation |
|-------|-------------------------|----------|-------------|
| `gh_installed` | `gh` on PATH AND major ≥ 2 (needed for `--json baseRefName`) | FAIL | Upgrade `gh` |
| `gh_auth` | `gh auth status` succeeds | FAIL | `gh auth login` |
| `gh_repo_reachable` | `gh repo view $PIPELINE_REPO` succeeds | FAIL | Check perms / `PIPELINE_REPO` |
| `pipeline_config` | `pipeline.config` exists at project root + `PIPELINE_REPO` set | FAIL | Copy `pipeline.config.example` and edit |
| `claude_plugin_root` | `CLAUDE_PLUGIN_ROOT` resolves to a real plugin install (4 env-states) | varies | See sub-section below |
| `plugin_loaded` | `claude plugin list` includes `claude-pipeline` | WARN if `claude` not on PATH | `/plugin install pipeline@claude-pipeline` |
| `labels_exist` | All 10 pipeline labels present (honors `PIPELINE_LABELS_*` overrides) | FAIL | `--fix labels` (idempotent upsert) |
| `no_residual_subtree` | No `.claude-pipeline/` or `.pipeline-managed` markers from the retired subtree installer | FAIL | `scripts/migrate-from-subtree.sh` |
| `claude_md_residual` | Legacy section headers / `.claude-pipeline/` paths / dangling `.claude/{scripts,hooks,skills}/` refs / unprefixed slash commands (delegates to `migration-cleanup-claudemd.sh`; on-disk path verification) | WARN | `migrate-from-subtree.sh --keep-referenced` |
| `settings_residual` | Pipeline-owned hook entries in `.claude/settings.json`; capability-impact annotation from `_advisory-text.sh` | WARN (jq required) | `--fix residual` (interactive) |
| `skill_files_residual` | Consumer `.claude/{skills,hooks,scripts,agents}/` files colliding with plugin-shipped (relative-path compare); `*.template` renders reported separately as `consumer-required` | FAIL when stale `<owner>/<repo>` ≠ `$PIPELINE_REPO` | Delete duplicate or fix legacy install |
| `consumer_drift` | Per-file drift classification (6 buckets) | varies — see sub-section | Per-bucket |
| `container_assets_unwired` | Undeclared `compose.<mode>.{yml,yaml}` with marker-env triangle | varies — see sub-section | Declare in `PIPELINE_EVAL_CONTAINERS` or annotate `# pipeline:manual-only` |
| `preservation_refs` | Why each duplicate is still here — six reference-source buckets; KEEP/DELETE verdict | WARN when any KEEP; never FAIL | Rewire then delete on KEEP |
| `base_branch_local` | Local branch `$PIPELINE_BASE_BRANCH` exists | WARN if no upstream | `git fetch && git checkout -b <base> origin/<base>` |
| `base_branch_enforcement` | `enforce-base-branch.py` exists AND ≥1 PreToolUse Bash matcher invokes it. Defense-in-depth #295 | FAIL if absent or unregistered | Restore plugin manifest or re-add matcher |
| `container_skills_validity` | `PIPELINE_CONTAINER_SKILLS` lists only canonical skill names (#321) | WARN; never FAIL | Fix typo in `pipeline.config` |

The shared `scripts/_advisory-text.sh` helper is the single source of truth for capability-impact annotation copy surfaced by `settings_residual` — also sourced by `migrate-from-subtree.sh` so the wording matches.

## claude_plugin_root check

Validates `CLAUDE_PLUGIN_ROOT` resolves to a real plugin install. Captures a pre-resolve env snapshot to distinguish four states:

| Env state | Path valid? | Status | Rationale |
|-----------|-------------|--------|-----------|
| Set in env | Yes | `pass` | Operator opted in to a specific plugin version; doctor stays out of the way. |
| Empty | Self-resolution from `~/.claude/plugins/cache/claude-pipeline/pipeline/<latest>/` succeeded | `pass` | env empty + self-resolved from the plugin cache IS the recommended path — it picks the highest-version directory automatically and survives upgrades. Surfacing `warn` here misled v0.7.1 consumers into hardcoding `CLAUDE_PLUGIN_ROOT`. |
| Set in env | No (path missing or not a directory) | `warn` | Likely stale config — operator pinned a version that no longer exists after a plugin upgrade. Unset (recommended) or update. |
| Empty | No plugin cache present | `fail` | Plugin isn't installed. Run `/plugin install pipeline@claude-pipeline`. |

## consumer_drift check

Per-file drift classification on top of `skill_files_residual`'s duplicate presence. Delegates to `scripts/diff-consumer-files.sh` (stateless, also reused by `migrate-from-subtree.sh`); assigns one of six buckets:

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
- **B.bug** row → `fail` (active bug — stale local overrides correct plugin behavior).
- **A / B / C / E** row whose basename is in `LOAD_BEARING_HOOKS` → `fail` (#295). The array in `scripts/doctor.sh` (currently `enforce-base-branch.py`, `enforce-path-c-delegation.py`, `block_deletions.py`) names hooks the pipeline depends on for defense-in-depth; stale local copies silently defeat the guardrail. Detail line: `<n> load-bearing hook(s) drifted (<csv>) — defense-in-depth at risk`.
- Other **A / B / C / E** row → `warn` (drift exists but not breaking).
- Only **D / F** rows (or no rows) → `pass`.

Textual-diff-only; no behavioral comparison. `--fix drift` is out of scope.

## container_assets_unwired check

Detects a class #218 left invisible: **the consumer repo has container assets but they're not declared in `PIPELINE_EVAL_CONTAINERS`**. When intent-evidence is present (a `.claude/hooks/*.py` reads an env var the compose file sets), the dispatch path is broken — `spawn-claude.sh` never invokes `docker compose run`, the marker never gets set, dependent hooks silently degrade. Helper: `scripts/check-container-assets.sh`.

**Marker-env triangle (all three required for FAIL):**

1. A `compose.<mode>.yml` or `compose.<mode>.yaml` file at the project root.
2. The compose file sets a non-`PIPELINE_*` env var via `services.*.environment:`.
3. A `.claude/hooks/*.py` file reads that exact env var via a quoted-literal string (`'MARKER'` or `"MARKER"`).

**Verdict matrix:**

| Signal | Verdict |
|--------|---------|
| Mode declared in `PIPELINE_EVAL_CONTAINERS` | **PASS** |
| First 5 lines of compose contain `# pipeline:manual-only` | **PASS** (explicit opt-out) |
| Undeclared compose, no marker-reader hook found | **WARN** (could be manual-use) |
| Undeclared compose, full triangle (compose sets MARKER, hook reads MARKER) | **FAIL** (intent-evidence — undeclared dispatch breaks a wired hook) |
| Undeclared compose, marker set but hook reads a DIFFERENT marker | **WARN** (no overlap, no triangle) |
| YAML environment block unparseable (yq + awk fallback both fail) | **WARN** with `note=yaml-parse-skipped` — never escalate to FAIL without confirmed marker-set evidence |

**Implementation notes.**
- **YAML parsing.** `yq` first (handles anchors / merge keys); falls back to a flat-`environment:`-block awk scanner. When neither resolves, emit `note=yaml-parse-skipped` and stay at WARN — invariant: **never escalate to FAIL without confirmed evidence**.
- **Marker filter.** Env-var names matching `PIPELINE_*` are filtered out before the marker-reader scan (plugin-internal noise).
- **Hook-reader detection.** `grep -E "['\"]<MARKER>['\"]"` against `.claude/hooks/*.py`. False-positives suppressed by the triangle constraint.
- **Suggested snippet emission.** On FAIL, the helper emits a copy-paste `pipeline.config` snippet from discovered values (compose filename, first `services.<name>:` entry, sibling `Dockerfile.<mode>` / `.env.<mode>`). Mode-name suffix: `tr '[:lower:]-' '[:upper:]_'`.
- **Opt-out window.** `# pipeline:manual-only` must appear in the first 5 lines.
- **Precedent.** Same escalation pattern as `consumer_drift::LOAD_BEARING_HOOKS` applied to the dispatch-asset surface.
- **Out of scope.** `docker-compose.yml` without `.<mode>` infix — file a follow-up. Misconfigured `PIPELINE_EVAL_CONTAINER_<MODE>_COMPOSE_FILE` paths — `pipeline_config` territory.

## preservation_refs check

Answers "why is each duplicate still here, and should the consumer delete it?" Per consumer `.claude/{scripts,hooks}/` file with a plugin-shipped collision, delegates to `scripts/scan-preservation-refs.sh` (also used by `migrate-from-subtree.sh --keep-referenced`); emits one per-file block with references + verdict (KEEP/DELETE) + advisory text.

**Reference-source buckets** (six total; copy from `scripts/_advisory-text.sh::advisory_for_ref_source`):

| Bucket | Definition | Verdict mapping |
|--------|-----------|-----------------|
| `active-wiring`      | Reference in `.claude/settings.json`; file is wired into a live hook chain. | KEEP |
| `falls-away`         | Reference in `.claude/skills/<n>/SKILL.md` AND `<n>` is plugin-shipped (migration removes the skill). | DELETE (when sole holding ref) |
| `consumer-skill-ref` | Reference in `.claude/skills/<n>/SKILL.md` AND `<n>` is consumer-authored (migration does NOT remove the skill). | KEEP |
| `self-only`          | Reference is inside the file itself (usage string or docstring); no external consumer. | DELETE (when sole holding ref) |
| `fork`               | Reference in `.claude/settings.json` AND the file's `consumer_drift` bucket is `C`. | KEEP |
| `doc-ref`            | Reference in any other `.md` / `.txt` — `CLAUDE.md`, `README.md`, `dev/audits/*.md`, etc. | KEEP (resolve manually post-migration) |

**Verdict rule.** DELETE when every reference is in `{self-only, falls-away}` OR no references found. KEEP when at least one reference is in `{active-wiring, fork, consumer-skill-ref, doc-ref}`.

**Status mapping.** `pass` when zero files or every verdict is DELETE; `warn` when any KEEP. Never `fail` — the only fail-grade signal in this domain is `consumer_drift::B.bug`. No `--fix preservation-refs` mode; doctor stays read-only.

**Cache + plugin-skill match.** `scan-preservation-refs.sh` calls `diff-consumer-files.sh` once at start and caches the per-path bucket. The `falls-away` vs `consumer-skill-ref` distinction requires `${CLAUDE_PLUGIN_ROOT}/skills/<n>/` to exist (basename match). When `CLAUDE_PLUGIN_ROOT` is unresolved, every SKILL.md ref defaults to `consumer-skill-ref` — conservatively correct, but under-reports safe-to-delete cases.

## Mutating actions

### `--fix labels`

`/pipeline:doctor --fix labels` seeds the 10 canonical pipeline labels on `$PIPELINE_REPO` via `gh label create --force`, which is an idempotent upsert — safe to re-run. The four configurable label rows (`excluded`, `later`, `human`, `brainstorm`) honor `PIPELINE_LABELS_*` overrides from `pipeline.config`.

### `--fix residual`

Interactive remediation for the three residual checks (`claude_md_residual`, `settings_residual`, `skill_files_residual`); `y/N` prompt per finding. `DOCTOR_FIX_NONINTERACTIVE=1` auto-skips (everything defaults to No) — useful for CI smoke runs.

- `settings_residual` patching is delegated to `migrate-from-subtree.sh --patch settings` (in-place jq rewrite with `.bak` backup; ISO-timestamp collision suffix). Honors `--dry-run`, `--assume-yes`, `--assume-no`.
- `claude_md_residual` only surfaces the report from `migration-cleanup-claudemd.sh`; doctor does NOT edit `CLAUDE.md` directly — it's user-authored prose.
- Consumer-required paths rendered from plugin `scripts/*.template` / `hooks/*.template` are **never** proposed for deletion (load-bearing). The `.template`-branch becomes obsolete once #215 lands.
