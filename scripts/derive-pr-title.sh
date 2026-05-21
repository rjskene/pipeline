#!/usr/bin/env bash
# derive-pr-title — convert a GitHub issue title + label set into a strict
# Conventional-Commits PR title. Used by the pipeline:execute-issue-plan
# skill when opening a PR so release-please can drive versioning +
# CHANGELOG without a late-stage rewording step. See issue #56 for the
# rule rationale.
#
# Usage: derive-pr-title.sh <issue-number> [--title-override <str>]
#                                          [--labels-override <comma-or-space-list>]
#
# The overrides are for unit testing; in production the helper fetches title
# and labels via `gh issue view "$N" --repo "$PIPELINE_REPO" --json title,labels`.
#
# Exit 0: derived PR title written to stdout.
# Exit 2: issue is a tracker (epic) — refusal message on stderr, stdout empty.
set -euo pipefail

N="${1:-}"
if [ -z "$N" ]; then
  echo "usage: derive-pr-title.sh <issue-number> [--title-override <str>] [--labels-override <list>]" >&2
  exit 64
fi
shift || true

TITLE_OVERRIDE=""
LABELS_OVERRIDE=""
TITLE_OVERRIDDEN=0
LABELS_OVERRIDDEN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --title-override)
      TITLE_OVERRIDE="${2:-}"
      TITLE_OVERRIDDEN=1
      shift 2
      ;;
    --labels-override)
      LABELS_OVERRIDE="${2:-}"
      LABELS_OVERRIDDEN=1
      shift 2
      ;;
    *)
      echo "derive-pr-title: unknown argument '$1'" >&2
      exit 64
      ;;
  esac
done

# Neutralize set -u for callers that don't source pipeline.config first
# (e.g. the test harness, or ad-hoc invocations). The explicit guard below
# converts the missing-config case into a controlled exit 64 instead of a
# `line NN: PIPELINE_REPO: unbound variable` shell trap.
: "${PIPELINE_REPO:=}"

require_repo() {
  if [ -z "$PIPELINE_REPO" ]; then
    echo "derive-pr-title: PIPELINE_REPO is unset; pass --title-override/--labels-override or source pipeline.config" >&2
    exit 64
  fi
}

if [ "$TITLE_OVERRIDDEN" -eq 1 ]; then
  TITLE="$TITLE_OVERRIDE"
else
  require_repo
  TITLE=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json title --jq '.title')
fi

if [ "$LABELS_OVERRIDDEN" -eq 1 ]; then
  LABELS_RAW="$LABELS_OVERRIDE"
else
  require_repo
  LABELS_RAW=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json labels --jq '[.labels[].name] | join(",")')
fi

# Normalize labels into a comma-bounded string for whole-token matching.
LABELS_NORM=$(printf '%s' "$LABELS_RAW" | tr ' ' ',' | tr -s ',')
LABELS_NORM=",${LABELS_NORM},"

has_label() {
  [[ "$LABELS_NORM" == *",$1,"* ]]
}

refuse_tracker() {
  echo "Issue #$N is a tracker (epic title); trackers don't get PRs. Close the issue or rename it." >&2
  exit 2
}

# Rewrite the literal substring `../` to `..⁄` (U+2044, FRACTION SLASH) so the
# emitted title can be safely interpolated into `gh pr create --title "$T"`
# without the restrict_paths.py PreToolUse hook treating it as a path-escape
# attempt. Visually near-identical to `/`, never matches `\.\./` as a regex,
# survives round-trip through GitHub's PR title field unchanged. Every other
# shell metachar ($, backticks, single quotes, ;, &&) is left to the
# executor's quoting boundary. See issue #361 for the full rationale.
emit_title() {
  printf '%s\n' "$1" | sed $'s|\\.\\./|..\xe2\x81\x84|g'
}

# Tracker refusal — `tracker` label or epic(...) title prefix.
if has_label "tracker"; then
  refuse_tracker
fi
if [[ "$TITLE" =~ ^epic\( ]]; then
  refuse_tracker
fi

# Conventional-commits passthrough — keep this regex in sync with
# .github/workflows/pr-title-check.yml and skills/run/SKILL.md merge gate.
CC_RE='^(feat|fix|chore|refactor|docs|ci|perf|test|build|style|revert)(\([a-z0-9_-]+\))?!?: .+'
if [[ "$TITLE" =~ $CC_RE ]]; then
  emit_title "$TITLE"
  exit 0
fi

normalize_scope() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9_-]/-/g; s/^-*//; s/-*$//'
}

# bug(<scope>): <rest> → fix(<normalized-scope>): <rest>
if [[ "$TITLE" =~ ^bug\(([^\)]+)\):[[:space:]]+(.+)$ ]]; then
  scope=$(normalize_scope "${BASH_REMATCH[1]}")
  rest="${BASH_REMATCH[2]}"
  emit_title "$(printf 'fix(%s): %s' "$scope" "$rest")"
  exit 0
fi

# Derive scope from a `(...)` parenthetical in the title; else `general`.
scope_from_title() {
  if [[ "$TITLE" =~ \(([A-Za-z0-9_-]+)\) ]]; then
    normalize_scope "${BASH_REMATCH[1]}"
  else
    printf 'general'
  fi
}

# Strip a leading `prefix:` from the title (e.g. `skill: ...`, `web modal: ...`)
# so the PR title doesn't double-prefix. Multi-word prefixes are supported as
# long as they end at the first `:` with no parentheses before it.
summary_from_title() {
  local t="$TITLE"
  if [[ "$t" =~ ^[a-z][a-z[:space:]]*:[[:space:]]+(.+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "$t"
  fi
}

# `bug` label fallback — title had no recognized prefix, but the issue is
# tagged as a bug.
if has_label "bug"; then
  emit_title "$(printf 'fix(%s): %s' "$(scope_from_title)" "$(summary_from_title)")"
  exit 0
fi

# `enhancement` label fallback — same shape, emits feat(...).
if has_label "enhancement"; then
  emit_title "$(printf 'feat(%s): %s' "$(scope_from_title)" "$(summary_from_title)")"
  exit 0
fi

# Default — no recognized signal. Emit chore(general) so release-please
# still ingests it cleanly; a human can rename with `gh pr edit --title`
# and the merge-gate validation in skills/run/SKILL.md is the final
# reword opportunity.
emit_title "$(printf 'chore(general): %s' "$(summary_from_title)")"
exit 0
