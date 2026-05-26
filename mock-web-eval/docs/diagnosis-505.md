# Root-cause diagnosis — #505 (`/pipeline:*` undiscoverable inside mock-web-eval container)

Regression of #241. PR #504's fullsend hit `Unknown command: /pipeline:evaluate-issue-pr`
inside the `--container-mode=mock-web-eval` evaluator. The issue body listed three candidate
causes and demanded empirical verification before patching. This doc records the probe outputs
that identify the actual cause, and names the file/mount that flips the Task-1 regression
fixture green.

All probes ran in the same container layout the failing fullsend used: the host project root
bind-mounted at the same absolute path, `working_dir` set to a git worktree beneath it, and
`~/.claude/{plugins,settings.json,.credentials.json}` mounted read-only. The reproduction
worktree was created with `git worktree add` under the registered project root, mirroring the
real dispatch shape (`scripts/spawn-claude.sh` container mode:
`PIPELINE_PROJECT_ROOT=<main root>`, `working_dir=<worktree>`).

## Probe A — what claude-cli reads (`--debug`)

`claude --debug --dangerously-skip-permissions -p '/pipeline:doctor'` produced no extra
diagnostic output in `-p` (print) mode — the slash command is rejected at resolution time,
before any debug logging:

```
Unknown command: /pipeline:doctor
```

`--debug` was therefore uninformative here; the investigation pivoted to `claude plugin list`
(Probe ‑tree below), which reports per-plugin load status and is the decisive instrument.

## Probe B — file-visibility audit (inside the container)

```
### whoami / pwd
runner
/home/rjskene/claude-pipeline/.claude/worktrees/test-505-discovery
### installed_plugins.json — pipeline-related lines
    "pipeline@claude-pipeline": [
        "scope": "local"
        "projectPath": "/home/rjskene/claude-pipeline"
        "installPath": "/home/rjskene/.claude/plugins/cache/claude-pipeline/pipeline/0.17.0-rc.1"
### settings.json (host ~/.claude) — enable-related lines
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
    "autoresearch@autoresearch": true
### project-root .claude/settings.local.json (via project mount)
-rw-rw-r-- 1 runner runner 67 /home/rjskene/claude-pipeline/.claude/settings.local.json
--- contents ---
{ "enabledPlugins": { "pipeline@claude-pipeline": true } }
### cwd .claude/ listing  (worktree, raw `git worktree add`)
-rw-rw-r-- settings.json          # NOTE: no settings.local.json here
### ~/.claude/settings.local.json (user scope)
ls: cannot access '/home/runner/.claude/settings.local.json': No such file or directory
```

Findings: pipeline **is** registered (`scope=local`, `projectPath=/home/rjskene/claude-pipeline`).
The project-root enablement file exists and is visible. The container's HOME is `/home/runner`
(host user is `rjskene`).

The decisive instrument was `claude plugin list` (run at `working_dir=<project root>`,
**no fix mount**):

```
❯ autoresearch@autoresearch       Scope: user    Status: ✘ failed to load
    Error: Plugin autoresearch not found in marketplace autoresearch
❯ pipeline@claude-pipeline        Scope: local   Status: ✘ failed to load
    Error: Plugin pipeline not found in marketplace claude-pipeline
❯ superpowers@claude-plugins-official  Scope: user  Status: ✘ failed to load
    Error: Plugin superpowers not found in marketplace claude-plugins-official
```

**Every** plugin — including the user-scope `superpowers`/`autoresearch` that are enabled in
`~/.claude/settings.json` — fails with `not found in marketplace`. This rules out enablement
(candidate cause 3) as the primary fault: enabled plugins also fail.

The marketplace registry reveals why (`~/.claude/plugins/known_marketplaces.json`):

```json
"claude-pipeline": {
  "source": { "source": "github", "repo": "rjskene/pipeline" },
  "installLocation": "/home/rjskene/.claude/plugins/marketplaces/claude-pipeline"
}
```

`installLocation` is a **host-absolute path under `/home/rjskene/.claude/plugins`**. Inside the
container that path does not exist — only `/home/rjskene/claude-pipeline` is bind-mounted, not
`/home/rjskene/.claude`. The marketplace *content* is present, but at the container-HOME path:

```
### host-absolute installLocation reachable?
ls: cannot access '/home/rjskene/.claude/plugins/marketplaces/claude-pipeline': No such file or directory
### container-HOME path (~/.claude/plugins/marketplaces/claude-pipeline) reachable?
drwxr-xr-x ... claude-pipeline    # present (mounted from host ~/.claude/plugins → /home/runner/.claude/plugins)
```

