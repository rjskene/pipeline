#!/bin/bash
# shellcheck shell=bash
# _extract-body-paths.sh — sourceable helper (issue #1239).
#
# Shared single source of truth for the issue-body / plan-comment file-path
# extractor: the regexes, the `## Affected areas` / `**Files to change:**`
# slicing, and the `git ls-files` path-normalization + junk-token rejection
# fix from #1230. Sourced by BOTH scripts/plan-waves.sh (issue-body fallback
# + plan-comment extraction) and scripts/path-b-execute-eligible.sh (blast-
# radius path set), so the two call sites read ONE extractor instead of two
# hand-copied drifting ones. Precedent: #1039 / scripts/_high-uncertainty-match.sh,
# whose sourceable-only shape and naming convention this file follows.
#
# API:
#   FILE_PATH_RE, FILE_EXT_RE   — the path-shape and known-extension regexes.
#   bp_tree_index               — echoes the repo's `git ls-files` output,
#                                  lazily memoized into BP_TREE_INDEX. Empty
#                                  string when not inside a repo.
#   bp_normalize_tokens         — stdin/stdout filter: resolves a shallow
#                                  path reference onto its repo-root-relative
#                                  form via the tree index (or an unambiguous
#                                  unique-suffix match), else keeps a token
#                                  with a known extension verbatim, else drops
#                                  it (#1230 junk-token rejection).
#   bp_body_paths <body>        — full issue-body extraction pipeline
#                                  (backticked tokens + `## Affected areas`
#                                  block) -> normalized, deduped paths, one
#                                  per line on stdout.
#   bp_plan_files <plan_body>   — extraction over a plan-comment's
#                                  `**Files to change:**` bullet block ->
#                                  normalized, deduped paths, one per line.
#
# This file is sourceable-only: no shebang side effects, nothing runs at
# source time beyond the two regex assignments below.

FILE_PATH_RE='^[^[:space:]]*/[^/[:space:]]+$|^[^[:space:]]+\.(md|sh|py|json|yml|yaml|ts|tsx|js|jsx|go)$'
FILE_EXT_RE='\.(md|sh|py|json|yml|yaml|ts|tsx|js|jsx|go)$'

# bp_tree_index — lazily populate + echo BP_TREE_INDEX. Deferred (not an
# eager top-level assignment) so classify/plan-stage callers that never
# extract paths pay no `git ls-files` cost.
bp_tree_index() {
  if [ -z "${BP_TREE_INDEX+x}" ]; then
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$root" ]; then
      BP_TREE_INDEX=$(git -C "$root" ls-files 2>/dev/null || true)
    else
      BP_TREE_INDEX=""
    fi
  fi
  printf '%s' "$BP_TREE_INDEX"
}

# bp_normalize_tokens — stdin/stdout filter (#1230). Resolves each token to
# repo-root-relative form when the tree index has an exact or unambiguous
# unique-suffix match; otherwise keeps tokens with a known extension
# verbatim (existence RESOLVES, never DROPS — see B4); otherwise drops the
# token (junk-token rejection — see B3).
bp_normalize_tokens() {
  local tok clean cands n tree_index
  tree_index=$(bp_tree_index)
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    clean="${tok//\`/}"
    clean=$(printf '%s' "$clean" | sed -E 's/^[*_([]+//; s/[]*_,.;:)]+$//')
    clean="${clean#./}"
    [ -n "$clean" ] || continue
    case "$clean" in
      *'#'*) continue ;;
      */)    continue ;;
    esac
    if [ -n "$tree_index" ] && printf '%s\n' "$tree_index" | grep -Fxq -- "$clean"; then
      printf '%s\n' "$clean"; continue
    fi
    case "$clean" in
      */*)
        cands=""
        if [ -n "$tree_index" ]; then
          cands=$(printf '%s\n' "$tree_index" \
            | awk -v s="/$clean" 'length($0)>length(s) && substr($0, length($0)-length(s)+1)==s' || true)
        fi
        n=$(printf '%s' "$cands" | grep -c . || true)
        if [ "${n:-0}" = "1" ]; then printf '%s\n' "$cands"; continue; fi
        ;;
    esac
    if printf '%s' "$clean" | grep -qE "$FILE_EXT_RE"; then
      printf '%s\n' "$clean"; continue
    fi
  done
}

# bp_body_paths <body> — issue-body extraction: backticked tokens plus the
# `## Affected areas` block, normalized and deduped. One path per line.
bp_body_paths() {
  local body="$1" from_backticks from_affected
  from_backticks=$( { printf '%s' "$body" \
    | grep -oE '`[^`]+`' \
    | tr -d '`' \
    | grep -E "$FILE_PATH_RE"; } || true)
  from_affected=$(printf '%s' "$body" \
    | awk 'BEGIN{IGNORECASE=1; in_block=0}
           /^##[[:space:]]+Affected areas/ {in_block=1; next}
           in_block && /^##/ {in_block=0}
           in_block && NF>0 {print}')
  { printf '%s\n%s\n' "$from_backticks" "$from_affected" \
    | tr -d '`' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' \
    | sed 's/[[:space:]]\+/\n/g' \
    | grep -E "$FILE_PATH_RE" \
    | bp_normalize_tokens \
    | sort -u; } || true
}

# bp_plan_files <plan_body> — plan-comment extraction: the
# `**Files to change:**` bullet block, normalized and deduped. One path per
# line.
bp_plan_files() {
  local body="$1"
  { printf '%s' "$body" \
    | awk 'BEGIN{in_block=0}
           /^\*\*Files to change:\*\*/ {in_block=1; next}
           in_block && /^\*\*/ {in_block=0}
           in_block && /^-/ {print}' \
    | sed 's/[[:space:]]\+/\n/g' \
    | tr -d '`' \
    | grep -E "$FILE_PATH_RE" \
    | bp_normalize_tokens \
    | sort -u; } || true
}
