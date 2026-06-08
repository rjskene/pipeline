# Codex dual-target — design

**Date:** 2026-06-08
**Topic:** Make the entire `claude-pipeline` plugin run on **OpenAI Codex CLI** as well as Claude Code, from a single source tree.
**Status:** Brainstorm complete; feeds an implementation plan (writing-plans). No issues filed yet.

## Decisions (locked during brainstorm)

| # | Question | Decision |
|---|----------|----------|
| D1 | Target shape | **Dual-target, one source.** Single codebase runs on both Claude Code (CC) and Codex via a runtime adapter layer. No fork. |
| D2 | Enforcement fidelity on Codex | **Full parity.** The safety/correctness gates must actually block on Codex, not degrade to advisory prose. |
| D3 | Codex surface | **Codex CLI only.** The IDE/cloud "Codex App" (Seatbelt sandbox, detached-HEAD worktrees that block `git checkout -b`/`push`/`gh pr create`) is **out of scope**. |
| D4 | Architecture | **Approach A — in-repo adapter.** Committed Codex manifests + hook config beside the CC ones; runtime platform detection. Codex dogfoods off the working tree exactly like CC. A publish-projection (`sync-to-codex.sh`) to a Codex marketplace is a **deferred follow-up** (Approach C), not part of this migration. |

## Motivation

The pipeline is a CI workflow built on Claude Code primitives: 17 skills (slash commands), the enforcement + observability hooks, native `Agent` subagent dispatch, MCP, `${CLAUDE_PLUGIN_ROOT}`. The real engine underneath — the GitHub-issue lifecycle, label flow, `gh`/git, and ~65 of ~70 bash scripts — is harness-agnostic. The migration is therefore an **adapter shell around an unchanged core**, not a rewrite.

## Grounding: Codex CLI is more capable than the precedents suggested

Verified against current Codex docs (`developers.openai.com/codex/hooks`, `/config-reference`) — newer than the assistant's training cutoff:

- **Codex has a native hooks system** with the same event vocabulary as CC: `PreToolUse`, `PostToolUse`, `PermissionRequest`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionStart`, `UserPromptSubmit`, `PreCompact`/`PostCompact`.
- **Block contract is cross-compatible.** Codex PreToolUse stdin is a *superset* of CC's (`session_id, transcript_path, cwd, hook_event_name, tool_name, tool_input, permission_mode` + `model, turn_id, tool_use_id`). A hook blocks via the **same** mechanisms CC uses: `{"decision":"block","reason":"…"}`, `{"hookSpecificOutput":{"permissionDecision":"deny",…}}`, or **exit code 2**. So the existing Python hooks block identically on both harnesses.
- **Matcher syntax** is a regex on tool name (`"^Bash$"`, `"Edit|Write"`, `"*"`) — same model as CC. **Codex maps CC `Edit`/`Write` → a single `apply_patch` tool.**
- **Multi-agent dispatch** via `[features] multi_agent = true` → `spawn_agent` / `wait_agent` / `close_agent` (the `Agent`/`Task` analog). `codex exec` is the non-interactive analog of `claude -p` for the `--spawn` transport.
- **Hook discovery:** `~/.codex/hooks.json`, `~/.codex/config.toml`, `<repo>/.codex/hooks.json`, `<repo>/.codex/config.toml`, and plugin bundles.
- **Hook trust model:** non-managed command hooks must be reviewed/trusted; trust is keyed to the script's hash and revoked on any edit. `requirements.toml` "managed" hooks are auto-trusted by policy. `--dangerously-bypass-hook-trust` runs hooks without persisted trust (for vetted automation).

### Precedent (superpowers, obra/superpowers + autoresearch)

Both ship a single source projected per-platform. **Superpowers explicitly excludes `hooks/` from its Codex bundle** — *not* because Codex can't run hooks, but because superpowers has none. The pipeline reaches D2 (full parity) through Codex's native hook system; git-wrapper shims become a fallback, not the primary mechanism. Useful borrowings: per-platform root files (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`), per-platform manifest dot-dirs (`.claude-plugin/`, `.codex-plugin/plugin.json` with `"skills"`+`interface{}`), `references/codex-tools.md` tool mapping, runtime read-only environment detection.