claude-cli finds the registry via `$HOME` (`/home/runner/.claude/plugins/known_marketplaces.json`)
but then resolves each marketplace at its recorded **host-absolute** `installLocation`
(`/home/rjskene/.claude/plugins/marketplaces/...`), which is absent in the container → load fails.

## Probe C — does cwd-vs-projectPath matter?

`working_dir=/home/rjskene/claude-pipeline` (the exact registered `projectPath`, **not** a
worktree), no fix mount:

```
Unknown command: /pipeline:doctor
```

It **also** fails at the registered `projectPath`. This rules out candidate causes 1 and 2
(project-discovery / `cwd == projectPath` tightening, and worktree-as-its-own-project): the
plugin fails to load even when cwd is exactly the registered project. The fault is
marketplace-path resolution, not cwd keying.

## Probe D — does the same-absolute-path mount fix it?

Adding `-v ${HOME}/.claude/plugins:${HOME}/.claude/plugins:ro` so the host-absolute marketplace
paths resolve:

- **`working_dir=projectPath`:** `pipeline@claude-pipeline` → `Status: ✔ enabled`;
  `superpowers`/`autoresearch` → `✔ enabled`; `/pipeline:doctor` resolves and runs
  (emits `CHECK:` lines + `=== Summary ===`).
- **`working_dir=worktree` created by raw `git worktree add` (no enable file):**
  `pipeline` → `Status: ✘ disabled` (no longer "failed to load" — marketplace now resolves).
  This is a **test artifact**, not the regression: a raw `git worktree add` omits the untracked
  `.claude/settings.local.json` that the pipeline's `setup-worktree.sh` / worktree-sync copies
  into every real feature worktree. Confirmed: this repo's live `wt-505-…` worktree **does**
  carry `.claude/settings.local.json` with `{"enabledPlugins":{"pipeline@claude-pipeline":true}}`.
- **`working_dir=worktree` that carries `settings.local.json` (faithful to real worktrees) +
  the mount:** `/pipeline:doctor` resolves and runs (`Unknown command` count 0; `CHECK:`/
  `=== Summary ===` present). The unrelated `jq_installed` check fails because the image ships no
  `jq` — out of scope for #505; the slash command resolved, which is the contract under test.

## Conclusion

**Root cause (iii) — "something else": marketplace `installLocation` host-absolute-path
mismatch.** `~/.claude/plugins/known_marketplaces.json` records each marketplace's
`installLocation` as a path under the **host** HOME (`/home/rjskene/.claude/plugins/marketplaces/…`).
The container runs as `runner` with HOME `/home/runner`, and the compose file mounts
`~/.claude/plugins` only at `/home/runner/.claude/plugins`. claude-cli resolves marketplaces at
their recorded host-absolute paths, which do not exist in the container, so every plugin —
including the enabled user-scope ones — fails with `not found in marketplace`. This is the same
*class* of bug #241 fixed for the **project root** (bind-mount at the same absolute path the host
registered), now surfacing for the **plugin/marketplace registry**, which the current compose
file does not mount at its host-absolute path.

**Neither candidate cause 1 (cwd/projectPath tightening) nor 3 (enablement) is the primary
fault** — both are ruled out by Probe C (fails at projectPath) and Probe B/-tree (enabled
user-scope plugins also fail). Enablement (Layer 2) is handled in production by worktree-sync
copying `settings.local.json` into each feature worktree, so it is not part of this regression.

**The single mount that flips the Task-1 fixture green:**

```yaml
- "${HOME}/.claude/plugins:${HOME}/.claude/plugins:ro"
```

added to `mock-web-eval/docker/compose.yml`. With it (and a worktree carrying its
`settings.local.json`, as real worktrees do), `/pipeline:doctor` resolves and the doctor skill
runs inside the container.

### Fix classification & scope

This is the plan's **Branch C** (a cause neither the planner's enablement prior nor #241's
project-path theory anticipated). The fix satisfies Branch C's constraints: it is the smallest
change that turns the Task-1 fixture green, does **not** widen `restrict_paths.py`, does **not**
add a per-spawn `claude plugin install` step, and does **not** touch the pinned
`@anthropic-ai/claude-code` version. No live `pipeline.config` edit is required — the fix lands
entirely in tracked files (`compose.yml` + the regression fixture).

### Note on the Task-1 fixture

The fixture must seed `.claude/settings.local.json` into its test worktree (mirroring
worktree-sync) so it exercises the **marketplace-resolution** regression rather than the
raw-`git worktree add` enablement artifact. Without that seed the fixture would test a
condition production never hits.
