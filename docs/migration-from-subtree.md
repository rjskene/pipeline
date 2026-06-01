# Migrating from a subtree install to the plugin install

This guide walks an existing consumer of claude-pipeline from the legacy `.claude-pipeline/` subtree install to a clean plugin install. Run all commands from the root of your consumer project.

The migration is one-shot and idempotent: re-running on an already-migrated project is a no-op.

Bootstrapping a fresh (non-subtree) project instead? See [Getting started](getting-started.md) — the greenfield counterpart that leads with /pipeline:init.

## 1. Confirm you have a subtree install

```bash
ls -d .claude-pipeline
```

If the directory exists, you have a legacy install and this guide applies. If it does not, you are already on the plugin install path — skip to step 4.

## 2. Run the migration script

```bash
bash scripts/migrate-from-subtree.sh
```

The script removes every pipeline-managed file it can identify (skills, agents, scripts, hooks that the harness installed into `.claude/`) and the `.claude-pipeline/` directory itself. Consumer-owned files are preserved:

- `pipeline.config` at the project root stays put — it is owned by your project, and the plugin reads it at runtime via `${CLAUDE_PLUGIN_ROOT}/scripts/...` shims.
- Any non-pipeline files under `.claude/` (skills, agents, hooks, or settings you authored yourself) are untouched. Pipeline files are identified by `.pipeline-managed` markers and by basename enumeration against `.claude-pipeline/`.

### 2a. Recovering installs that bypassed the legacy installer

If your install came from a subtree-pull, hand-copy, or `git fetch <fork>` import (i.e., never went through `bash .claude-pipeline/install.sh`), the `.pipeline-managed` marker files will be absent and the marker-only detection pass will skip your duplicates. Use the basename-match recovery flow:

```bash
bash scripts/migrate-from-subtree.sh --dry-run
```

The script lists every `.claude/skills/*/` directory and `.claude/agents/*.md` file whose basename matches a plugin-shipped skill or agent. Review the list — anything you authored yourself with a same-named skill is preserved because it doesn't match a plugin basename, and consumer-authored skills with novel names never appear.

Then re-run interactively:

```bash
bash scripts/migrate-from-subtree.sh
```

You'll be prompted `[y/N]` per candidate. For non-interactive removal (e.g., CI cleanup), use `--assume-yes`. To preview without any chance of mutation, use `--assume-no`.

## 3. Review the settings.json advisory report

If the migration script detected pipeline hook entries in `.claude/settings.json`, it writes an advisory report to:

```
.claude/settings.json.pipeline-migration-report.txt
```

The script never mutates `settings.json` itself. After the plugin install the harness registers its own hooks via the plugin manifest, so leftover entries in your project's `settings.json` will double-register and cause duplicate hook fires.

A unified-diff patch is also written to `.claude/migration-cleanup-settings.patch` (parallel to step 3a below). Review it (`less .claude/migration-cleanup-settings.patch`), then apply with `git apply .claude/migration-cleanup-settings.patch`. The patch is JSON-aware — it removes only the pipeline-flagged hook entries and preserves consumer-authored entries plus other top-level keys (`env`, `permissions`, `mcpServers`, …).

If the report contains a `WARNING: applying this patch will leave .claude/settings.json functionally empty` block, the patch will delete `settings.json` entirely (the post-patch content would be `{}`). Review for non-pipeline customizations the detector may have missed before applying — when in doubt, edit `settings.json` by hand instead.

When you are done, delete the artifacts:

```bash
rm -f .claude/migration-cleanup-settings.patch .claude/settings.json.pipeline-migration-report.txt
```

## 3a. Review the CLAUDE.md advisory report

If `.claude/migration-cleanup-report-claudemd.txt` exists, the migration detected pipeline-legacy content in your `CLAUDE.md`(s). Open the file; each finding lists `<path>:<line>: <text>` under one of three subsections (Section headers / Legacy paths / Deprecated slash commands).

A unified-diff patch is also written to `.claude/migration-cleanup-claudemd.patch`. Review it (`less .claude/migration-cleanup-claudemd.patch`), then apply with `git apply .claude/migration-cleanup-claudemd.patch` (or edit your `CLAUDE.md` by hand if you want partial coverage). The patch deletes entire flagged `## Pipeline*` sections and the individual legacy-reference lines that fall outside those sections — preview before applying.

After cleanup, delete the artifacts with `rm -f .claude/migration-cleanup-report-claudemd.txt .claude/migration-cleanup-claudemd.patch`, then run `/pipeline:doctor` (introduced by #144, merged at `120640b`) to validate your install end-to-end.

## 4. Add the plugin marketplace

```bash
/plugin marketplace add rjskene/pipeline
```

Run this inside Claude Code. It registers the claude-pipeline marketplace with the local plugin client.

## 5. Install the plugin

```bash
/plugin install pipeline@claude-pipeline
```

The form is `<plugin-name>@<marketplace-name>` — `pipeline` is the plugin (from `plugin.json`), `claude-pipeline` is the marketplace (from `marketplace.json`). The plugin is fetched into `~/.claude/plugins/claude-pipeline/` and all of its slash commands, hooks, skills, and the `tdd-implementer` subagent are registered automatically.

If the migration script printed a different install hint at the end of step 2 (e.g., `claude plugin install ...`), ignore it and use the slash commands above.

## 6. Verify

```bash
/pipeline:run
```

You should see the pipeline orchestrator inspect the issue queue and report the next stage. If the command is not found, the plugin did not install correctly — re-run step 5 and check for errors.

That's it. Your project now has no `.claude-pipeline/` directory and no pipeline files inside `.claude/`. The only pipeline-related file in your repo is `pipeline.config`.
