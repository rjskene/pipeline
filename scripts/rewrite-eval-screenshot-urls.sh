#!/bin/bash
# rewrite-eval-screenshot-urls.sh — issue #506
#
# After auto-merge fires, rewrite the branch-pinned raw.githubusercontent.com
# screenshot URLs embedded in a PR's latest `## Evaluation` comment to
# merge-SHA-pinned URLs. A `<owner>/<repo>/<merge-sha>/.eval-screenshots/...`
# URL is durable for the life of the commit, whereas the branch-pinned form
# 404s once the feature branch is deleted by `--delete-branch` (the Option A
# ephemeral behaviour from tracker #383, which this supersedes).
#
# Usage: rewrite-eval-screenshot-urls.sh <pr-number> <merge-sha>
#
# Fail-soft by contract: the merge has already completed by the time this runs,
# so a rewrite failure is cosmetic — it warns to stderr and exits 0, never
# blocking the workflow. Idempotent: re-running on an already-rewritten comment
# is a no-op because the branch-pinned source pattern no longer matches.
#
# Opt-out: PIPELINE_SCREENSHOT_REWRITE_ENABLED=false restores tracker-#383
# (Option A ephemeral) behaviour by short-circuiting before any API call.
set -u

PR="${1:-}"
SHA="${2:-}"

# Env-var opt-out (default: enabled). Operators who want the legacy ephemeral
# audit-trail behaviour set this to false.
if [ "${PIPELINE_SCREENSHOT_REWRITE_ENABLED:-true}" != "true" ]; then
  exit 0
fi

if [ -z "$PR" ] || [ -z "$SHA" ]; then
  echo "WARN: rewrite-eval-screenshot-urls.sh requires <pr-number> <merge-sha>" >&2
  exit 0
fi

if [ -z "${PIPELINE_REPO:-}" ]; then
  echo "WARN: PIPELINE_REPO unset; skipping screenshot URL rewrite" >&2
  exit 0
fi

# Resolve the PR's head branch — the source component of the URLs to rewrite.
BRANCH="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json headRefName --jq .headRefName 2>/dev/null)"
if [ -z "$BRANCH" ]; then
  echo "WARN: could not resolve headRefName for PR #${PR}; skipping rewrite" >&2
  exit 0
fi

# Fetch the latest `## Evaluation` comment (id derived from its URL + body).
COMMENTS="$(gh pr view "$PR" --repo "$PIPELINE_REPO" --json comments 2>/dev/null)"
EVAL="$(printf '%s' "$COMMENTS" | jq -c '[.comments[] | select(.body | contains("## Evaluation"))] | last' 2>/dev/null)"
if [ -z "$EVAL" ] || [ "$EVAL" = "null" ]; then
  exit 0
fi

BODY="$(printf '%s' "$EVAL" | jq -r '.body')"
URL="$(printf '%s' "$EVAL" | jq -r '.url')"
COMMENT_ID="${URL##*issuecomment-}"
if [ -z "$COMMENT_ID" ] || [ "$COMMENT_ID" = "$URL" ]; then
  echo "WARN: could not derive comment id from URL '${URL}'; skipping rewrite" >&2
  exit 0
fi

# Branch-scoped source pattern: only URLs whose branch component matches THIS
# PR's head branch are touched, so doc links to other branches/commits are
# preserved verbatim.
SRC="raw.githubusercontent.com/${PIPELINE_REPO}/${BRANCH}/.eval-screenshots/"
DST="raw.githubusercontent.com/${PIPELINE_REPO}/${SHA}/.eval-screenshots/"
# Private-repo blob host (issue #551): the attach helper emits
# github.com/<repo>/blob/<branch>/.eval-screenshots/ URLs on private repos.
# Branch-scope-pin those to the merge SHA too. Host strings do not cross-match:
# raw.githubusercontent.com never contains the bare github.com/.../blob/ form.
BLOB_SRC="github.com/${PIPELINE_REPO}/blob/${BRANCH}/.eval-screenshots/"
BLOB_DST="github.com/${PIPELINE_REPO}/blob/${SHA}/.eval-screenshots/"

# No-op only if NEITHER host's branch-pinned form is present.
if ! printf '%s' "$BODY" | grep -qF "$SRC" && ! printf '%s' "$BODY" | grep -qF "$BLOB_SRC"; then
  exit 0
fi

# `|` delimiter avoids escaping the slashes in owner/repo and feature/* names.
# Both hosts are rewritten in one pass; each sed expression is a no-op when its
# source pattern is absent, so the raw-only and blob-only paths are preserved.
NEW_BODY="$(printf '%s' "$BODY" | sed -e "s|${SRC}|${DST}|g" -e "s|${BLOB_SRC}|${BLOB_DST}|g")"

if ! gh api -X PATCH "/repos/${PIPELINE_REPO}/issues/comments/${COMMENT_ID}" -f body="$NEW_BODY" >/dev/null 2>&1; then
  echo "WARN: failed to PATCH comment ${COMMENT_ID} on PR #${PR}; branch-pinned URLs left in place" >&2
  exit 0
fi

exit 0
