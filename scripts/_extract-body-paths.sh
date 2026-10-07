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
#   bp_body_paths <body>        — full issue-body extraction pipeline:
#                                  declared sections (affected-areas / files-
#                                  to-change), whole body as fallback ->
#                                  normalized, deduped paths, one per line on
#                                  stdout.
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

# bp_drop_negated_lines <body> — drop any physical line matching the negation
# cue `(do|does|must|should|will)( not|n't)|never` when an action word
# `(touch|change|edit|modify|alter|rewrite)` follows it later on the SAME
# line (case-insensitive, #1347). A negated line contributes no paths at all
# — documented trade-off: a line that both forbids one file and names another
# loses the second (plans list real files in `**Files to change:**`, which is
# unaffected since this filter is bp_body_paths-only).
bp_drop_negated_lines() {
  awk -v IGNORECASE=1 \
      -v neg1="(do|does|must|should|will)( not|n't)" \
      -v neg2="never" \
      -v act="(touch|change|edit|modify|alter|rewrite)" \
      '{
         line = $0
         # Each cue is checked independently: a `never <act>` must not be
         # masked by a later `do not <non-act>` on the same line.
         if (match(line, neg1)) { rest = substr(line, RSTART + RLENGTH); if (match(rest, act)) next }
         if (match(line, neg2)) { rest = substr(line, RSTART + RLENGTH); if (match(rest, act)) next }
         print line
       }'
}

# bp_declared_lines — stdin/stdout filter (#1388). ONE awk pass that both
# DETECTS a declaring header (`## Affected areas`, `**Files to change:**`,
# `## Files to change`) and SLICES the block(s) that follow it. When at
# least one header was seen, emits a `BP_DECLARED` sentinel line first, then
# the block lines (possibly none, e.g. a block whose only entry was already
# dropped by bp_drop_negated_lines). Emits nothing at all when no declaring
# header is present — that absence is what bp_body_paths reads as "declares
# nothing", the presence-based fallback trigger (see B14/B15).
bp_declared_lines() {
  awk 'BEGIN{IGNORECASE=1; in_block=0; seen=0; buf=""; mode=""}
       /^##[[:space:]]+Affected areas/ { seen=1; in_block=1; mode="affected"; next }
       /^\*\*Files to change:\*\*/ { seen=1; in_block=1; mode="files"; next }
       /^##[[:space:]]+Files to change/ { seen=1; in_block=1; mode="files"; next }
       in_block && /^##/ { in_block=0 }
       in_block && mode=="files" && /^\*\*/ { in_block=0 }
       in_block && NF>0 { buf = buf $0 "\n" }
       END{ if (seen) { printf "BP_DECLARED\n"; printf "%s", buf } }'
}

# bp_body_paths <body> — issue-body extraction: declared sections (affected-
# areas / files-to-change) when the body declares at least one; the whole
# body (backticked tokens plus the `## Affected areas` block) as a fallback
# when it declares none. Normalized and deduped. One path per line.
bp_body_paths() {
  local body="$1" filtered scoped from_backticks from_affected
  filtered=$(printf '%s' "$body" | bp_drop_negated_lines)
  scoped=$(printf '%s' "$filtered" | bp_declared_lines)
  if [ -n "$scoped" ]; then
    from_backticks=""
    from_affected=$(printf '%s' "$scoped" | tail -n +2)
  else
    from_backticks=$( { printf '%s' "$filtered" \
      | grep -oE '`[^`]+`' \
      | tr -d '`' \
      | grep -E "$FILE_PATH_RE"; } || true)
    from_affected=$(printf '%s' "$filtered" \
      | awk 'BEGIN{IGNORECASE=1; in_block=0}
             /^##[[:space:]]+Affected areas/ {in_block=1; next}
             in_block && /^##/ {in_block=0}
             in_block && NF>0 {print}')
  fi
  { printf '%s\n%s\n' "$from_backticks" "$from_affected" \
    | tr -d '`' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' \
    | sed 's/[[:space:]]\+/\n/g' \
    | grep -E "$FILE_PATH_RE" \
    | grep -vE '[*?[]' \
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
    | grep -vE '[*?[]' \
    | bp_normalize_tokens \
    | sort -u; } || true
}
