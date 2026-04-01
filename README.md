# Claude Pipeline Harness

A reusable multi-file skill that provides an automated GitHub issue pipeline for Claude Code projects. Manages the full lifecycle: planning, evaluation, execution, PR creation, and cleanup — all through Claude Code slash commands.

## Pipeline flow

```
(new issue) → /plan-issue → /evaluate-plan → (user approves) → /execute-issue → /evaluate-issue → (merge) → (cleanup)
```

Label flow: `(none) → plan-pending → plan-reviewed → plan-approved → in-progress → pr-open → merged`

## Quick start

1. **Copy or submodule** `.claude-pipeline/` into your project root.

2. **Create `pipeline.config`** in your project root:
   ```bash
   cp .claude-pipeline/pipeline.config.example pipeline.config
   # Edit pipeline.config with your project's values
   ```

3. **Run the installer:**
   ```bash
   bash .claude-pipeline/install.sh
   ```
   This generates all files in `.claude/skills/`, `.claude/scripts/`, and `.claude/hooks/`.

4. **Wire up hooks** in `.claude/settings.json` (see `.claude-pipeline/settings.json.template` for the expected hook configuration). The installer does NOT modify `settings.json` — you manage it manually.

5. **Use the pipeline:**
   ```
   /pipeline          # Check status and advance next stage
   /plan-issue 42     # Plan issue #42
   /evaluate-plan 42  # Evaluate the plan
   /execute-issue 42  # Implement the approved plan
   /evaluate-issue 42 # Review the PR against the plan
   /worktree-sync     # Sync .claude/ files to all worktrees
   ```

## Configuration

All config lives in `pipeline.config` (shell-sourceable). See `pipeline.config.example` for all available knobs and documentation.

### How templates work

- **SKILL.md files** and **Python hooks** use `envsubst` at install time — `${PIPELINE_*}` variables are baked into the output files.
- **Shell scripts** source `pipeline.config` at runtime — variables are resolved when the script runs, not at install time. The `source` line (`source "$(cd "$(dirname "$0")/../.." && pwd)/pipeline.config"`) resolves the project root relative to the script location.

### Re-installing

After changing `pipeline.config`, re-run:
```bash
bash .claude-pipeline/install.sh
```

The installer skips files that haven't changed (uses `diff -q`).

## Files

```
.claude-pipeline/
├── install.sh                              # Installer (reads pipeline.config, generates project files)
├── pipeline.config.example                 # Example config with all knobs documented
├── settings.json.template                  # Reference hook wiring (NOT auto-applied)
├── README.md                               # This file
├── skills/
│   ├── pipeline/SKILL.md.template          # Pipeline coordinator
│   ├── plan-issue/SKILL.md.template        # Planning agent
│   ├── evaluate-plan/SKILL.md.template     # Plan evaluator
│   ├── execute-issue/SKILL.md.template     # Execution agent
│   ├── evaluate-issue/SKILL.md.template    # PR evaluator
│   └── worktree-sync/SKILL.md.template     # Worktree sync
├── scripts/
│   ├── run-queue.sh.template               # Queue runner (parameterized)
│   ├── spawn-claude.sh.template            # Agent spawner (parameterized)
│   ├── setup-worktree.sh.template          # Worktree setup (parameterized)
│   ├── cleanup-worktree.sh.template        # Worktree cleanup (parameterized)
│   ├── sync-worktrees.sh.template          # Worktree sync (parameterized)
│   ├── review-logs.sh                      # Log reviewer (generic)
│   └── check-server.sh                     # Server health check (generic)
└── hooks/
    ├── block_deletions.py                  # Deletion guard (generic)
    ├── enforce-staging-base.py.template    # PR base-branch guard (parameterized)
    ├── restrict_paths.py.template          # Path boundary hook (parameterized)
    └── log-tool-use.sh                     # Tool-use logger (generic)
```

## Prerequisites

- `envsubst` (part of `gettext`) — used by `install.sh`
  - Linux: `sudo apt-get install gettext-base`
  - macOS: `brew install gettext && brew link --force gettext`
  - Git Bash (Windows): included by default
- `gh` CLI — for GitHub issue/PR operations
- `jq` — for hook JSON parsing
