#!/bin/bash
# Commits a screenshot PNG to mock-web-eval/screenshots/ in the current
# worktree, pushes the commit to origin (the PR branch), and prints a
# SHA-pinned GitHub raw URL on stdout. The URL survives squash-merge because
# the PNG blob collapses into the merge commit on the base branch.
#
# Usage: mock-web-eval/scripts/eval-screenshot-attach.sh <pr-number> <abs-png-path>
#
# Fail-soft on `git push`: if push fails (network blip, missing creds),
# the helper prints a warning to stderr, still emits the local-SHA URL,
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

mkdir -p mock-web-eval/screenshots
cp -- "$PNG" "mock-web-eval/screenshots/${FILENAME}"

git add -- "mock-web-eval/screenshots/${FILENAME}"

# Idempotent re-eval: if the file is unchanged, `git commit` fails with
# "nothing to commit" — that's fine, we'll reuse the existing HEAD SHA.
git commit -m "chore(eval): screenshot evidence for PR #${PR}" >/dev/null 2>&1 || true

if ! git push origin HEAD >/dev/null 2>&1; then
  echo "eval-screenshot-attach: WARN: git push failed — screenshot committed locally but not pushed; URL may 404 until pushed" >&2
fi

SHA="$(git rev-parse HEAD)"
echo "https://github.com/${PIPELINE_REPO}/raw/${SHA}/mock-web-eval/screenshots/${FILENAME}"