## Architecture

### Spine — one platform primitive

`scripts/platform.sh` exports `PIPELINE_HARNESS=claude|codex`. Detection order:

1. Explicit `PIPELINE_HARNESS` in `pipeline.config` (authoritative override).
2. Env sniff (`CODEX_HOME` present → codex; `CLAUDE_PLUGIN_ROOT` present → claude).
3. Default `claude`.

**Every platform branch in scripts and skills keys off this single variable.** Nothing else hard-codes a platform — this is the only source of divergence.

### Component map (authoritative)

| # | Coupling point | Codex mapping | Files touched | Adaptation |
|---|---|---|---|---|
| 1 | Platform detection | `PIPELINE_HARNESS` | new `scripts/platform.sh` | new |
| 2 | `${CLAUDE_PLUGIN_ROOT}` | `$CODEX_HOME` bundle glob | `scripts/_resolve-plugin-root.sh` | +branch |
| 3 | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` (`skills`+`interface`) | new committed file | new |
| 4 | 6 enforcement hooks (7 wirings) in `plugin.json` | `.codex/config.toml` `[[hooks.*]]` | new committed file | new wiring, same scripts |
| 5 | `restrict_paths`, `enforce-path-c-delegation` | `Edit`/`Write` → `apply_patch` matcher + tool-name | 2 hook scripts | widen branching |
| 6 | observability hooks (dogfood `.claude/settings.json`, **not** `plugin.json`) | `PostToolUse`/`SubagentStop` | 3 log scripts | +branch, opt-in |
| 7 | `Agent` tool dispatch | `spawn_agent`/`wait_agent`/`close_agent` | skill prose + dispatch scripts | tool-neutral + branch |
| 8 | `--spawn` (`claude -p`) | `codex exec` | new `spawn-codex.sh`, generalize caller | +transport |
| 9 | `tdd-implementer.md` agent | Codex subagent (prompt passed at spawn) | agent ref in skills | verify mechanism |
| 10 | `.mcp.json` (playwright) | `config.toml [mcp_servers.playwright]` | new Codex MCP block | reshape JSON→TOML |
| 11 | tool names in prose (Read/Bash/Grep…) | native + `references/codex-tools.md` | skill bodies | tool-neutral phrasing |
| 12 | `CLAUDE.md` | `AGENTS.md` (+ Codex preamble) | new file | new |
| 13 | hook trust model | managed-hook / `/hooks` trust / bypass flag | install docs + doctor | new install step |
| 14 | `pipeline.config`, ~65 bash scripts, gh/git engine | run as-is under Codex shell | — | **none** |

## Layer designs

### L2 — Enforcement (full-parity gates)

- **Same Python scripts, new wiring.** The shared block schema is honored by both harnesses, so no block-mechanism change. The 6 enforcement hooks (7 CC wirings → 6 on Codex, since CC's separate `Edit`+`Write` matchers collapse to one `apply_patch`) re-wire into `.codex/config.toml`:
  - `Bash` matcher → `block_deletions`, `enforce-base-branch`, `check-ci-skip-markers`
  - `apply_patch` matcher → `enforce-path-c-delegation` (CC's Edit+Write)
  - `*` → `restrict_paths`; `Stop` → `enforce-ci-wait`
- **Observability hooks (#6)** are dogfood-only and `PIPELINE_LOGS_ENABLED`-gated (wired in `.claude/settings.json`, not the published manifest). They port the same way — into a dogfood `.codex/config.toml` `PostToolUse`/`SubagentStop` matchers — but are lower priority; fold into a later leg or defer.
- **The one genuine code change (#5):** `restrict_paths.py` and `enforce-path-c-delegation.py` branch on `tool_name in {Edit,Write}` and read `tool_input.file_path`. Add a shared `_tool_input_paths(event)` helper (in an existing shared module, e.g. `hooks/_pipeline_config.py` or a new `hooks/_tool_input.py`) that returns the target path list for **both** CC `Edit`/`Write` (`file_path`) and Codex `apply_patch` (parse the patch's target file(s)). Both scripts call it → no divergent path logic.
- **Path-agnostic hook commands:** config.toml hook commands invoke `hooks/_run.sh <script>` (new tiny wrapper) which self-resolves the plugin root via `_resolve-plugin-root.sh`, so the committed manifest carries no host-specific paths.
- **Trust model (#13):** dogfood scripts change frequently, so hash-keyed trust would thrash. Resolution order:
  1. Prefer a repo-local **managed-hook** config (auto-trusted) **if** Codex permits a repo-local managed dir (VERIFY in planning).
  2. Else `doctor` surfaces untrusted/blocked hooks and documents the one-time `/hooks` re-trust.
  3. Automation paths (`fullsend`/`campaign` via `codex exec`) pass `--dangerously-bypass-hook-trust`.
- `enforce-comment-trust.py` is invoked by scripts (not wired in `plugin.json`); portable as-is, no wiring change.

### L3 — Dispatch

- **PATH A/B/D (inline):** the Codex orchestrator session executes the skill directly (no separate dispatch). Prose goes tool-neutral.
- **PATH C fan-out:** the per-leaf worktree split (`path-c-split-worktree.sh`) + cherry-pick reassembly are **unchanged bash/git**. Only the dispatch *call* branches — CC `Agent` ↔ Codex `spawn_agent` (collect with `wait_agent`, free with `close_agent`). Requires `[features] multi_agent = true` (added to install). Encapsulate the branch in one `dispatch-leaf` abstraction keyed on `PIPELINE_HARNESS`.
- **`--spawn` escape hatch:** add `scripts/spawn-codex.sh` → `codex exec` (non-interactive; sandbox/approval flags for autonomy; `--dangerously-bypass-hook-trust` as needed). The run-queue/caller selects transport by `PIPELINE_HARNESS` (CC keeps `spawn-claude.sh`).
- **tdd-implementer (#9):** its body is system-prompt/instructions prose → portable verbatim. Pass it as the `spawn_agent` instructions inline; register a named Codex subagent type only if Codex supports a registry (VERIFY).

### L4 — Skills & tool vocabulary

- Keep skills authored in **CC tool names** (the lingua franca) and ship `skills/.../references/codex-tools.md` (superpowers' mapping + pipeline extras: `apply_patch`, `spawn_agent`/`wait_agent`/`close_agent`, `codex exec`). AGENTS.md preamble points to it.
- Codex consumes the same `skills/` dir via `.codex-plugin/plugin.json` `"skills":"./skills/"` (native skill-loading). Thin `~/.codex/prompts/pipeline-*.md` slash-shims only if Codex needs them for slash-style invocation (deferred nicety).
- `${CLAUDE_PLUGIN_ROOT}` Boot blocks keep working via the `_resolve-plugin-root.sh` Codex branch — no per-skill edits to Boot logic.
- **AGENTS.md (#12):** a thin wrapper — Codex preamble (tool-map pointer; `multi_agent=true` required for PATH C; hook-trust note) then links/includes the CLAUDE.md content. **Not** a raw symlink (CLAUDE.md carries CC-only assertions).

### L5 — Manifest, MCP, install

- **`.codex-plugin/plugin.json`** mirrors the superpowers shape (name/version/description/author + `"skills"` + `interface{}`).
- **Version sync:** add `.codex-plugin/plugin.json` to release-please `extra-files` so it bumps in lockstep with `.claude-plugin/plugin.json` and both `marketplace.json` fields. The version-sync test asserts **equality across the now-4 manifest locations** (semver-shape regex), never a string literal — per the release-cadence "tests that self-destruct on the first release" gotcha.
- **MCP (#10):** a Codex `[mcp_servers.playwright]` TOML block in the `.codex/config.toml` template (required for `visual-proof-from-plan`).
- **Doctor Codex-mode:** checks Codex present, `multi_agent` enabled, hooks wired/trusted, MCP server reachable, base branch, `gh` auth — mirrors the CC doctor states.
- **Namespace discipline:** add `scripts/check-no-consumer-codex-writes.sh` mirroring `check-no-consumer-claude-writes.sh` (write nothing to consumer `~/.codex/` beyond a documented allow-list).

### L6 — Testing & CI

- The bash test suite runs under both harnesses. New/changed tests:
  - **Hook-parity test (linchpin):** assert `.claude-plugin/plugin.json` and `.codex/config.toml` wire the **identical hook-script set** (same scripts, equivalent matchers per the Edit/Write↔apply_patch mapping). Guarantees enforcement cannot silently diverge between harnesses.
  - `platform.sh` detection truth-table (override / env-sniff / default).
  - `_tool_input_paths()` unit: CC `Edit`/`Write` and Codex `apply_patch` both yield the right path list.
  - `_resolve-plugin-root.sh` Codex branch.
  - 4-file version-sync.
  - `spawn-codex.sh` transport smoke (mocked `codex exec`).
- **CI** adds a Codex-config-lint + parity job (static validation; running live Codex in CI is out of scope).

## Rollout — "one-shot" = one tracker run as a campaign

Ordered legs; **each keeps CC green (additive)** and is independently testable:

1. **Foundation** — `platform.sh`, `_resolve-plugin-root.sh` Codex branch, `_tool_input_paths()` helper. *(Pure additive; no CC behavior change.)*
2. **Enforcement** — `.codex/config.toml` hook wiring + `apply_patch` widening + hook-parity test + trust/install story.
3. **Manifest + MCP + AGENTS.md + version-sync.**
4. **Dispatch** — `spawn-codex.sh` + PATH C `spawn_agent` branch + tdd-implementer.
5. **Skills tool-neutral pass + `codex-tools.md`.**
6. **Doctor Codex-mode + namespace guard + docs.**
7. *(Deferred, Approach C)* publish-projection `sync-to-codex.sh` to a Codex marketplace.

**Critical path: 1 → 2 → 4.** The pipeline dogfoods its own migration: a `tracker` issue carries this `## Rollout sequence`, run via `/pipeline:campaign`.

