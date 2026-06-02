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

### Version-bump policy

Pre-1.0, release-please uses two conservatism flags in `release-please-config.json`:

- `bump-minor-pre-major: true` — `feat!:` / `BREAKING CHANGE:` commits resolve to a minor bump (NOT major). Locks "no 1.0 cut until explicit graduation."
- `bump-patch-for-minor-pre-major: true` — `feat:` commits resolve to a patch bump (NOT minor). Locks "feat → patch only."

| Commit type | Bump |
|-------------|------|
| `fix:` | patch |
| `feat:` | patch |
| `feat!:` / `BREAKING CHANGE:` | minor |

Graduating to 1.0 (future, not now): set both flags to `false` and push to `main`. The first cut after the flip honors default semver (`feat!:` → 1.0.0). Single-PR change; no hand-cutting. Tag history is preserved — existing `-rc` tags stay as-is.

### Breaking changes

- Container-isolation opt-ins and the pre-spawn eval-classifier hook were removed in #514 (see that PR for the full list of retired `pipeline.config` knobs) — web-eval is now inline-only via the `needs-browser` label.

## Release gotchas

**GitHub Actions PR permission (first-run install).** release-please (and any
Action that opens PRs) fails with `GitHub Actions is not permitted to create or
approve pull requests` *after* it has already pushed the release branch — only
the final PR-create API call is blocked. Repos default to
`default_workflow_permissions=read`; an org policy can lock the repo-level
setting until the org flips its own. On a new org-owned repo, flip both
proactively before the first run, don't wait for the failure:

- Org: `https://github.com/organizations/<ORG>/settings/actions` → Workflow
  permissions → Read+write + allow PR creation (needs `admin:org`; UI is the only
  path without it).
- Repo: `gh api -X PUT repos/<ORG>/<REPO>/actions/permissions/workflow -F default_workflow_permissions=write -F can_approve_pull_request_reviews=true`

After enabling, `gh run rerun <ID>` — release-please skips the already-pushed
branch and just opens the PR.

**Tests that self-destruct on the first release.** release-please mutates
`CHANGELOG.md` and the `extra-files` version locations on every cut, so two test
anti-patterns are time bombs:

- **Grepping the repo as a "no references" guard.** A test that asserts "string X
  must not appear anywhere" will match release-please's own CHANGELOG entry
  containing the commit subject. Such tests MUST exclude `CHANGELOG.md`,
  `.claude/logs/`, and `.git/` from the grep.
- **Hard-coded version literals in equality assertions.** A version-sync test must
  assert the values match *each other* (manifest == `plugin.json` == `marketplace.json`),
  optionally with a semver-shape regex — never compare to a string literal like
  `0.2.0`, which goes red the moment release-please bumps it.

In plan-issue / evaluate-issue-plan, flag any new test that (a) greps the whole
repo without excluding generated paths, or (b) compares a version field to a
literal.

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

**Context.** An earlier release cut produced exactly one CHANGELOG entry for PR #484 even though that PR carried five conventional sub-commits. This is the intended behavior of the per-PR granularity contract, not a regression: the merge-commit subject is the source of truth, and PR #484's single merge-commit subject became the single CHANGELOG line.

**Why sub-commits collapse.** release-please's simple-mode projection walks `--first-parent` from the release tip. On that line a merged feature PR appears as ONE commit — its merge-commit subject — while the per-sub-commit conventional subjects live only on the merge's second parent (the full DAG), unreachable to a `--first-parent` walk. So a five-commit PR yields one CHANGELOG entry, keyed on the merge-commit subject. (This is the property characterized hermetically in `tests/test-release-please-changelog-fixture.sh`.)

**Rejected alternatives** — each pays a real cost for sub-commit granularity the pipeline does not need (PATH B plans already emit single-purpose commits at the merge-commit-subject level; PATH C plans can be split into multiple PRs when sub-commit granularity matters):

- **`manifest mode`** — release-please does not support a per-PR config that explodes a merge commit into its sub-commits; the workaround would re-author commits post-merge and introduce a new failure mode.
- **`custom walker`** keyed on PR number — replaces the release-please projection entirely and forfeits the version-bump atomicity that `extra-files` provides.
- **`richer commit-message walker`** that follows all merge second-parents — not configurable in release-please v4 simple mode; adopting it would mean forking the action.

**Decision:** per-PR granularity is the contract; sub-commit granularity is **out of scope**.

**When the assumption breaks.** If a PATH C plan emits many distinct `feat:` sub-commits within a single PR and each deserves its own CHANGELOG line, the planning-time mitigation is to either split the work into multiple PRs (one CHANGELOG-worthy change per PR) or accept the parent merge-commit subject as the single enumerated entry. Do not reach for the rejected alternatives above without first reopening #492 and swapping the decision text here and the CLAUDE.md line-29 framing.
