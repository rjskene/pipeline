#!/bin/bash
set -euo pipefail
# Characterization guard for issue #459: demonstrates WHY merge-commits preserve
# per-PR CHANGELOG entries where squash collapses them.
#
# Builds the two-level merge topology that release-please traverses on `main`:
#   root --> staging (merge --no-ff feature/A, merge --no-ff feature/B)
#         --> main   (merge --no-ff staging, with a `chore(main): release` +
#                     `Release-As:` body, mimicking a `gh pr merge --merge` of
#                     the staging->main release PR)
#
# Asserts the property release-please's commit walker relies on: the per-PR
# conventional commits (`feat: A`, `fix: B`) are REACHABLE from `main`'s tip via
# the full commit DAG (merge second parents), even though they are NOT on the
# `--first-parent` line. A squash merge would have placed ZERO conventional
# commits on `main` (only the non-conventional release subject) -> the
# "Miscellaneous Chores" / single-line CHANGELOG failure mode seen on v0.14.0,
# v0.14.1, and v0.14.2.
#
# NOTE: this test does NOT invoke the release-please CLI. release-please reads
# commits via the GitHub GraphQL/REST API (it has no local-git backend) — a
# `release-please release-pr --repo-url file://<dir>` invocation parses the path
# as an `owner/repo` slug and 404s against api.github.com. Verified empirically
# 2026-05-24. The end-to-end release-please projection is verified out-of-band
# on the first real merge-commit release after #459 (see docs/release-cadence.md
# "Migration & rollback").
#
# Hermetic: no network, no npx, no GitHub. Uses a throwaway git repo under a
# temp dir that is removed on exit.

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

command -v git >/dev/null 2>&1 || { echo "SKIPPED: git unavailable"; exit 0; }

FIX="$(mktemp -d)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

(
  cd "$FIX"
  git init -q -b root
  git config user.email fixture@test.local
  git config user.name fixture
  git commit --allow-empty -q -m "init"

  git checkout -q -b staging
  git checkout -q -b feature-A
  git commit --allow-empty -q -m "feat: A new feature"
  git checkout -q staging
  git merge --no-ff feature-A -q -m "Merge pull request #1 from feature-A"$'\n\n'"feat: A new feature"

  git checkout -q -b feature-B
  git commit --allow-empty -q -m "fix: B bug fix"
  git checkout -q staging
  git merge --no-ff feature-B -q -m "Merge pull request #2 from feature-B"$'\n\n'"fix: B bug fix"

  # synthetic `main` at root, then merge staging in (the staging->main release PR)
  git checkout -q -b main root
  git merge --no-ff staging -q -m "chore(main): release 0.14.2"$'\n\n'"Release-As: 0.14.2"
)

FULL_LOG="$(git -C "$FIX" log main --pretty=%s)"
FP_LOG="$(git -C "$FIX" log main --first-parent --pretty=%s)"
SP_LOG="$(git -C "$FIX" log staging --first-parent --pretty=%s)"
TIP_BODY="$(git -C "$FIX" log -1 --pretty=%B main)"

# 1. Per-PR conventional commits reachable from main's tip via the full DAG.
assert "feat: A reachable from main (full DAG)" "printf '%s' \"\$FULL_LOG\" | grep -q 'feat: A new feature'"
assert "fix: B reachable from main (full DAG)"  "printf '%s' \"\$FULL_LOG\" | grep -q 'fix: B bug fix'"

# 2. They are NOT on the --first-parent line (proving they live on merge second
#    parents — exactly what a squash would have dropped from main entirely).
assert "feat: A absent from --first-parent line" "! printf '%s' \"\$FP_LOG\" | grep -q 'feat: A new feature'"
assert "fix: B absent from --first-parent line"  "! printf '%s' \"\$FP_LOG\" | grep -q 'fix: B bug fix'"

# 3. The release merge commit carries the conventional subject + Release-As footer.
assert "release merge commit subject present" "printf '%s' \"\$TIP_BODY\" | grep -q 'chore(main): release 0.14.2'"
assert "Release-As: footer preserved on merge commit" "printf '%s' \"\$TIP_BODY\" | grep -q 'Release-As: 0.14.2'"

# 4. Per #492: the unit of CHANGELOG entry within a single merged feature PR is
#    the merge-commit subject (what `--first-parent` sees), not the per-sub-commit
#    conventional subjects (which are reachable only via the full DAG). A
#    --first-parent walker reading from a tip that includes feature merges
#    (`staging`) sees `Merge pull request #N from feature-X` as the subject — that
#    merge-commit subject IS the source of truth for the per-PR granularity
#    contract, and is exactly what main's --first-parent line (asserted absent in
#    block 2 above) does NOT carry. See
#    docs/release-cadence.md#granularity-scope-decision-492.
assert "staging --first-parent shows the merge-PR subject (per-PR granularity source of truth)" "printf '%s' \"\$SP_LOG\" | grep -q 'Merge pull request #1 from feature-A'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
