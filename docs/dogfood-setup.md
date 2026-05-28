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

Expected: `~/claude-pipeline` (the repo working tree). NOT a cache
subdirectory under `~/.claude/plugins/cache/...`.

If you see a cache path instead, the local-marketplace install fell
back to a copy. File a follow-up issue and consult the
**`_resolve-plugin-root.sh` compatibility** section.

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

## `_resolve-plugin-root.sh` compatibility (open follow-up)

`scripts/_resolve-plugin-root.sh` reads
`~/.claude/plugins/installed_plugins.json` and uses each entry's
`installPath`. For a local marketplace, `installPath` should equal the
repo working tree. If Claude Code creates a cache copy regardless of
source type, the resolver may need a small patch to detect a
local-source marketplace and re-route to `installLocation` from
`known_marketplaces.json`. Out of scope for issue #611; flagged here
so the next dogfood operator knows where to look.

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
