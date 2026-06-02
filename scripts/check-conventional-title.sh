#!/bin/bash
#
# Canonical Conventional Commits PR-title validator used pipeline-wide.
# Single source of truth for both /pipeline:execute-issue-plan (pre-PR-create
# pre-validation) and /pipeline:status (pre-merge gates). See Issue #45.
#
# Usage:
#
#   # As a script (returns exit 0/1):
#   bash scripts/check-conventional-title.sh "feat(web): add modal"
#
#   # Sourced (exposes function + regex var):
#   source scripts/check-conventional-title.sh
#   if check_conventional_title "$PR_TITLE"; then ...; fi
#   echo "$CONVENTIONAL_TITLE_REGEX"
#
# Types: feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert
# Optional scope: lowercase letters, digits, underscore, hyphen.
# Optional breaking marker: `!`
# Subject: at least one non-whitespace character after `: `.

export CONVENTIONAL_TITLE_REGEX='^(feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert)(\([a-z0-9_-]+\))?!?: [^[:space:]].*'

check_conventional_title() {
  local title="${1-}"
  [[ "$title" =~ $CONVENTIONAL_TITLE_REGEX ]]
}

# Only enable strict mode + run CLI when invoked directly (not when sourced),
# so callers that `source` this file don't inherit `set -e` quirks.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  if check_conventional_title "${1-}"; then
    exit 0
  else
    exit 1
  fi
fi
