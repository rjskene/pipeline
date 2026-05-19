# Claude Pipeline

## What This Is

Claude Pipeline is a **CI workflow for automating code updates** through GitHub issues. It manages the full lifecycle: issue creation, planning, plan review, execution, and PR evaluation.

## Pipeline vs Superpowers

These are distinct layers:

- **Pipeline** is the outer workflow — it defines *what happens* and *in what order*. Each stage is a slash command that advances an issue through the lifecycle.
- **Superpowers** are inner tools — skills like brainstorming, writing-plans, TDD, and debugging that pipeline stages use internally to do their work well.

Pipeline orchestrates. Superpowers execute.

## Lifecycle Stages

```
create-issues → plan-issue → evaluate-issue-plan → (approve) → execute-issue-plan → evaluate-issue-pr → (merge)
```

| Stage | Pipeline skill | Superpowers used internally |
|-------|---------------|---------------------------|
| Ideation | `/pipeline:create-issues` | `brainstorming` |
| Planning | `/pipeline:plan-issue` | `writing-plans` |
| Plan review | `/pipeline:evaluate-issue-plan` | — |
| Execution | `/pipeline:execute-issue-plan` | `subagent-driven-development` |
| PR review | `/pipeline:evaluate-issue-pr` | `subagent-driven-development` |

For autonomous end-to-end runs across many issues, `/pipeline:fullsend` is the canonical entry point — it chains classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge without intermediate confirmations. The legacy `"full send"` magic-string passed to `/pipeline:run` is preserved as a back-compat delegator.

For pre-prioritization hygiene over the open-issue set, `/pipeline:run --analyze` runs a read-only pass that flags likely duplicates and standalones that fit existing trackers — decision-support only, no mutations. See `skills/run/SKILL.md` analyze mode.

### Dispatch model (hybrid)

Pipeline stages dispatch in one of two ways, keyed off the path label written by `/pipeline:classify-issue`:

- **PATH A** (`docs-only`) — execute-issue-plan and evaluate-issue-pr run inline via `Agent(subagent_type='general-purpose', ...)` from the orchestrator session. No `spawn-claude.sh`, no `claude -p`, no tmux. The worktree is still created by `setup-worktree.sh`; only the agent launch is inline. Routing logic lives in `skills/run/SKILL.md` Step 6 and Step 7.
- **PATH B / PATH C** — execute-issue-plan and evaluate-issue-pr continue to dispatch through `scripts/spawn-claude.sh` (which invokes `claude -p`) and, for multi-issue runs, `scripts/run-queue.sh` + tmux. PATH B uses spawn-claude.sh; PATH C uses spawn-claude.sh. This is unchanged from the previous behavior and remains the indefinite default for B/C until external pressure (deprecation or quota signals on `-p`) forces broader migration.
- **Other stages** (classify-issue, plan-issue, evaluate-issue-plan, create-issues) are already invoked inline as `Agent(...)` from the orchestrator regardless of path; nothing changes for them.