## Known-unknowns to verify during planning (none are blockers)

1. **#1 detection signal** — exactly which env var Codex exports to hook/shell subprocesses. *Fallback:* explicit `PIPELINE_HARNESS` flag in `pipeline.config`.
2. **#9 subagent definition** — whether Codex consumes a named-agent registry or only inline `spawn_agent` instructions. *Fallback:* inline prompt (portable regardless).
3. **#13 repo-local managed hooks** — whether Codex allows a repo-local managed-hook dir (auto-trusted). *Fallback:* documented `/hooks` trust + bypass flag for automation.
4. **#10 apply_patch `tool_input` shape** — exact JSON for extracting target paths. Confirm against a live Codex `PreToolUse` payload before finalizing `_tool_input_paths()`.

## What does NOT change

The GitHub-issue lifecycle, label flow (`plan-pending → … → merged`), the `gh`/git engine, `pipeline.config`, ~65 of ~70 scripts, and the **intent** of every existing test. Claude Code behavior is preserved exactly — every change is additive and gated on `PIPELINE_HARNESS`.

## Out of scope

- Codex App (IDE/cloud sandbox) — D3.
- Publish-projection to a Codex marketplace for consumers — deferred (D4 / Approach C); committing `.codex-plugin/` in-repo makes it trivial later.
- Gemini / OpenCode / Cursor harnesses (the spine generalizes to them later, but they are not targeted now).
- Best-effort/sandbox-only enforcement — explicitly rejected by D2.
