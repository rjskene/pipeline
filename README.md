# Claude Pipeline Harness

A reusable automation layer for Claude Code projects. Manages the full GitHub issue lifecycle — planning, evaluation, execution, PR creation, and cleanup — through slash commands.

```
(new issue) → /plan-issue → /evaluate-plan → (approve) → /execute-issue → /evaluate-issue → (merge)
```

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

---

## Adding to a new project

There are three ways to bring the pipeline into a project. Pick one.

### Option A: Plain copy (simplest)

Just copy the `.claude-pipeline/` directory into your new project:

```bash
cp -r /path/to/source-repo/.claude-pipeline /path/to/your-project/
```

This gives you a snapshot. If the pipeline harness is updated in the source repo later, you'd need to copy it again manually.

### Option B: Git subtree (recommended)

A **git subtree** embeds a copy of the pipeline directory directly in your repo. It looks and acts like normal files in your project — no special git commands needed for day-to-day work. The advantage over a plain copy is that you can **pull updates** from the source repo later with one command.

**First time — add the pipeline to your project:**

```bash
cd /path/to/your-project

# This creates .claude-pipeline/ with the contents from the source repo
git subtree add \
  --prefix=.claude-pipeline \
  https://github.com/rjskene/claude-pipeline.git main \
  --squash
```

- `--prefix=.claude-pipeline` = where to put it in your repo
- `https://github.com/...` = the pipeline source repo
- `main` = branch to pull from
- `--squash` = collapse the pipeline's history into a single commit (keeps your log clean)

This creates a commit in your project with the pipeline files. They're just regular files now — you can read them, your IDE indexes them, etc.

**Later — pull updates:**

```bash
git subtree pull \
  --prefix=.claude-pipeline \
  https://github.com/rjskene/claude-pipeline.git main \
  --squash
```

Same command with `pull` instead of `add`. Git merges any changes into your copy.

**Tip:** To avoid typing the URL every time, add it as a remote:

```bash
git remote add claude-pipeline https://github.com/rjskene/claude-pipeline.git

# Then:
git subtree pull --prefix=.claude-pipeline claude-pipeline main --squash
```

### Option C: Git submodule

A **git submodule** is a pointer from your repo to a specific commit in the pipeline repo. Unlike a subtree, the files live in a separate git repo that's cloned inside your project.

```bash
cd /path/to/your-project

# Adds .claude-pipeline/ as a submodule
git submodule add \
  https://github.com/rjskene/claude-pipeline.git \
  .claude-pipeline

git commit -m "Add claude-pipeline submodule"
```

**Pull updates later:**

```bash
cd .claude-pipeline
git pull origin main
cd ..
git add .claude-pipeline
git commit -m "Update claude-pipeline"
```

**After cloning a repo that uses a submodule:**

Anyone who clones your project needs to initialize the submodule:

```bash
git clone https://github.com/you/your-project.git
cd your-project
git submodule update --init
```

**Subtree vs. submodule — which to pick:**

| | Subtree | Submodule |
|---|---|---|
| Files are... | Real files in your repo | A pointer to another repo |
| Cloning | Just works | Requires `git submodule update --init` |
| Updating | `git subtree pull` | `cd` into it, `git pull`, commit the pointer |
| Offline | Everything is local | Needs network to initialize |
| Complexity | Lower | Higher (extra git concepts) |

**Subtree is the simpler choice for most teams.** Submodules are better if you want strict version pinning or if multiple repos must stay on exactly the same commit.

---

## Setup (after adding the directory)

These steps are the same regardless of which method you used above.

### 1. Create `pipeline.config`

Copy the example and edit it:

```bash
cp .claude-pipeline/pipeline.config.example pipeline.config
```

Open `pipeline.config` and fill in your project's values:

```bash
PIPELINE_REPO="your-org/your-repo"          # GitHub owner/repo
PIPELINE_BASE_BRANCH="staging"              # Branch that PRs target
PIPELINE_WORKTREE_PREFIX="wt"               # Worktree directory prefix
PIPELINE_INSTALL_CMD="npm ci"               # How to install dependencies
PIPELINE_TEST_CMD="npm test"                # How to run tests
PIPELINE_TYPECHECK_CMD="npx tsc --noEmit"   # How to type-check (leave empty to skip)
PIPELINE_CONTEXT_FILES="CLAUDE.md"          # CLAUDE.md files the agents should read
# ... see pipeline.config.example for all options
```

### 2. Run the installer

```bash
bash .claude-pipeline/install.sh
```

This reads your `pipeline.config` and generates all the working files:

