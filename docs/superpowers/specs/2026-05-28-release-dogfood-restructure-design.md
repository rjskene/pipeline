# Release & dogfood restructure — design

**Date:** 2026-05-28
**Source brainstorm:** #589 (chore(release-please): pattern smoothing diary — graduation friction, revert PRs, manual back-sync)
**Status:** Design — pending user review before plan

## Problem

Six+ auto-memory entries document escape routes around release-please failure modes (`hand_cut_graduation_flow`, `hand_cut_rc_from_stable`, `release_as_minor_bump_override`, `release_graduation_squash_footgun`, `stable_cut_prerelease_flag`, `plugin_root_stale_audit`, `dogfood_skills_load_from_cache_not_repo`). The accretion is itself the signal — the release tooling is fighting the cadence rather than serving it. Today's v0.20.1 stable cut, after PR #607 spawned (sticky-prerelease override) and PR #609 spawned (backward-reconciliation), is the most recent live exhibit.

Two distinct things have been conflated into one release stream:

1. **Source-of-truth lifecycle** — `staging → main` flow with PR review + CI gates. This is what release-please was actually adopted for.
2. **Distribution channel** — what version a consumer sees when they `/plugin install`. RCs got bolted onto this stream via `prerelease: true`, which works only when the latest tag is itself a prerelease. The moment the line graduates to stable, the next RC has no anchor and release-please opens a backward-reverting PR.

