# Dogfood install — local file:// marketplace

## What this is

The dogfood model loads pipeline assets from the repo working tree on
`staging`, not from a cache copy of a published release. That means
`git pull` on staging = live skill/script/hook updates in the very next
Claude Code session, with no `/plugin install` round-trip. The
`${CLAUDE_PLUGIN_ROOT}` environment variable resolves to the repo
checkout itself.

This install is mutually exclusive with the published GitHub install
(`pipeline@claude-pipeline`). Only one can be active at a time, but
the swap scripts `dogfood-mode.sh` / `consumer-mode.sh` make the
round-trip trivial — flip to the consumer install to reproduce a
user-reported bug, then flip back to keep iterating against the working
tree.

## Prerequisites

- Claude Code installed.
- The `claude-pipeline` GitHub marketplace already known (no-op if
  already present): `/plugin marketplace add rjskene/pipeline`.
- `jq` available on the host.

## One-shot bootstrap

```bash
git clone https://github.com/rjskene/pipeline.git ~/claude-pipeline
cd ~/claude-pipeline
bash scripts/setup-dogfood-local.sh
```

What it does (idempotent, re-run safe):

1. Adds a `claude-pipeline-local` entry in
   `~/.claude/plugins/known_marketplaces.json` whose `installLocation`
   is the repo working tree itself. The `source` is
   `{"source": "file", "path": "<abs-repo-root>"}` — the discriminator
   value Claude Code accepts for a local marketplace registration. See
   the **Schema fallback** subsection below for the history (the
   initial implementation in #611 guessed `"local"`, which Claude Code
   rejected at `/plugin install` time; #617 corrected it to `"file"`).
2. Removes any cached `pipeline@claude-pipeline` install entries from
   `~/.claude/plugins/installed_plugins.json` so the published-install
   and dogfood-install do not collide.
3. Prints the exact manual command the operator must run next:
   `/plugin install pipeline@claude-pipeline-local`.
   - `/plugin` is interactive-only — scripts cannot drive it. The
     operator types this in a Claude Code session.

## Verification

In a fresh Claude Code session opened from `~/claude-pipeline`:

```bash
echo $CLAUDE_PLUGIN_ROOT
```

Expected: a path resolving to the repo working tree. Claude Code may
report a cache subdirectory under `~/.claude/plugins/cache/...`, but
that path is now a symlink to `~/claude-pipeline` (see **Symlink
verification** below). To confirm:

```bash
cd $CLAUDE_PLUGIN_ROOT && pwd -P
```

Expected: `~/claude-pipeline` (`pwd -P` resolves the symlink). If
instead `pwd -P` reports a cache subdirectory, the symlink hasn't
landed — open a fresh Claude Code session in `~/claude-pipeline` and
the SessionStart hook will self-heal it.

## Auto-refresh

Two layers, both backed by the same script
(`dev/hooks/dogfood-refresh.sh`):

**Layer 1 — SessionStart auto.** Every time you start a Claude Code
session in the dogfood repo, the SessionStart hook fires
`bash ${CLAUDE_PROJECT_DIR:-.}/dev/hooks/dogfood-refresh.sh` which runs
`git fetch + git merge --ff-only origin staging`. Idempotent,
fail-open, <2s on the no-op happy path.

**Layer 2 — Manual command.** For a mid-session refresh:

```bash
bash dev/hooks/dogfood-refresh.sh
```

Same script, same behavior. Logs to `.claude/logs/dogfood-refresh.log`
only when `PIPELINE_LOGS_ENABLED=true`; silent otherwise.

The hook exits 0 on EVERY failure mode (no network, dirty tree,
non-FF state, missing git). It MUST never block session start.

## Mode swap

```bash
bash scripts/dogfood-mode.sh    # back to local (re-runs setup-dogfood-local.sh)
bash scripts/consumer-mode.sh   # back to the published GitHub install
```

Use **consumer-mode.sh** when you want to verify behavior under the
published plugin (e.g. before a release, or when reproducing a
consumer-reported bug). Use **dogfood-mode.sh** when you're back to
iterating on the pipeline itself.

Each script prints its post-state (`current install: local|github ...`)
so you can verify at any time.

## Rollback

One command — `bash scripts/consumer-mode.sh`. It cleans the
local-install entries and prints the manual
`/plugin install pipeline@claude-pipeline` command.

## Schema fallback (research note)

The canonical `known_marketplaces.json` shape for a local marketplace is:

```json
{
  "claude-pipeline-local": {
    "source": {"source": "file", "path": "/abs/path/to/repo"},
    "installLocation": "/abs/path/to/repo",
    "lastUpdated": "<ISO-8601>"
  }
}
```

History: #611's initial implementation guessed
`source: {source: "local", path: ...}` by empirical analogy to the
existing `github` discriminator (e.g., the `claude-plugins-official`
entry uses `source: {source: "github", repo: "..."}`). Claude Code
rejected that shape at `/plugin install` time. #617 pinned the
verified-working discriminator to `"file"` — known-broken alternates
documented for posterity:

1. **Known-broken:** `source: {source: "local", path: "..."}` —
   rejected by Claude Code's marketplace-schema validation (#611's
   guess; #617's fix supersedes).
2. **Unverified fallback:** `source: {source: "local", url: "file:///abs/path"}` —
   never confirmed to work; preserved here only as a research note.

If a future Claude Code release rejects `"file"`, file a follow-up
issue with the rejection error so the canonical shape can be re-pinned
in `scripts/setup-dogfood-local.sh`.

## Symlink verification

Claude Code copies the repo into a cache subdirectory at
`/plugin install pipeline@claude-pipeline-local` time — a snapshot,
not a live view. To preserve the dogfood-as-live promise, the
SessionStart hook (`dev/hooks/dogfood-refresh.sh`) invokes
`dev/hooks/dogfood-symlink-swap.sh` as its last step. The helper reads
the `pipeline@claude-pipeline-local` entry from
`~/.claude/plugins/installed_plugins.json` whose `projectPath` matches
the resolved repo root and replaces that entry's `installPath`
directory with a symlink to the repo working tree. Idempotent + fail-open.

**Two heal layers (#624).** SessionStart alone left a mid-session gap:
if a plugin re-materialization wiped the cache dir between session
starts (observed when `/remote-control` connects), the symlink stayed
broken and `${CLAUDE_PLUGIN_ROOT}` for the local plugin 404'd until the
next session. The heal now fires on BOTH events:

- **SessionStart** — `dev/hooks/dogfood-refresh.sh` does the full
  `git fetch` + `merge --ff-only` and then invokes the swap helper.
- **UserPromptSubmit** — `dev/hooks/dogfood-heal-symlink.sh` re-asserts
  the symlink before every user turn. It is the *cheap* path: it
  delegates straight to `dogfood-symlink-swap.sh` (a `readlink`/`ln`,
  microseconds) and pays NO `git fetch`/`merge` cost. Silent, exit 0
  always, so it never blocks or pollutes the prompt.

This closes the mid-session gap without paying network cost per prompt.

**Manual detect path.** `scripts/doctor.sh` carries a
`dogfood_symlink_durable` check: when the
`pipeline@claude-pipeline-local` entry for this repo exists and its
`installPath` is missing (cache wiped) or a real directory (a
snapshot, not live), doctor records `warn` with a copy-pasteable heal
hint (`run: bash dev/hooks/dogfood-heal-symlink.sh`); it records `pass`
when the path is a live symlink to the repo, and emits nothing on
consumer installs (no local-marketplace entry). The `warn` never flips
doctor's exit code — a stale dogfood symlink is operator-only and
self-heals on the next prompt.

Operator check (one command):

```bash
readlink "$(jq -r '.plugins["pipeline@claude-pipeline-local"][0].installPath' ~/.claude/plugins/installed_plugins.json)"
```

Expected output: the absolute path of the repo working tree
(`~/claude-pipeline`). If the output is empty, the install path is
still a regular directory — open a fresh Claude Code session in
`~/claude-pipeline` to fire the SessionStart hook; the swap will land
automatically.

The cache directory path embeds the plugin version from
`.claude-plugin/plugin.json` (e.g.
`~/.claude/plugins/cache/claude-pipeline-local/pipeline/0.20.1`). On
a version bump, Claude Code installs a fresh directory; the helper
tracks whatever `installPath` `installed_plugins.json` reports, so the
bump is transparent — no per-version edit required.

## Worktree-aware resolution + projectPath export (#878)

The symlink-swap above is the *intended* wiring: `installPath` becomes a
symlink to the working tree, so resolving it yields the live tree. In practice
that swap is not guaranteed to have landed (the cache dir may be a stale plain
copy, or absent), and — more importantly — execute/eval subagents run from a
**worktree** (`<root>/.claude/worktrees/wt-<N>-<slug>`), not the main repo root.
Two consequences the default-mode tie-break in `scripts/_resolve-plugin-root.sh`
now handles directly, so dogfood resolution does not depend on the symlink being
healthy:

1. **Worktree `$PWD` is normalized to the main-repo root before matching.** The
   local install's `projectPath` is the MAIN repo, so a raw worktree `$PWD`
   never matched and the tie-break used to fall through to the stale published
   cache. The resolver strips at `/.claude/worktrees/` (var-independent primary
   rule; `git rev-parse --git-common-dir` fallback for worktrees elsewhere)
   before matching `projectPath`. A non-worktree `$PWD` normalizes to itself.

2. **The resolver exports the matched entry's `projectPath` (the live working
   tree), not its `installPath`.** On this host `installPath` is a stale cache
   copy, NOT the symlink the resolver header once claimed; `projectPath` is the
   live `staging` tree by construction. `installPath` is used only as a fallback
   when `projectPath` is missing/non-dir. This is what makes "git pull on
   staging = live skill updates" actually hold inside worktree subagents,
   independent of whether the symlink-swap hook has run.

The `## Boot` snippet shared across all plugin-root `SKILL.md` files also globs
the `claude-pipeline-local` cache ahead of the published `claude-pipeline` cache
when LOCATING the resolver, so the first resolver sourced on a dogfood host is
the live one rather than a stale published copy.

## When do edits go live? (session-cached skill bodies)

`git pull` on staging updates the skill/script FILES on disk immediately (the
symlink points at the working tree — no release/reinstall). But the files being
fresh on disk is NOT enough to make new *skill behavior* live in the **running
orchestrator session**:

- **Orchestrator's own `Skill()` invocations are session-cached.** A fresh
  `Skill(pipeline:fullsend)` call mid-session returns the body that was loaded at
  session start, even after merge+pull — the Skill tool does NOT re-read
  `SKILL.md` from disk. Stale until the session is **restarted** (restart, NOT
  reinstall — the symlink already points at the live tree).
- **Everything else reads fresh:** spawned `claude -p` workers (PATH B/C execute +
  evaluate), inline `Agent(subagent_type=...)` subagents whose prompt says "follow
  `skills/.../SKILL.md`", scripts (`plan-waves.sh`, `run-queue.sh`, …), and hooks
  (repo-rooted) all read the current on-disk file.

So: to test a just-merged change that lives in an **orchestrator-driven** skill
body (`run`/`status`, `fullsend` dispatch logic), restart the session after
merge+pull. Changes in worker-loaded skills (`execute-issue-plan`,
`evaluate-issue-pr`) or in scripts are live without restart. Do NOT trust a fresh
`Skill()` call to pick up on-disk edits mid-session.

## Memory cleanup (per-operator, outside this PR)

Auto-memory entries that describe the old cache-based dogfood model
live OUTSIDE this repo at
`~/.claude/projects/<host-mangled-path>/memory/`. After this PR lands
and your host is on the local marketplace, retire the stale memories
— these are operator-side state, not codebase changes:

- `feedback_dogfood_skills_load_from_cache_not_repo.md` — rewrite or
  delete; the cache-not-repo claim is no longer true on dogfood hosts.

The pipeline's `feedback_dogfood_instrumentation_no_consumer_crud`
guidance still applies — self-improvement work is repo-local
scripts+tests, NOT skill/runtime edits.