- `.claude/skills/*/SKILL.md` — slash command definitions
- `.claude/scripts/*.sh` — shell scripts for worktrees, queues, etc.
- `.claude/hooks/*` — safety hooks (deletion guard, PR base-branch enforcement, etc.)

Re-run the installer any time you change `pipeline.config`. It skips files that haven't changed.

### 3. Wire up hooks in settings.json

The installer generates hook scripts but does **not** modify your `.claude/settings.json`. You need to register the hooks manually. Use `.claude-pipeline/settings.json.template` as a reference:

```jsonc
// .claude/settings.json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "python3 .claude/hooks/block_deletions.py" }]
      },
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "python3 .claude/hooks/enforce-base-branch.py" }]
      },
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "python3 .claude/hooks/restrict_paths.py" }]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "bash .claude/hooks/log-tool-use.sh" }]
      }
    ]
  }
}
```

Pick the hooks that make sense for your project. They're all optional.

### 4. Create GitHub labels

The pipeline tracks issue progress with these labels. Create them in your GitHub repo (Settings → Labels):

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

### 5. Verify

Run `/pipeline` in Claude Code. It should fetch your issues and print a status table.

---

## Usage

| Command | What it does |
|---|---|
| `/pipeline` | Check pipeline status, see what's ready, advance the next stage |
| `/plan-issue 42` | Generate an implementation plan for issue #42 and post it as a comment |
| `/evaluate-plan 42` | Independently review the plan on issue #42 |
| `/execute-issue 42` | Implement the approved plan (run from inside the feature worktree) |
| `/evaluate-issue 42` | Review the PR against its plan (run from inside the feature worktree) |
| `/create-issues` | Brainstorm mode — discuss changes, then push as GitHub issues |
| `/worktree-sync` | Sync `.claude/` files to all active worktrees |

---

## How templates work

There are two kinds of files in `.claude-pipeline/`:

- **Templates** (`.template` suffix) — processed by `install.sh`. SKILL.md and Python hook templates use `envsubst` to bake in `${PIPELINE_*}` values at install time. Shell script templates are copied as-is because they `source pipeline.config` at runtime.
- **Non-template files** — copied directly to `.claude/` with no modification.

After installation, the generated files live in `.claude/skills/`, `.claude/scripts/`, and `.claude/hooks/`. You can choose to gitignore these (and regenerate from `install.sh`) or commit them — either approach works.

---

## File reference

```
.claude-pipeline/
├── install.sh                              # Installer script
├── pipeline.config.example                 # Example config (copy to pipeline.config)
├── settings.json.template                  # Reference hook wiring
├── README.md                               # This file
├── skills/
│   ├── pipeline/SKILL.md.template          # Pipeline status + coordinator
│   ├── plan-issue/SKILL.md.template        # Planning agent
│   ├── evaluate-plan/SKILL.md.template     # Plan evaluator
│   ├── execute-issue/SKILL.md.template     # Execution agent
│   ├── evaluate-issue/SKILL.md.template    # PR evaluator
│   ├── create-issues/SKILL.md.template     # Issue creation from brainstorm
│   └── worktree-sync/SKILL.md.template     # Worktree file sync
├── scripts/
│   ├── run-queue.sh.template               # Queue runner
│   ├── spawn-claude.sh.template            # Agent spawner
│   ├── setup-worktree.sh.template          # Worktree creation
│   ├── cleanup-worktree.sh.template        # Worktree teardown
│   ├── sync-worktrees.sh.template          # Worktree sync
│   ├── retarget-pr.sh.template             # PR base-branch retargeting
│   ├── queue-status.sh                     # Queue status display
│   ├── review-logs.sh                      # Tool-use log reviewer
│   ├── check-server.sh                     # Server health check
│   └── check-subtree-drift.sh              # Detects upstream/local drift in subtree installs
└── hooks/
    ├── block_deletions.py                  # Guards against accidental deletions
    ├── enforce-base-branch.py.template    # Blocks PRs that target the wrong branch
    ├── restrict_paths.py.template          # Restricts file access to project boundaries
    └── log-tool-use.sh                     # Logs all tool invocations
```

## Prerequisites

- **`envsubst`** (part of `gettext`) — used by `install.sh`
  - Linux: `sudo apt-get install gettext-base`
  - macOS: `brew install gettext && brew link --force gettext`
  - Git Bash (Windows): included by default
- **`gh` CLI** — for GitHub issue/PR operations
- **`jq`** — for hook JSON parsing
- **`bash` 4+** — queue and status scripts use associative arrays
  - macOS ships bash 3.2; install a newer version: `brew install bash`