Broader PATH B/C inline migration is intentionally deferred (see issue #80 rationale: subagent context budget, turn budget, permission inheritance, TDD discipline drift, and crash recovery risks are accepted at PATH A scope but not at B/C scope).

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

**Full Send wave model.** When the user invokes `/pipeline:fullsend` (or the back-compat `"full send"` magic-string in `/pipeline:run`, which delegates to the same skill), the orchestrator runs `scripts/plan-waves.sh` against the set of ready issues before dispatching any classify/plan agents. The helper groups issues into ordered waves by priority tier (`priority/P0` > `P1` > `P2` > `P3`), respecting explicit `blocked by #N` / `depends on #N` body annotations and shared-file conflicts inferred from issue bodies. Each wave is dispatched in parallel; subsequent waves wait for the prior wave to finish. Disable with `PIPELINE_FULL_SEND_WAVE_PLANNING_ENABLED=false` to restore the legacy single-blast dispatch.

## Key Handoffs

**Brainstorming → Issues:** The `superpowers:brainstorming` skill produces a design spec. The `/pipeline:create-issues` skill converts that spec into one or more GitHub issues and deletes the spec file — the issues become the source of truth. Brainstorming does NOT hand off to `writing-plans` directly; that happens later inside `/pipeline:plan-issue`.

**Issues → Plans:** Each issue gets its own implementation plan via `/pipeline:plan-issue`, which uses `writing-plans` internally.

**Plans → Execution:** After a plan is reviewed (`/pipeline:evaluate-issue-plan`) and approved (human adds `plan-approved` label), `/pipeline:execute-issue-plan` implements it in an isolated worktree.

## Auto-merge default

When `/pipeline:evaluate-issue-pr` returns Approved on a feature PR, the pipeline auto-squash-merges the PR (with branch delete), flips the issue to `merged`, and closes it — no manual confirmation. The interesting gate is the eval verdict, not the merge button.

**Four greenlight conditions** (all must hold; otherwise the PR is left for manual merge with a `block-*` reason):

1. Latest `## Evaluation` comment contains `**Verdict:** Approved`.
2. Every entry in the PR's `statusCheckRollup` has `conclusion == SUCCESS` (or the rollup is empty for repos with no CI configured).
3. `mergeable == MERGEABLE`.
4. `mergeStateStatus == CLEAN` (not BLOCKED/BEHIND/DIRTY/UNSTABLE).

**Three opt-outs** restore today's stop-before-merge behavior:

- `FULL SEND --manual-merge` (token may appear anywhere in argv — before, between, or after issue numbers).
- `/pipeline:evaluate-issue-pr <N> --manual-merge` for one-off evaluations.
- A `manual-merge` label on the issue, for per-issue control without re-typing the flag.

The implementation lives in `scripts/auto-merge-gate.sh` (helper exposing `auto_merge_should_fire`), the evaluate-issue-pr skill (Step 11), and the run skill (Step 8). **Release-please PRs are out of scope** — they flow through `PIPELINE_RELEASE_PR_AUTO_MERGE` in Step 7b of the run skill, unchanged.

## Observability

**dogfood-only.** `.claude/hooks/log_subagent.py` is a PostToolUse hook that logs every Agent tool invocation. It writes per-agent JSON files to `.claude/logs/subagents/`, a consolidated TSV to `.claude/logs/subagents.log`, and errors to `.claude/logs/subagent-hook-errors.log`. All logs are gitignored and the hook uses fail-open semantics (errors are swallowed so they never block tool use). This hook is registered in this repo's `.claude/settings.json` only; the published `pipeline@claude-pipeline` plugin manifest does NOT register it, so consumer installs produce no `.claude/logs/subagents/` files.

**dogfood-only.** `.claude/logs/tool-use.log` is a tab-separated per-tool-call log (timestamp, tool, session, summary) written by `.claude/hooks/log-tool-use.sh` (PostToolUse `*`). Correlate with `subagents.log` via the `session` field to reconstruct the tool sequence inside each subagent — useful for verifying TDD order (Write test → Bash pytest fail → Write impl → Bash pytest pass). Log rotation is not automated; `cleanup-worktree.sh` copies per-issue logs to the root `.claude/logs/tool-use-issue-<N>.log` on worktree teardown. This hook is registered in this repo's `.claude/settings.json` only; the published `pipeline@claude-pipeline` plugin manifest does NOT register it, so consumer installs produce no `.claude/logs/tool-use.log` files.

`.claude/logs/runs.log` is a tab-separated per-spawn marker written by `spawn-claude.sh` at session launch (one line per spawn). Columns: timestamp, `session=<uuid>`, `issue=<N>`, `path=<A|B|C>`, `skill=<name>`, `worktree=<path>`. The session UUID matches `--session-id` passed to the claude CLI, so it joins 1:1 with `tool-use.log` and `subagents.log` rows for that session. Use `bash ${CLAUDE_PLUGIN_ROOT}/scripts/review-audits.sh [--last N | --path X | --deviations | --issue N | --since DATE]` to inspect runs — the script derives signals (skill sequence vs expected, subagent dispatches, TDD commit pattern) on the fly from the raw substrate, so there's no derived-audit JSON to stale. Log rotation is not automated; at steady state (~50 spawns/week) growth is negligible.

## Branches

- **`staging`** (or whatever `PIPELINE_BASE_BRANCH` is set to in `pipeline.config`) — the base branch for all pipeline work. PRs target this branch. The orchestrator session runs here.
- **`main`** — the release branch. release-please tracks `main` and cuts releases from it; see [Release cadence](#release-cadence-this-repo-only) below.
- **`feature/*`** — feature branches created by `/pipeline:execute-issue-plan` in worktrees, one per issue. Merged back to the base branch via PR.

Base-branch enforcement is defense-in-depth across three layers: (i) eval-time `baseRefName == $PIPELINE_BASE_BRANCH` assertion in `auto-merge-gate.sh` with a TOCTOU re-check immediately before `gh pr merge` (load-bearing zero-data-loss gate, #295); (ii) skill-level quoted `--base "$PIPELINE_BASE_BRANCH"` in `execute-issue-plan` Step 9b at PR creation time; (iii) `enforce-base-branch.py` PreToolUse hook covering both `gh pr create` and `gh pr edit --base` retargets. The hook alone is not sufficient — it has bypassed (#295) when the consumer settings.json layout shadowed the plugin-registered matcher, or when a stale rendered spawn-claude.sh emitted an unnamespaced slash command that never loaded plugin hooks at all (see dev/audits/295-root-cause.md).

### Release cadence (this repo only)

This repo uses a **two-branch model** with [release-please](https://github.com/googleapis/release-please): `staging` is the dev trunk where feature PRs land; `main` is the release branch that release-please tracks.

**How a release happens:**

1. Feature PRs merge to `staging` using Conventional Commits (`feat:`, `fix:`, `chore:`, etc.). CI runs on every push to `staging` and on PRs.
2. When ready to release, open a PR `staging` → `main` and fast-forward or squash-merge it.
3. On every push to `main`, the `release-please` workflow (`.github/workflows/release-please.yml`) opens — or updates — a Release PR titled `chore(main): release X.Y.Z`. The Release PR bumps `version` in `.claude-plugin/plugin.json` and both `metadata.version` and `plugins[0].version` in `.claude-plugin/marketplace.json` (synced via `extra-files` in `release-please-config.json`), and appends to `CHANGELOG.md`.
4. Squash-merge the Release PR. release-please then creates the `vX.Y.Z` git tag and a corresponding GitHub Release automatically.
5. Back-sync to staging happens automatically — the back-sync-release workflow (`.github/workflows/back-sync-release.yml`) merges the release commit onto staging (`--ff-only` when possible; `-X theirs` strategy-option when staging has overlapping work, so main wins on collisions — release-please's version-manifest bumps on main are strictly newer than staging for the files they touch) on every push to `main` matching `chore(main): release …`. On a true delete/modify conflict that `-X theirs` cannot resolve, it opens a draft PR `release-back-sync/<sha>` against staging for human resolution instead of failing the workflow.
6. **Reload the plugin** so subsequent dogfood sessions pick up the new code:
   ```
   /plugin uninstall pipeline@claude-pipeline
   /plugin install   pipeline@claude-pipeline
   ```
   (If installed via a local marketplace pointing at the working tree, no reload is needed — every edit is already live.)

The previous five-step manual ritual (release branch, manual version bumps, hand-written tag, hand-written GitHub Release) is gone — release-please owns version bumps, tags, and the GitHub Release. Back-sync is now fully automated via the back-sync-release workflow; the merge to staging happens without human intervention on the clean path, and only true delete/modify conflicts open a draft fallback PR. The merge strategy is asymmetric between directions: `staging → main` uses `-X ours` (staging is strictly newer in that direction); `main → staging` uses `-X theirs` (main is strictly newer on every file the release commit touched). #205 fixed the regression where #200 had naively used `-X ours` for both directions.

### Dev/prerelease channel

The `Release-As:` footer mechanism for cutting prereleases is preserved — it correctly marks the GitHub Release as a prerelease and applies the `-rc.N` tag suffix via release-please. The dev marketplace (`claude-pipeline-dev`) has been **retired**: opt-in to a new version already lives at the `/plugin install` layer (a stable consumer only picks up a new version when they explicitly run `/plugin uninstall` + `/plugin install`), so the dual-marketplace gate added no real protection beyond what the install action itself provides. Mental model: **if you don't want an RC, don't reinstall.**

1. **Trigger (LOCKED).** To cut an RC, open a `staging → main` PR and merge it with `gh pr merge <N> --squash --body-file <path-to-body-with-Release-As-footer>` where the body file contains a `Release-As: X.Y.Z-rc.1` footer (substitute the target version). **Using the GitHub web squash UI is FORBIDDEN for RC cuts** because it can silently drop commit trailers; `gh pr merge --squash --body-file` (or a non-squash merge) preserves the `Release-As:` footer reliably. release-please reads the footer on the resulting merge commit on `main` and opens an RC Release PR instead of a stable one. Verify post-merge with `git log -1 --pretty=%B main | grep -q "Release-As:"`.
2. **Versioning.** RCs follow SemVer prerelease (`MAJOR.MINOR.PATCH-rc.N`), enabled by `prerelease: true` + `prerelease-type: "rc"` in `release-please-config.json`. One release-please run bumps `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.release-please-manifest.json` atomically via `extra-files`.
3. **Graduation.** Prereleases do NOT auto-graduate. The next normal `staging → main` cut WITHOUT a `Release-As:` footer produces the stable `X.Y.Z` bump. RC and stable are mutually exclusive per `staging → main` PR.
4. **Fallback (Risks).** If `Release-As:` footers fail to trigger in release-please v4 simple mode, the documented fallback is the `autorelease: pre-release` label on the live Release PR. Both satisfy the issue's "either footer or label" requirement; the canonical path is the footer.
5. **Consumer cleanup (one-time).** Anyone who previously installed via the dev channel should run `/plugin uninstall pipeline@claude-pipeline-dev` followed by `/plugin marketplace remove claude-pipeline-dev` to unregister the now-orphaned manifest. The next `/plugin install pipeline@claude-pipeline` picks up the stable channel.

## Doctor

`/pipeline:doctor` is a non-mutating validator consumers run after install. It audits `pipeline.config`, `gh` auth, plugin registration, the pipeline-stage labels on the GitHub repo, residual subtree artifacts, and the base branch's local presence + remote tracking — emitting structured `CHECK: <name> status=<pass|fail|warn> detail=<msg>` lines and a final summary table. Non-zero exit signals any `fail`. The `--fix labels` flag is the one write path: it seeds the canonical pipeline labels via `gh label create --force` (idempotent upsert) and honors `PIPELINE_LABELS_*` overrides. Entrypoint: `scripts/doctor.sh`. Skill: `skills/doctor/SKILL.md`.

## Plugin architecture

Pipeline assets live outside the consumer project. The plugin installs to `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`). Hooks, scripts, and the `tdd-implementer` subagent are registered from the plugin manifest; skills auto-discover from `${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md` and the manifest does not enumerate them. The consumer project's `.claude/` stays clean.

**Consumer-required rendered scripts.** Post-#215/#223, plugin skills invoke worktree/dispatch helpers as `bash ${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh` directly; the consumer .claude/scripts/ mirror has been retired. The doctor's .template-branch in `doctor.sh` is dead code retained for legacy subtree consumers and will be removed in a follow-up.

The consumer project owns exactly one pipeline file: `pipeline.config` at the project root. The plugin reads it via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims at runtime — there is no install-time template rendering anymore, and skill files reference `$PIPELINE_*` as runtime shell variables sourced from `pipeline.config` at session start (per each skill's `## Boot` section).

All slash commands are namespaced under `pipeline:` (`/pipeline:plan-issue`, `/pipeline:run`, …). Unprefixed command names like `plan-issue` are intentionally not registered so the plugin coexists with other plugins that might claim those names.

> Legacy install (`install.sh`, the `.claude-pipeline/` subtree, and the subtree-drift tooling) has been retired. Existing subtree consumers run `scripts/migrate-from-subtree.sh` once and then install the plugin.

Observability hooks (`log-tool-use.sh`, `log_subagent.py`) are dogfood-only and registered via this repo's `.claude/settings.json`; they are not part of the published manifest. See Observability.

**Bash subshells.** `CLAUDE_PLUGIN_ROOT` is not guaranteed to be exported into the Bash tool's subshell — Claude Code does not consistently propagate it. Every consumer-facing skill sources `scripts/_resolve-plugin-root.sh` in its `## Boot` block, which (when the env var is empty) picks the highest-version directory under `~/.claude/plugins/cache/claude-pipeline/pipeline/` and exports it. Doctor's `claude_plugin_root` check surfaces the resolution state across four cases: `pass` (env pre-set + valid dir), `pass` (env empty, self-resolved from the plugin cache), `warn` (env set but path missing/invalid — likely a stale config), `fail` (env empty and no plugin cache exists).

## Namespace discipline

The pipeline writes **nothing** to the consumer project's `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json`. All plugin assets live under `~/.claude/plugins/claude-pipeline/` (read at runtime via `${CLAUDE_PLUGIN_ROOT}`).

**Runtime allow-list (consumer-owned, pipeline may read/write):**
- `.claude/logs/` — observability artifacts (tool-use, subagents, runs).
- `.claude/worktrees/` — pipeline-managed worktree checkouts.

Everything else under consumer `.claude/` is consumer-owned. CI enforces this via `scripts/check-no-consumer-claude-writes.sh` — adding any new source reference to `.claude/{skills,hooks,scripts,agents}/` or `.claude/settings.json` requires an explicit entry in `tests/no-consumer-claude-writes.allow` with a justification comment. Allow-list entries are the audit trail for legacy code waiting to be retired.

## Tracker lifecycle

Tracker issues (label: `tracker`) are coordination artifacts that roll up child issues under a `## Rollout sequence` checklist. The orchestrator excludes them from the action queue and never proposes them for plan/execute. `/pipeline:run` housekeeping auto-closes any open issue labelled `tracker` whose `## Rollout sequence` children are all in state `CLOSED`, posting the comment `Auto-closed: all children merged.` and leaving the issue history preserved. This depends on the `tracker` label introduced by #31 — without that label the housekeeping pass has nothing to scan. Entrypoint: `scripts/auto-close-trackers.sh`. Contract / test substrate: `tests/test-auto-close-trackers.sh`.

## Design Principles

1. **Issues are the unit of work.** All planned work lives in GitHub issues. Specs, brainstorm notes, and design docs are transient — they get converted to issues and deleted.
2. **Human gates matter.** Plan approval and PR merge are manual. The pipeline automates the work between human decisions, not the decisions themselves.
3. **Superpowers are composable.** Pipeline skills declare which superpowers they use. A skill can compose with any superpowers available in the environment — if a superpowers skill isn't installed, the pipeline skill falls back to inline behavior.
4. **Isolation by default.** Execution happens in git worktrees. The main workspace stays clean.

## Spawn-claude degradation behavior

`spawn-claude.sh` is intentionally fail-soft when external inputs are unreliable:

- **`gh issue view` fails** (offline/auth): logs `[spawn-claude] WARN: gh issue view failed ...` to stderr and falls back to **PATH B** (the standard path). The session still launches.
- **Skill args file configured but missing on disk**: logs `WARNING: args file not found for <skill>: <path>` to stderr and emits the `Skill()` line **without** an `args=` field. The skill still fires; it just runs without its project-specific directive. Fix the typo or restore the file to remove the warning.

There is one **fail-closed** counterpart: when `PIPELINE_EVAL_CLASSIFIER` is set AND the skill is `evaluate-issue-pr` AND `--container-mode=<name>` was NOT passed, spawn-claude re-invokes the classifier inline. If the classifier would emit a `--container-mode=<name>` token, spawn-claude exits **5** with actionable stderr instead of silently launching a bare-host evaluator — fixing the race where a stale consumer copy of the script pre-empts container dispatch (#238). Fail-open when the classifier is unset, `mock-web-eval/scripts/eval-classifier-invoke.sh` is missing, or the classifier exits non-zero / emits nothing.

When `--container-mode=<name>` IS passed, spawn-claude forwards `PIPELINE_PROJECT_ROOT=<repo-root>` and `PIPELINE_WORKTREE_PATH=<worktree-abs>` into `docker compose run -e` (#241). The compose file binds `${PIPELINE_PROJECT_ROOT}:${PIPELINE_PROJECT_ROOT}` (same-path) and pins `working_dir` to `${PIPELINE_WORKTREE_PATH:-${PIPELINE_PROJECT_ROOT}}`. Same-path binding is required because Claude Code's plugin discovery is keyed off the `projectPath` field in `~/.claude/plugins/installed_plugins.json` — slash commands resolve only when the container's `working_dir` lives under a registered project path. `mock-web-eval/scripts/mock-web-eval-probe-port.sh` also seeds both env vars into `mock-web-eval/target/.env.mock-web-eval` for operators who invoke `docker compose run` directly without going through `spawn-claude.sh`.

## Self-improvement loop (dogfood-only)

This repo dogfoods a **repo-only audit system** that observes pipeline behavior to surface improvement candidates. The audit is **not part of the plugin** — nothing in `.claude-plugin/` references it, no consumer sees it.

**Trigger.** This repo's `.claude/settings.json` registers a `UserPromptSubmit` hook that runs `dev/hooks/audit-on-pipeline-run.sh`. When the submitted prompt starts with `/pipeline:run`, the hook backgrounds `dev/self-audit/inner-loop.sh` and returns in <200ms. The user's prompt is not blocked.

**Inner loop (`dev/self-audit/inner-loop.sh`).** Reads `dev/audits/index.jsonl` for the last audit timestamp, queries `gh` for merged feature/* PRs since then, reads observability logs (`.claude/logs/subagents/*.json`, `.claude/logs/tool-use*.log`, `.claude/logs/runs.log`) plus the orchestrator transcript at `${AUDIT_CLAUDE_PROJECTS_DIR:-~/.claude/projects}/<project-hash>/<session-uuid>.jsonl`, and emits `dev/audits/inner-<ISO>.md`. Every digest contains five sections: **Compliance**, **Interaction**, **Pattern → defaults** (per-run noise), **Efficiency**, and **Data quality** (which inputs were present/missing — blind spots are a first-class finding). The Interaction section ships as a `_pending subagent classification — session <uuid>_` placeholder; an LLM-powered classification subagent (dispatched from `/pipeline:run` step 1c) appends the real Interaction body in place. After every third new entry, the inner loop backgrounds `outer-loop.sh`.

**Audit-subagent dispatch (`/pipeline:run` step 1c → `dev/self-audit/dispatch-audit-subagent.md`).** On every `/pipeline:run`, after housekeeping, the orchestrator invokes `dev/self-audit/should-dispatch-audit.sh` — a stateless gate that prints `dispatch:<digest>:<transcript>` when the most-recent transcript (by mtime) is newer than the latest `index.jsonl` entry AND has ≥10 turns, else `skip:<reason>`. On `dispatch:*`, the orchestrator fires one `Agent(subagent_type='general-purpose')` with the prompt at `dev/self-audit/dispatch-audit-subagent.md` (read literally — do not paraphrase). The subagent reads the transcript, classifies correction events using LLM judgment (not regex), and replaces the `_pending_` placeholder in `<digest>` with the structured **Interaction** section in-place. Each correction event is three fields: `Trigger:` (assistant action), `Correction:` (user response, ≤200 chars, passed through `redact.sh::redact()`), `Suggested default:` (imperative line that would prevent the next instance). Dispatch is **synchronous in wall-clock** (slots into the housekeeping window where the user is already waiting) but **isolated in context** (subagent's window is separate from the orchestrator's — zero orchestrator-context cost).

**Outer loop (`dev/self-audit/outer-loop.sh`).** Reads the last 3 inner entries from `index.jsonl` and surfaces signals consistent across ALL of them. **Cross-run pattern detection on `Suggested default` strings:** when ≥2 of 3 runs in the window emit the same `Suggested default` (exact-string match in MVP; Jaccard ≥0.7 is the upgrade path), the outer digest names that string as a **codification candidate**. For each pattern, it names a **codification target** on a plugin surface: skill prose, `pipeline.config.example`, hooks, or scripts. **Never local-machine personal state** — that does not propagate. The outer loop is read-only: it files no issues, modifies no surfaces. A human reads the digest and files the issue when ready.

**Four lenses (MVP — interaction lens is the only one with real heuristics).**
1. **Compliance** — TODO stub (TDD pattern, wave-prio, PATH-tier dispatch, hook trip counts). Deferred until interaction lens proves its 10-run success criterion (#135 / #136).
2. **Interaction** — IMPLEMENTED (subagent-classified correction events with the three-field contract above). Other interaction signals (turn count, unnecessary confirmations) remain TODO; they can be added without re-architecting.
3. **Pattern → defaults** — IMPLEMENTED in outer-loop's 2-of-3 cross-run detector on Suggested-default strings.
4. **Efficiency** — TODO stub (tokens, wall clock, re-plan loops, eval-Revise verdicts).

**Redaction discipline (load-bearing).** Every transcript quote passes through `dev/self-audit/redact.sh::redact()`, which hard-denies token-shaped strings (regex `[A-Za-z0-9]{32,}`), the case-insensitive keywords `password|token|secret|api[_-]?key|bearer|Authorization`, and URLs containing `?key=|?token=|?auth=`; caps line length at 200 chars with a `...[truncated; original N chars]` suffix; and strips triple-backtick code-block contents entirely (only surrounding prose survives). Verified by `dev/tests/test-redaction.sh`.

**Output location.** All digests and `index.jsonl` live in `dev/audits/`, which is gitignored — digests may contain redacted excerpts and stay on-disk locally only.

**Plugin manifest is untouched.** `dev/`, `.claude/settings.json`, and the allow-list entry in `tests/no-consumer-claude-writes.allow` are the only surfaces this system writes to in this repo. `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `skills/`, `scripts/`, `hooks/`, `agents/` are not modified by this system.

**Internal-path dependency.** The orchestrator transcript path `~/.claude/projects/<project-hash>/<session-uuid>.jsonl` is a Claude Code internal. If Anthropic changes it, set `AUDIT_CLAUDE_PROJECTS_DIR` in the environment to point at the new location.

**Tests live at `dev/tests/test-*.sh`** and are run by `dev/tests/run-all.sh` (which CI invokes alongside `tests/test*.sh`).
