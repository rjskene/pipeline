# Claude Pipeline Harness

A reusable automation layer for Claude Code projects. Manages the full GitHub issue lifecycle — planning, evaluation, execution, PR creation, and cleanup — through slash commands.

```
(new issue) → /pipeline:plan-issue → /pipeline:evaluate-issue-plan → (approve) → /pipeline:execute-issue-plan → /pipeline:evaluate-issue-pr → (merge)
```

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

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

---

## Configure your project

Your consumer project needs exactly one pipeline file at its root: `pipeline.config`. The plugin reads it at runtime — there is no install-time template substitution.

Create the file with the values for your project:

```bash
PIPELINE_REPO="your-org/your-repo"          # GitHub owner/repo
PIPELINE_BASE_BRANCH="staging"              # Branch that PRs target
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

You can create them quickly with `gh`:

```bash
REPO="your-org/your-repo"
gh label create plan-pending   --repo $REPO --color "C2E0C6" --description "Plan posted, awaiting review"
gh label create plan-reviewed  --repo $REPO --color "BFD4F2" --description "Plan evaluated"
gh label create plan-approved  --repo $REPO --color "0E8A16" --description "Approved, ready for execution"
gh label create in-progress    --repo $REPO --color "FBCA04" --description "Currently being implemented"
gh label create pr-open        --repo $REPO --color "1D76DB" --description "PR open, awaiting review"
gh label create merged         --repo $REPO --color "6F42C1" --description "PR merged, ready for cleanup"
gh label create excluded       --repo $REPO --color "E4E669" --description "Excluded from pipeline"
gh label create later          --repo $REPO --color "D4C5F9" --description "Deferred"
gh label create human          --repo $REPO --color "F9D0C4" --description "Needs human in the loop"
```

Hooks are registered by the plugin manifest at install time — you do not need to touch `.claude/settings.json` yourself.

---

## Usage

| Command | What it does |
|---|---|
| `/pipeline:run` | Check pipeline status, see what's ready, advance the next stage |
| `/pipeline:plan-issue 42` | Generate an implementation plan for issue #42 and post it as a comment |
| `/pipeline:evaluate-issue-plan 42` | Independently review the plan on issue #42 |
| `/pipeline:execute-issue-plan 42` | Implement the approved plan (run from inside the feature worktree) |
| `/pipeline:evaluate-issue-pr 42` | Review the PR against its plan (run from inside the feature worktree) |
| `/pipeline:create-issues` | Brainstorm mode — discuss changes, then push as GitHub issues |
| `/pipeline:worktree-sync` | Sync `.claude/` files to all active worktrees |

---

## Migrating from a subtree install

If you previously installed the pipeline via the legacy `.claude-pipeline/` subtree path, there is a one-shot migration script that removes the legacy files and leaves your project ready for the plugin install. See [docs/migration-from-subtree.md](docs/migration-from-subtree.md) for the full sequence.

---

## Prerequisites

- **`gh` CLI** — for GitHub issue/PR operations
- **`jq`** — for hook JSON parsing
- **`bash` 4+** — queue and status scripts use associative arrays
  - macOS ships bash 3.2; install a newer version: `brew install bash`
