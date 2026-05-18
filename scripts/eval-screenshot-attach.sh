#!/bin/bash
# Idempotently uploads a screenshot PNG as a release asset on the
# eval-evidence-<PR> tag, then prints the download URL on stdout.
#
# Usage: scripts/eval-screenshot-attach.sh <pr-number> <abs-png-path>
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

TAG="eval-evidence-${PR}"
FILENAME="$(basename "$PNG")"

# Idempotent create — succeed-or-already-exists. The release is created
# against the default branch (main) but assets are tag-pinned; the target
# commit is irrelevant for asset rendering.
if ! gh release view "$TAG" --repo "$PIPELINE_REPO" >/dev/null 2>&1; then
  gh release create "$TAG" \
    --repo "$PIPELINE_REPO" \
    --title "Eval evidence for PR #${PR}" \
    --notes "Automated screenshot capture from /pipeline:evaluate-issue-pr. Deleted on PR merge." \
    --target main \
    >/dev/null
fi

gh release upload "$TAG" "$PNG" --repo "$PIPELINE_REPO" --clobber >/dev/null

# Canonical asset download URL. Works for public + private repos
# (private requires reader auth on the underlying repo).
echo "https://github.com/${PIPELINE_REPO}/releases/download/${TAG}/${FILENAME}"
