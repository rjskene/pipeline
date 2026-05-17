# Claude Pipeline Harness

A reusable automation layer for Claude Code projects. Manages the full GitHub issue lifecycle — planning, evaluation, execution, PR creation, and cleanup — through slash commands.

```
(new issue) → /pipeline:classify-issue → /pipeline:plan-issue → /pipeline:evaluate-issue-plan → (approve) → /pipeline:execute-issue-plan → /pipeline:evaluate-issue-pr → (merge)
```

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`. `/pipeline:classify-issue` additionally applies a path label (`docs-only` for trivial doc-only edits, `multi-task` for issues that need parallel sub-task execution) that steers downstream dispatch.

For autonomous end-to-end runs across many issues, use `/pipeline:fullsend` — it chains classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge without intermediate confirmations.

---

## Install

The pipeline is distributed as a Claude Code plugin. Install it from the marketplace:

```
/plugin marketplace add HTS-COLLAB-ORG/claude-pipeline
```

```
/plugin install pipeline@claude-pipeline
```

The plugin lives at `~/.claude/plugins/claude-pipeline/` (referenced at runtime as `${CLAUDE_PLUGIN_ROOT}`) and registers all slash commands, hooks, skills, and the `tdd-implementer` subagent automatically. Nothing is copied into your project tree.

### Installing the dev channel

Alongside the stable `claude-pipeline` marketplace, this repo publishes a sibling `claude-pipeline-dev` marketplace that carries release candidates of the same plugin at versions like `X.Y.Z-rc.N`. RCs are opt-in only; consumers on the stable channel are unaffected.

**Install from your existing `staging` clone** — auto-back-sync (see `CLAUDE.md` → Release cadence step 5) merges every release commit from `main` onto `staging` automatically (`--ff-only` when possible; `-X ours` when staging is ahead), so `staging` carries the same `version` fields as `main`. No separate `~/claude-pipeline-main` clone is required.

In your existing staging clone:

```bash
git pull --ff-only origin staging
```

Then in Claude Code (substitute the path to your staging clone):

```
/plugin marketplace add <path-to-your-staging-clone>/.claude-plugin/marketplace-dev.json
/plugin install pipeline@claude-pipeline-dev
```

Pick the **local** scope at the install prompt. Then reload so the new plugin code is active:

```
/plugin uninstall pipeline@claude-pipeline-dev
/plugin install   pipeline@claude-pipeline-dev
```

On each RC cut, `git pull --ff-only origin staging` in the same clone, then uninstall + reinstall above to pick up the new version.

**Pitfalls:**
- The repo is private, so an SSH key registered with GitHub (or HTTPS via `gh` token rewrite) is mandatory for the `git pull`.
- Do NOT use the `owner/repo@ref <manifest-path>` shorthand for the dev marketplace — Claude Code's CLI joins the manifest path into the ref. The local-path form is the only reliable one.
- Do NOT add the marketplace from a copy of `marketplace-dev.json` placed outside the repo tree — the manifest's `"source": "./"` resolves relative to the manifest file's location, so the loader can't find the plugin tree.
- Pick the **local** scope at the install prompt. The **user** scope works too, but its hooks fire in every Claude Code session on the machine.

**Troubleshooting — installed dev version older than expected?** Run `/pipeline:doctor` — the `dev_marketplace_on_main` check remains as defense-in-depth and warns if the registered marketplace path resolves to a non-`main` clone (legacy setups).

See `CLAUDE.md` → "Dev/prerelease channel" for the publishing side (how RCs are cut).

---

## Configure your project

Your consumer project needs exactly one pipeline file at its root: `pipeline.config`. The plugin reads it at runtime — there is no install-time template substitution.

Create the file with the values for your project:

```bash
PIPELINE_REPO="your-org/your-repo"          # GitHub owner/repo
PIPELINE_BASE_BRANCH="staging"              # Branch that PRs target (default: staging — dev trunk)
PIPELINE_WORKTREE_PREFIX="wt"               # Worktree directory prefix
PIPELINE_INSTALL_CMD="npm ci"               # How to install dependencies
PIPELINE_TEST_CMD="npm test"                # How to run tests
PIPELINE_TYPECHECK_CMD="npx tsc --noEmit"   # How to type-check (leave empty to skip)
PIPELINE_CONTEXT_FILES="CLAUDE.md"          # CLAUDE.md files the agents should read
# ... see pipeline.config.example in the plugin repo for all options
```

Then create the GitHub labels the pipeline uses to track issue progress:

| Label | Description |
|---|---|
| `plan-pending` | Plan has been posted, awaiting review |
| `plan-reviewed` | Plan has been evaluated |
| `plan-approved` | Plan approved, ready for execution |
| `in-progress` | Currently being implemented |
| `pr-open` | PR is open and awaiting review |
| `merged` | PR merged, ready for cleanup |
| `excluded` | Issue excluded from pipeline (configurable via `PIPELINE_LABELS_EXCLUDED`) |
| `later` | Deferred — shown in status but not processed (configurable via `PIPELINE_LABELS_LATER`) |
| `human` | Needs human in the loop — never processed by autonomous runs (configurable via `PIPELINE_LABELS_HUMAN`) |
| `brainstorm` | Non-actionable discussion or exploration — surfaced in status but never auto-planned (configurable via `PIPELINE_LABELS_BRAINSTORM`) |

After installing the plugin, validate your setup:

```
/pipeline:doctor
```

This is a read-only audit — it reports any gaps in `pipeline.config`, `gh` auth, plugin registration, residual subtree artifacts, the base branch, and label setup. To seed the GitHub labels listed above in one shot, run:

```
/pipeline:doctor --fix labels
```

`--fix labels` is idempotent (uses `gh label create --force`) and honors `PIPELINE_LABELS_*` overrides from `pipeline.config`.

Hooks are registered by the plugin manifest at install time — you do not need to touch `.claude/settings.json` yourself.

### Release-PR awareness (release-please et al.)

`/pipeline:run` discovers open release-bot PRs in housekeeping and surfaces them in a dedicated **Release PRs** row group above the regular pipeline-issue table:

```
RELEASE PRs
================================================================
 PR     Title                              Stage             CI