The dogfood mechanism amplifies the friction: dogfood (= this repo's operator) consumes the plugin via the same `/plugin install` path as consumers, which means every dev cycle requires `/plugin uninstall + install` ceremonies and a 39-deep cache directory under `~/.claude/plugins/cache/claude-pipeline/pipeline/` that has misresolved `${CLAUDE_PLUGIN_ROOT}` to a stale 0.9.0 cache as recently as the audit pass that filed #595.

## Goals

1. **Eliminate RC machinery.** No more `-rc.N` tags, no more `Release-As:` footers, no more backward-reverting release-please PRs.
2. **Decouple dogfood from `/plugin install`.** Dogfood loads from the repo working tree directly; `git pull origin staging` is the deploy mechanism.
3. **Keep release-please for stable cuts.** Strip RC configuration so release-please runs in its happy-path linear-stable mode; reuse its CHANGELOG generation, atomic manifest bumps, and PR-based release review.
4. **Conservative version bumping.** Pre-1.0, `feat:` → patch and `feat!:` → minor. No 1.x.x cut until explicit graduation.
5. **Retire the memory entries** that document RC-specific escape hatches — they become historical once the regime that produced them is gone.

## Non-goals

- Reorganizing how feature PRs flow through `staging` (unchanged).
- Changing the worktree-per-issue execution model (unchanged).
- Changing the auto back-sync workflow (still needed for stable cuts; trigger pattern `chore(main): release ` continues to fire).
- Touching consumer-facing install instructions (`/plugin install pipeline@claude-pipeline` continues to work and continues to read from `main`).
- Retroactively deleting existing `-rc` tags (they represent real prior state; preserved as history).

## Design

### Architecture

```
feature/* ─PR─▶ staging ─cut─▶ main
                  │             │
            (working tree;      (release-please tracks;
             dogfood reads      stable cuts only)
             from here)              │
                  ▼                  ▼
            dogfood operator   consumer /plugin install
            (local file://     (GitHub marketplace)
             marketplace)
```

Two branches, two distribution channels, each with a strictly linear version history. The channels never collide: consumers read from `main` (only stable tags ever land there), dogfood reads from `staging` (working-tree live, no tag dependency).

### Branch & release topology

- **`staging`** — dev trunk. Feature PRs merge here via Conventional Commits (`feat:`, `fix:`, `chore:`, etc.). CI runs on every push to `staging` and on PRs.
- **`main`** — stable release branch. release-please tracks `main`. The only commits that land on `main` are `staging → main` merge-commits (for batched stable cuts) and release-please's own `chore(main): release X.Y.Z` commits.
- **No RC tags.** Drop `prerelease: true` and `prerelease-type: "rc"` from `release-please-config.json`. release-please runs in plain linear-stable mode.

#### Release flow

1. Feature PRs merge to `staging` with Conventional Commits. CI runs.
2. When ready to ship: operator opens a `staging → main` PR. Merge-commit it (`gh pr merge --merge`). Per-PR conventional commits remain reachable via the merge's second parent (the per-PR granularity contract from #459 still holds).
3. On push to `main`, release-please opens — or updates — `chore(main): release X.Y.Z`. The Release PR bumps `version` in `.claude-plugin/plugin.json` and the two locations in `.claude-plugin/marketplace.json`, appends to `CHANGELOG.md`, and updates `.release-please-manifest.json`.
4. Operator merges the Release PR (`gh pr merge --merge`). release-please creates the `vX.Y.Z` git tag and the GitHub Release automatically.
5. Back-sync to staging auto-fires via `.github/workflows/back-sync-release.yml` (the existing trigger `contains(commit.message, 'chore(main): release ')` continues to match).

No `Release-As:` footers, no hand-cuts, no PR ceremonies for prereleases.

#### Version-bump conservatism

`release-please-config.json` retains both:

- `"bump-minor-pre-major": true` — pre-1.0, `BREAKING CHANGE` / `feat!:` → minor (NOT major). Locks "no 1.0 cut until explicit graduation."
- `"bump-patch-for-minor-pre-major": true` — pre-1.0, `feat:` → patch (NOT minor). Locks "feat → patch only."

Behavior starting from 0.20.1:

| Commit type | Bump |
|---|---|
| `fix:` | 0.20.1 → 0.20.2 |
| `feat:` | 0.20.1 → 0.20.2 |
| `feat!:` / `BREAKING CHANGE:` | 0.20.1 → 0.21.0 |

Multiple breaking changes within one release cycle bump minor exactly once (standard release-please behavior, not custom).

**Graduating to 1.0** (future, not now): set both flags to `false` and push to `main`. The first cut after the flip honors default semver (`feat!:` → 1.0.0). Single-PR change; no hand-cutting.

### Dogfood: local file:// marketplace

#### One-time per-host bootstrap

A new script `scripts/setup-dogfood-local.sh` does this idempotently:

1. **Register the local marketplace** by adding an entry to `~/.claude/plugins/known_marketplaces.json`:
   ```json
   "claude-pipeline-local": {
     "source": { "source": "local", "path": "<repo-root>" },
     "installLocation": "<repo-root>",
     "lastUpdated": "<iso-ts>"
   }
   ```
   The exact source-schema (`"local"` vs `"file"` vs an object form) needs verification against Claude Code's marketplace schema during plan-time research.
2. **Uninstall the GitHub-sourced install** if present: `/plugin uninstall pipeline@claude-pipeline`.
3. **Install from local**: `/plugin install pipeline@claude-pipeline-local`.

After bootstrap, every `git pull origin staging` in the repo directory is live — no `/plugin install` ceremony.

#### Mutually exclusive with the GitHub install

The operator has exactly one pipeline plugin install at a time. `setup-dogfood-local.sh` uninstalls `pipeline@claude-pipeline` if present. Two paired helper scripts let the operator swap:

- `scripts/dogfood-mode.sh` — switches to `pipeline@claude-pipeline-local`. The default state for the dogfood operator.
- `scripts/consumer-mode.sh` — switches to `pipeline@claude-pipeline`. Used when consumer-testing the published stable channel.

#### Plugin discovery + skill loading

After local install, the marketplace's `installLocation` IS the repo working tree itself (no cache copy). `${CLAUDE_PLUGIN_ROOT}` resolves to the repo directory; plugin loader reads `skills/`, `scripts/`, `agents/` from the working tree on every startup.

This collapses three failure modes:

- **`plugin-root-stale-audit`** — gone. Only one resolved path; no multi-version cache directory to misresolve.
- **`dogfood-skills-load-from-cache-not-repo`** — gone. The cache IS the working tree.
- **Post-merge `/plugin uninstall + install` ceremony** — gone.

#### Version semantics in dogfood

The version reported by dogfood comes from `marketplace.json` on the checked-out branch. So immediately post-cut, staging at `v0.20.2`'s commit shows `0.20.2`; subsequent feature merges past the tag still report `0.20.2` until the next cut. This is intentional — the reported version pins the BASE the dev work is built on, useful for bug reports and audit. The true tip is always `git log -1` away.

#### Pipeline worktrees are unchanged

`.claude/worktrees/wt-N-slug/` (pipeline issue worktrees) remain separate git working trees on feature branches. They do NOT each get their own dogfood plugin install — `known_marketplaces.json` is host-global, and `${CLAUDE_PLUGIN_ROOT}` resolves to the same place for every session on this host: the main checkout on staging.

Implication: an executor running in `feature/foo`'s worktree sees `staging`'s version of skills/scripts, NOT the worktree's local edits to those files. This is the same isolation we have today (cache-version pins the snapshot for everyone), shifted up from "main's last release tag" to "staging's current tip." An executor that modifies a skill file in its own worktree does NOT see that modification loaded in its own session — the loaded skill came from the main checkout. This matches today's behavior; calling it out so future-us doesn't debug "why didn't my skill edit take effect in the same session?"

### Dogfood auto-refresh

Two layers, both strictly dogfood-only (live in this repo's dogfood territory, not bundled into the published plugin):

#### Layer 1: SessionStart hook (automatic)

Add a `SessionStart` block to dogfood-only `.claude/settings.json` (the same file that already registers the dogfood-only PreToolUse / UserPromptSubmit / PostToolUse hooks):

```json
"SessionStart": [{
  "matcher": "*",
  "hooks": [{
    "type": "command",
    "command": "bash ${CLAUDE_PROJECT_DIR:-.}/dev/hooks/dogfood-refresh.sh"
  }]
}]
```

Fires once per session. Pull failure (no network, non-FF state, etc.) logs but never blocks session start.

#### Layer 2: Manual command (operator-driven)

The same `dev/hooks/dogfood-refresh.sh` script is operator-runnable directly:

```bash
bash dev/hooks/dogfood-refresh.sh
```

Used mid-session when the operator knows a merge just landed and doesn't want to wait for the next session start. The `dev/` path follows the existing `dev/hooks/audit-on-pipeline-run.sh` convention from the current `.claude/settings.json` — the path itself marks dogfood-only intent.

#### Why both layers

The SessionStart hook covers all entry paths (pipeline:*, brainstorming, doctor, ad-hoc) without per-skill plumbing. The manual command closes the gap for long-lived sessions where merges happen mid-session — analogous to how RC cuts today are operator-driven verbs, not automatic background activity.

#### Dogfood-only enforcement

- `.claude/settings.json` is dogfood-only by convention (its own `_comment` field explicitly says so; consumer plugins don't register hooks via the consumer's `settings.json`).
- `dev/hooks/dogfood-refresh.sh` lives under `dev/`, not under `skills/` or `scripts/` (which ARE bundled into the published plugin).
- No pipeline `:run` / `:fullsend` / etc. skill invokes the dogfood-refresh script — it's only fired by the hook and by operator hands.
- The published plugin manifest doesn't need touching.

### Migration

#### Repo file changes

| File | Change |
|------|--------|
| `release-please-config.json` | Remove `"prerelease": true` and `"prerelease-type": "rc"` ONLY. Keep `"bump-minor-pre-major": true` and `"bump-patch-for-minor-pre-major": true` — they encode the conservative bump policy and are independent of RC machinery. |
| `.release-please-manifest.json` | Unchanged — still release-please's source of truth. |
| `.github/workflows/release-please.yml` | Unchanged (still triggers on push to main). |
| `.github/workflows/back-sync-release.yml` | Unchanged (trigger pattern `chore(main): release ` continues to fire on stable cuts). |
| `docs/release-cadence.md` | Delete "Dev/prerelease channel" section, "Starting / advancing an RC line or graduating from an established stable base (manual cut)" subsection, and Release-As: footer mechanics. Retain "How a release happens" (already linear), Breaking changes note, granularity scope decision (#492). Add a "Version-bump policy" subsection naming the two pre-1.0 flags and the future 1.0 graduation procedure. |
| `.claude/settings.json` | Add the SessionStart hook block (dogfood-only). |
| `dev/hooks/dogfood-refresh.sh` | New. Idempotent `git pull --ff-only origin staging` in the repo directory; logs to `.claude/logs/dogfood-refresh.log` if logging is enabled; exits 0 on no-op or failure. |
| `scripts/setup-dogfood-local.sh` | New. One-shot per-host bootstrap; registers local marketplace, runs the uninstall+install swap. |
| `scripts/dogfood-mode.sh` | New. Operator helper to swap to local install. |
| `scripts/consumer-mode.sh` | New. Operator helper to swap to GitHub install (consumer testing). |
| `docs/dogfood-setup.md` | New. Per-host bootstrap docs. Reference from CLAUDE.md. |
| `CLAUDE.md` | Update "Branches" section: drop `prerelease channel` framing, simplify release-cadence pointer. Update dogfood framing to point at the new file:// mechanism. |

#### Memory cleanup

Becomes historical / contradicted:

- `feedback_hand_cut_graduation_flow` → delete (no RCs to graduate from).
- `feedback_hand_cut_rc_from_stable` → delete (no RC cuts).
- `feedback_release_as_minor_bump_override` → delete (no `Release-As:` footer flow).
- `feedback_stable_cut_prerelease_flag` → delete (no `prerelease: true` to flip off).
- `feedback_release_graduation_squash_footgun` → delete (no graduation procedure with that shape).

Retained / updated:

- `feedback_release_back_sync` — keep (back-sync workflow still fires on stable cuts).
- `feedback_pipeline_root_stale_audit` — keep with `historical: post-2026-05-28-dogfood-local` annotation (bug shape is gone but the lesson — audit repo files, not cache — applies for any future cache-based scenarios).
- `feedback_dogfood_skills_load_from_cache_not_repo` — rewrite to "dogfood loads from working tree; `git pull origin staging` in repo dir = live."
- `feedback_dogfood_instrumentation_no_consumer_crud` — keep (still valid — `dev/` and dogfood `.claude/settings.json` remain the right place for operator-only instrumentation).

#### Tag history

No retroactive tag deletion. `v0.20.1-rc.1`, `v0.19.0-rc.{1,2,3}`, etc. stay as-is — they represent real prior state. New invariant: no `vX.Y.Z-rc.N` tags going forward.

#### Issue cleanup

- **#589** — close with comment linking to this spec, after the implementation lands.
- **#541** (Release-As drops -rc) — close if still open; no longer applicable.

### Rollback

If the local-marketplace approach has a fatal flaw not surfaced in plan-time research (Claude Code's marketplace schema rejecting `"source": "local"`, plugin loader misbehavior, etc.), rollback is purely dogfood-side:

1. Revert the PR's changes to `release-please-config.json` (restores `prerelease: true`, RC machinery returns).
2. Remove the SessionStart hook block from `.claude/settings.json`.
3. Operator runs `/plugin uninstall pipeline@claude-pipeline-local && /plugin install pipeline@claude-pipeline`.
4. Re-instate the deleted memory entries from git history.

No tag changes, no published-plugin breakage. Consumers are unaffected through the rollback.

## Open items (research at plan time, not blocking design approval)

1. **Exact `source: local` schema** in `known_marketplaces.json` — `"local"` vs `"file"` vs an object form. Verify against Claude Code marketplace schema docs / source before writing `setup-dogfood-local.sh`.
2. **Plugin discovery order if both marketplaces are installed simultaneously** — verify Claude Code's loader semantics before committing to "mutually exclusive is required vs. recommended."
3. **Whether `${CLAUDE_PLUGIN_ROOT}` resolution requires updates to `scripts/_resolve-plugin-root.sh`** for the local-install case, or whether Claude Code handles it natively without that helper.
4. **Whether `setup-dogfood-local.sh` should detect and prompt before uninstalling `pipeline@claude-pipeline`** (in case the operator wants to keep both for some reason during a transition window).

## Acceptance criteria

A reviewer approves the implementation PR by confirming:

1. `release-please-config.json` no longer contains `"prerelease": true` or `"prerelease-type": "rc"`; still contains both `bump-*-pre-major` flags.
2. A new test (or doc check) asserts no `prerelease` field present in `release-please-config.json`.
3. `dev/hooks/dogfood-refresh.sh` exists, is executable, runs `git pull --ff-only origin staging` in the repo directory, and exits 0 on no-op or non-fatal failure.
4. `.claude/settings.json` registers the SessionStart hook pointing at `dev/hooks/dogfood-refresh.sh`.
5. `scripts/setup-dogfood-local.sh` exists, runs idempotently, and (after first run on the dogfood host) the operator's `~/.claude/plugins/known_marketplaces.json` contains a `claude-pipeline-local` entry with the correct `installLocation`.
6. After running `setup-dogfood-local.sh`, `${CLAUDE_PLUGIN_ROOT}` in a fresh session resolves to the repo directory (not a cache subdirectory).
7. `docs/release-cadence.md` no longer mentions RC cuts, `Release-As:` footers, hand-cut procedures, or graduation paths.
8. `docs/dogfood-setup.md` exists and provides a copy-paste path for a new dogfood host to bootstrap.
9. The auto-memory entries listed under "Memory cleanup" are deleted or updated as specified.
10. A real stable cut from staging tip (e.g. v0.20.2 once one or more `feat:` / `fix:` commits accumulate post-v0.20.1) produces a single linear-stable release-please PR with no spurious revert PRs after merge.
