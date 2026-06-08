# Codex dogfood setup

The Codex-harness counterpart to [docs/dogfood-setup.md](dogfood-setup.md). Where the Claude Code dogfood install wires a local-marketplace plugin and a `SessionStart` hook, the Codex harness keys everything off `~/.codex/config.toml` plus the repo-local `.codex/` manifest bundle. This guide is the one-time bootstrap to run the pipeline under Codex (`PIPELINE_HARNESS=codex`).

CC and Codex bootstraps diverge enough — hook trust keyed to script hash, the `[features] multi_agent` gate, TOML-shaped MCP wiring — to warrant a sibling guide rather than bloating the CC one.

## Why a separate harness

The pipeline's single point of platform divergence is `scripts/platform.sh`, which exports `PIPELINE_HARNESS=claude|codex`. Every later platform branch keys off that variable; nothing else hard-codes a harness. Detection precedence: the `pipeline.config` `PIPELINE_HARNESS` override (authoritative, read by grep) → an env sniff (`CODEX_HOME` present ⇒ codex) → default `claude`. So setting `PIPELINE_HARNESS=codex` in `pipeline.config` is the authoritative switch.

## Prerequisites

- **Codex CLI** installed and on `PATH` (`codex --version`). Doctor's `codex_installed` check fails when it is absent.
- **`gh`** authenticated (`gh auth status`) — the GitHub surface is harness-neutral and shared with the CC install.
- A clone of this repo. The repo-local `.codex/` bundle (the committed Codex manifest) ships with the tree.

## Bootstrap

### 1. Select the Codex harness

In `pipeline.config` (host-specific, gitignored), set:

```bash
PIPELINE_HARNESS=codex
```

This is the authoritative override read by `scripts/platform.sh`. With it set, `/pipeline:doctor` emits the Codex-mode `CHECK:` lines (all gated behind `PIPELINE_HARNESS=codex`; Claude Code runs emit none).

### 2. Enable multi-agent in `~/.codex/config.toml`

PATH C fans out via the Codex `spawn_agent` surface, which requires the `multi_agent` feature. Merge into your personal `~/.codex/config.toml`:

```toml
[features]
multi_agent = true
```

Doctor's `codex_multi_agent_enabled` check (FAIL grade) scans for an enabled `multi_agent = true` under the `[features]` header.

### 3. Wire the enforcement hooks (repo-local `.codex/config.toml`)

The repo ships `.codex/config.toml` — the Codex twin of `.claude-plugin/plugin.json`'s `hooks`. It runs the **identical** enforcement scripts under `hooks/` (`enforce-base-branch.py`, `enforce-path-c-delegation.py`, `block_deletions.py`, `restrict_paths.py`, `check-ci-skip-markers.py`, `enforce-ci-wait.py`) via the path-agnostic `hooks/_run.sh` launcher, so the committed file is host-portable (no absolute paths). Note the Edit/Write → `apply_patch` collapse: Claude Code wires `enforce-path-c-delegation.py` on two file-mutation tools (`Edit`, `Write`); Codex performs all edits through the single `apply_patch` tool, so those collapse into one wiring.

Doctor's `codex_hooks_wired` check (FAIL grade) verifies ≥1 `[[hooks.*]]` table-array references a load-bearing enforcement hook.

### 4. Trust the hooks (the one-time `/hooks` re-trust)

Codex keys hook trust to the script **hash** and revokes trust whenever a wired script is edited. So after a `git pull` lands a hook change, run the one-time `/hooks` re-trust in the Codex session. For unattended pipeline automation (`codex exec`), pass `--dangerously-bypass-hook-trust` so a hash change does not wedge the run.

Doctor's `codex_hooks_trusted` check is **WARN-grade and never fails** — trust thrashes on dogfood, so a fail would block a correctly-configured host. It passes only when a managed trust marker is detectable on disk; otherwise it warns with this remediation.

### 5. Add the Playwright MCP server

For browser-driven verification (`visual-proof-from-plan`), merge the MCP block (mirrors `.mcp.json`'s `mcpServers.playwright`) into `~/.codex/config.toml`:

```toml
[mcp_servers.playwright]
command = "npx"
args = ["-y", "@playwright/mcp@0.0.75"]
```

Doctor's `codex_mcp_reachable` check is **WARN-grade** (MCP gates only `visual-proof-from-plan`; absence is non-fatal). It scans for an `[mcp_servers.*]` table — static validation only, no live connect.

### 6. Run the doctor and read the Codex CHECK lines

```bash
codex   # then: /pipeline:doctor
```

Confirm the Codex-mode lines are green:

```
CHECK: codex_installed status=pass ...
CHECK: codex_multi_agent_enabled status=pass ...
CHECK: codex_hooks_wired status=pass ...
CHECK: codex_hooks_trusted status=pass|warn ...
CHECK: codex_mcp_reachable status=pass|warn ...
```

`codex_hooks_trusted` and `codex_mcp_reachable` may legitimately read `warn` (trust undetectable; MCP optional) without blocking — only `fail` rows red the run.

### 7. First-run validation — confirm the gates actually BLOCK (issue #994)

A green doctor confirms the hooks are *wired*, not that they *block*. Codex's PreToolUse contract treats **exit 2** as the block signal, but two ported Bash gates — `block_deletions.py` and `enforce-base-branch.py` — currently exit **1**. Before relying on enforcement under Codex, prove each gate blocks a real attempt:

- a destructive command (e.g. `rm -rf …` or a clobbering `>`) → `block_deletions` must block;
- a `git push` / PR against the wrong base → `enforce-base-branch` must block;
- an out-of-boundary or protected-path `apply_patch` → `restrict_paths` must block.

If the exit-1 gates do **not** block on Codex, that is the **#994** parity gap: they must be aligned to the exit-2 (or `{"decision":"block"}`) contract before Codex enforcement is trustworthy. The exit-2 gates (`restrict_paths`, `enforce-path-c-delegation`, `enforce-ci-wait`) are unaffected.

## Namespace boundary

The same boundary discipline the pipeline enforces for the consumer's `.claude/` applies to the consumer's per-user Codex surface. The pipeline writes **nothing** to `~/.codex/{hooks,prompts,agents}/` or the user config under `~/.codex/` — doctor only **reads** those to validate the install. CI enforces this via `scripts/check-no-consumer-codex-writes.sh` (the Codex twin of `check-no-consumer-claude-writes.sh`); any source reference to the consumer Codex namespace requires a justified entry in `tests/no-consumer-codex-writes.allow`. The repo-local `.codex/` bundle is the pipeline's OWN committed artifact and is exempt.

## See also

- [docs/dogfood-setup.md](dogfood-setup.md) — the Claude Code dogfood install.
- [docs/plugin-architecture.md](plugin-architecture.md) — plugin layout and doctor states.
- `scripts/platform.sh` — the harness-detection primitive.
- `.codex/config.toml` — the committed Codex manifest (hooks + MCP template).
