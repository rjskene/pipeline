# Release cadence (this repo only)

This repo uses a **two-branch model** with [release-please](https://github.com/googleapis/release-please): `staging` is the dev trunk where feature PRs land; `main` is the release branch that release-please tracks.

## How a release happens

1. Feature PRs merge to `staging` using Conventional Commits (`feat:`, `fix:`, `chore:`, etc.). CI runs on every push to `staging` and on PRs.
2. When ready to release, open a PR `staging` → `main` and merge-commit it (`gh pr merge --merge`) — fast-forward is acceptable when branches are linear, but merge-commits are the canonical path because they preserve per-PR conventional-commit history for release-please.
3. On every push to `main`, the `release-please` workflow (`.github/workflows/release-please.yml`) opens — or updates — a Release PR titled `chore(main): release X.Y.Z`. The Release PR bumps `version` in `.claude-plugin/plugin.json` and both `metadata.version` and `plugins[0].version` in `.claude-plugin/marketplace.json` (synced via `extra-files` in `release-please-config.json`), and appends to `CHANGELOG.md`.
4. Merge-commit the Release PR (`gh pr merge --merge`). release-please then creates the `vX.Y.Z` git tag and a corresponding GitHub Release automatically.
5. Back-sync to staging happens automatically — the back-sync-release workflow (`.github/workflows/back-sync-release.yml`) merges the release commit onto staging (`--ff-only` when possible; `-X theirs` strategy-option when staging has overlapping work, so main wins on collisions — release-please's version-manifest bumps on main are strictly newer than staging for the files they touch) on every push to `main` matching `chore(main): release …`. On a true delete/modify conflict that `-X theirs` cannot resolve, it opens a draft PR `release-back-sync/<sha>` against staging for human resolution instead of failing the workflow.
6. **Reload the plugin** so subsequent dogfood sessions pick up the new code:
   ```
   /plugin uninstall pipeline@claude-pipeline
   /plugin install   pipeline@claude-pipeline
   ```
   (If installed via a local marketplace pointing at the working tree, no reload is needed — every edit is already live.)

The previous five-step manual ritual (release branch, manual version bumps, hand-written tag, hand-written GitHub Release) is gone — release-please owns version bumps, tags, and the GitHub Release. Back-sync is now fully automated via the back-sync-release workflow; the merge to staging happens without human intervention on the clean path, and only true delete/modify conflicts open a draft fallback PR. The merge strategy is asymmetric between directions: `staging → main` uses `-X ours` (staging is strictly newer in that direction); `main → staging` uses `-X theirs` (main is strictly newer on every file the release commit touched). #205 fixed the regression where #200 had naively used `-X ours` for both directions.

## Dev/prerelease channel

The `Release-As:` footer mechanism for cutting prereleases is preserved — it correctly marks the GitHub Release as a prerelease and applies the `-rc.N` tag suffix via release-please. The dev marketplace (`claude-pipeline-dev`) has been **retired**: opt-in to a new version already lives at the `/plugin install` layer (a stable consumer only picks up a new version when they explicitly run `/plugin uninstall` + `/plugin install`), so the dual-marketplace gate added no real protection beyond what the install action itself provides. Mental model: **if you don't want an RC, don't reinstall.**

1. **Trigger (LOCKED).** To cut an RC, open a `staging → main` PR and merge it with `gh pr merge <N> --merge --body-file <path-to-body-with-Release-As-footer>` where the body file contains a `Release-As: X.Y.Z-rc.1` footer (substitute the target version). Using the GitHub web merge UI is acceptable ONLY if the merge-commit body preserves the `Release-As:` footer verbatim; `gh pr merge --merge --body-file` is the canonical path and writes the body file to the merge-commit message reliably. release-please reads the footer on the resulting merge commit on `main` and opens an RC Release PR instead of a stable one. Verify post-merge with `git log -1 --pretty=%B main | grep -q "Release-As:"`.
2. **Versioning.** RCs follow SemVer prerelease (`MAJOR.MINOR.PATCH-rc.N`), enabled by `prerelease: true` + `prerelease-type: "rc"` in `release-please-config.json`. One release-please run bumps `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, and `.release-please-manifest.json` atomically via `extra-files`.
3. **Graduation.** Prereleases do NOT auto-graduate. To cut the stable `X.Y.Z`, the `staging → main` merge MUST be `gh pr merge <N> --merge --body-file <body-with-Release-As-footer>` (body contains `Release-As: X.Y.Z`). The merge-commit doctrine preserves per-PR `feat:`/`fix:` commits on `main` (reachable via the second parent), so release-please enumerates one entry per merged feature PR — the merge-commit subject — in the CHANGELOG rather than emitting `No user facing commits found` (see [granularity scope decision](#granularity-scope-decision-492) for why within-PR sub-commits are out of scope; the v0.14.0 stable-cut failure mode under the legacy squash regime had the squash subject `release: vX.Y.Z (staging → main)` — not a Conventional Commit type). The `Release-As:` footer is still required to flip prerelease→stable — without it, release-please opens a Release PR but does not graduate. RC and stable are mutually exclusive per `staging → main` PR. **Recovery.** If a no-footer merge already landed on `main`, open a follow-up empty `chore(release): graduate vX.Y.Z` PR whose body carries a `Release-As: X.Y.Z` footer to nudge release-please. After the tag lands, run `gh release edit vX.Y.Z --prerelease=false --latest` to flip the sticky prerelease flag (`release-please-config.json` has `prerelease: true`, so the flag persists across stable cuts until manually cleared).
4. **Fallback (Risks).** If `Release-As:` footers fail to trigger in release-please v4 simple mode, the documented fallback is the `autorelease: pre-release` label on the live Release PR. Both satisfy the issue's "either footer or label" requirement; the canonical path is the footer.
5. **Consumer cleanup (one-time).** Anyone who previously installed via the dev channel should run `/plugin uninstall pipeline@claude-pipeline-dev` followed by `/plugin marketplace remove claude-pipeline-dev` to unregister the now-orphaned manifest. The next `/plugin install pipeline@claude-pipeline` picks up the stable channel.

## Migration & rollback

This repo flipped from squash to merge-commits on 2026-05-24 via #459. Baseline before-picture: `.claude/logs/issue-459-baseline.md` (gitignored; on the dogfood host).

- **Trigger.** release-please v4 emitted `Considered 1 commit` / `No user facing commits found` against v0.14.0 stable because the `staging → main` squash collapsed the staging branch's conventional commits into one non-conventional release subject on `main`. v0.14.1 and v0.14.2 reproduced the same single-line CHANGELOG (a lone `release:` / `Miscellaneous Chores` entry).
- **Why merge-commits fix it.** Under `gh pr merge --merge`, each feature PR's `feat:`/`fix:` commits remain reachable from `main` via the merge's second parent. release-please walks the commit graph through merge parents (via the GitHub GraphQL API — it does not read local git, so a `--repo-url file://<dir>` dry-run cannot reproduce this and is not a valid local verification; see `tests/test-release-please-changelog-fixture.sh`), so it enumerates one entry per merged feature PR — keyed on the merge-commit subject — in the projected CHANGELOG (see [granularity scope decision](#granularity-scope-decision-492)).
- **Verification.** The first stable release cut after #459 MUST produce a CHANGELOG section enumerating individual `feat:`/`fix:` entries. If that cut still produces a one-line `Miscellaneous Chores` / single `release:` entry, the hypothesis is invalid: apply the rollback below and reopen #459.
- **Rollback path.**
  1. Re-enable the merge methods at the repo level: `gh api -X PATCH repos/rjskene/pipeline -f allow_squash_merge=true -f allow_rebase_merge=true`.
  2. Revert the source-flip commits (Tasks 2, 3, 4, 4b of #459) with `git revert <sha>...`.
  3. Inverse-or-remove the regression guards `tests/test-release-merge-strategy.sh` and `tests/test-back-sync-trigger-pattern.sh`.

### Granularity scope decision (#492)

**Context.** v0.16.0-rc.1 produced exactly one CHANGELOG entry for PR #484 even though that PR carried five conventional sub-commits. This is the intended behavior of the per-PR granularity contract, not a regression: the merge-commit subject is the source of truth, and PR #484's single merge-commit subject became the single CHANGELOG line.

**Why sub-commits collapse.** release-please's simple-mode projection walks `--first-parent` from the release tip. On that line a merged feature PR appears as ONE commit — its merge-commit subject — while the per-sub-commit conventional subjects live only on the merge's second parent (the full DAG), unreachable to a `--first-parent` walk. So a five-commit PR yields one CHANGELOG entry, keyed on the merge-commit subject. (This is the property characterized hermetically in `tests/test-release-please-changelog-fixture.sh`.)

**Rejected alternatives** — each pays a real cost for sub-commit granularity the pipeline does not need (PATH B plans already emit single-purpose commits at the merge-commit-subject level; PATH C plans can be split into multiple PRs when sub-commit granularity matters):

- **`manifest mode`** — release-please does not support a per-PR config that explodes a merge commit into its sub-commits; the workaround would re-author commits post-merge and introduce a new failure mode.
- **`custom walker`** keyed on PR number — replaces the release-please projection entirely and forfeits the version-bump atomicity that `extra-files` provides.
- **`richer commit-message walker`** that follows all merge second-parents — not configurable in release-please v4 simple mode; adopting it would mean forking the action.

**Decision:** per-PR granularity is the contract; sub-commit granularity is **out of scope**.

**When the assumption breaks.** If a PATH C plan emits many distinct `feat:` sub-commits within a single PR and each deserves its own CHANGELOG line, the planning-time mitigation is to either split the work into multiple PRs (one CHANGELOG-worthy change per PR) or accept the parent merge-commit subject as the single enumerated entry. Do not reach for the rejected alternatives above without first reopening #492 and swapping the decision text here and the CLAUDE.md line-29 framing.