----------------------------------------------------------------
 #201   chore(main): release 1.2.3         release-pending   pass
 #202   chore(main): release 1.3.0         release-pending   fail
================================================================
```

`release-pending` is a display-only Stage value — it is NOT a GitHub label. The PR already carries `autorelease: pending` (release-please convention); writing a second label would force consumer repos to define it.

In **interactive mode**, a green release PR is proposed for merge once feature work in flight is done (priority slots between `plan-approved` execution and `ready` planning). In **`/pipeline:fullsend`** (also reachable via the back-compat `"full send"` shortcut in `/pipeline:run`), step 7b auto-merges green release PRs between PR evaluation (step 7) and report (step 8) — gated on the opt-in flag below.

Two config flags control behavior (defaults shown):

| Flag | Default | Purpose |
|---|---|---|
| `PIPELINE_RELEASE_PR_AUTO_MERGE` | `"false"` | Opt-in auto-merge of green release PRs during `/pipeline:fullsend` (or back-compat `"full send"` in `/pipeline:run`). Default off so manual-review release flows aren't surprised on upgrade. |
| `PIPELINE_RELEASE_PR_LABEL` | `"autorelease: pending"` | Label used to discover release-bot PRs. Override for non-release-please bots (e.g. `please-release`). |

PRs with `ci=fail` or `ci=pending` are surfaced in the table but never proposed/merged — wait for CI to settle (or fix it) first.

The discovery helper requires `jq` (already a pipeline prerequisite) and `gh`. If `gh` is unavailable or no release PRs are open, the row group is omitted silently.

---

## Usage

| Command | What it does |
|---|---|
| `/pipeline:run` | Check pipeline status, see what's ready, advance the next stage |
| `/pipeline:fullsend [N N ...]` | Autonomous end-to-end run for one or many issues (classify → plan → evaluate-plan → execute → evaluate-pr → greenlight-merge) without intermediate confirmations |
| `/pipeline:classify-issue 42` | Triage issue #42 and apply a path label (`docs-only` / `multi-task` / none) for downstream dispatch |
| `/pipeline:plan-issue 42` | Generate an implementation plan for issue #42 and post it as a comment |
| `/pipeline:evaluate-issue-plan 42` | Independently review the plan on issue #42 |
| `/pipeline:execute-issue-plan 42` | Implement the approved plan (run from inside the feature worktree) |
| `/pipeline:evaluate-issue-pr 42` | Review the PR against its plan (run from inside the feature worktree) |
| `/pipeline:create-issues` | Brainstorm mode — discuss changes, then push as GitHub issues |
| `/pipeline:worktree-sync` | Sync `.claude/` files to all active worktrees |
| `/pipeline:doctor` | Read-only audit of `pipeline.config`, `gh` auth, plugin registration, labels, residual subtree artifacts, and base branch (run `/pipeline:doctor --fix labels` to seed the canonical labels) |

---

> **Migrating from a subtree install?** The legacy `.claude-pipeline/` subtree path is retired. Existing subtree consumers run the one-shot migration once — see [docs/migration-from-subtree.md](docs/migration-from-subtree.md).

---

## Prerequisites

- **`gh` CLI** — for GitHub issue/PR operations
- **`jq`** — for hook JSON parsing
- **`bash` 4+** — queue and status scripts use associative arrays
  - macOS ships bash 3.2; install a newer version: `brew install bash`
