# Migrating from a subtree install to the plugin install

This guide walks an existing consumer of claude-pipeline from the legacy `.claude-pipeline/` subtree install to a clean plugin install. Run all commands from the root of your consumer project.

The migration is one-shot and idempotent: re-running on an already-migrated project is a no-op.

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

## 3. Review the settings.json advisory report

If the migration script detected pipeline hook entries in `.claude/settings.json`, it writes an advisory report to:

```
.claude/settings.json.pipeline-migration-report.txt
```

The script never mutates `settings.json` itself. Open the report, then open `settings.json`, and manually delete any flagged hook entries. After the plugin install the harness registers its own hooks via the plugin manifest, so leftover entries in your project's `settings.json` will double-register and cause duplicate hook fires.

When you are done, delete the report file:

```bash
rm -f .claude/settings.json.pipeline-migration-report.txt
```

## 4. Add the plugin marketplace

```bash
/plugin marketplace add HTS-COLLAB-ORG/claude-pipeline
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
