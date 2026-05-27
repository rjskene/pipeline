#!/bin/bash
# Commits a screenshot PNG to .eval-screenshots/ in the current worktree,
# pushes the commit to origin (the PR branch), and prints a branch-pinned
# raw.githubusercontent.com URL on stdout. The URL is ephemeral by design
# (Option A, issue #337 / tracker #383): it resolves during the PR review
# window and intentionally 404s once the feature branch is deleted post-merge.
#
# Usage: mock-web-eval/scripts/eval-screenshot-attach.sh <pr-number> <abs-png-path>
#
# Fail-soft on `git push`: if push fails (network blip, missing creds),
# the helper prints a warning to stderr, still emits the branch-pinned URL,
# and exits 0. The URL will 404 until the operator pushes manually.
set -uo pipefail

PR="${1:-}"; PNG="${2:-}"
if [ -z "$PR" ] || [ -z "$PNG" ]; then
  echo "usage: $(basename "$0") <pr-number> <abs-png-path>" >&2
  exit 2
fi
if [ ! -f "$PNG" ]; then
  echo "error: PNG file not found at $PNG" >&2
  exit 3
fi
: "${PIPELINE_REPO:?PIPELINE_REPO must be set}"

FILENAME="$(basename "$PNG")"

mkdir -p .eval-screenshots
cp -- "$PNG" ".eval-screenshots/${FILENAME}"

git add -- ".eval-screenshots/${FILENAME}"

# Idempotent re-eval: if the file is unchanged, `git commit` fails with
# "nothing to commit" — that's fine, we'll reuse the existing HEAD SHA.
git commit -m "chore(eval): screenshot evidence for PR #${PR}" >/dev/null 2>&1 || true

if ! git push origin HEAD >/dev/null 2>&1; then
  echo "eval-screenshot-attach: WARN: git push failed — screenshot committed locally but not pushed; URL may 404 until pushed" >&2
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Repo-visibility branch (issue #551). On private repos, raw.githubusercontent.com
# content 404s for anonymous fetchers (and GitHub's camo image proxy can't
# authenticate), so emit a github.com/<repo>/blob/<branch>/... URL instead —
# GitHub's authenticated file viewer renders the PNG for repo members. Fail-soft:
# any `gh` absence/error/non-`true` value falls back to the raw host (public).
PRIVATE="$(gh repo view "$PIPELINE_REPO" --json isPrivate --jq .isPrivate 2>/dev/null || true)"
if [ "$PRIVATE" = "true" ]; then
  echo "https://github.com/${PIPELINE_REPO}/blob/${BRANCH}/.eval-screenshots/${FILENAME}"
else
  echo "https://raw.githubusercontent.com/${PIPELINE_REPO}/${BRANCH}/.eval-screenshots/${FILENAME}"
fi
