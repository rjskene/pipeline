# shellcheck shell=bash
# Pre-merge pairwise file overlap detection helper.
#
# Source this file; it exposes:
#   detect_merge_overlap <pr> [<pr>...]
#       - For each unordered pair of PRs, prints:
#           OVERLAP <prA> <prB> <count>
#             <path1>
#             <path2>
#         when their changed-file sets intersect (count > 0).
#       - Prints nothing for pairs with no overlap.
#       - Returns 0 always (advisory).
#   recommend_merge_order <pr> [<pr>...]
#       - Prints PR numbers one per line in recommended merge order:
#         ascending by (number of other PRs this PR overlaps), ties
#         broken by ascending PR number.
#
# Requires: gh, jq, $PIPELINE_REPO in env.

_dmo_files_for_pr() {
  # Print one path per line for the given PR. Cached per-call in $_DMO_CACHE_DIR.
  local pr="$1"
  local cache="${_DMO_CACHE_DIR}/${pr}.files"
  if [ ! -f "$cache" ]; then
    gh pr view "$pr" --repo "${PIPELINE_REPO:-}" --json files \
      --jq '.files[].path' > "$cache" 2>/dev/null || true
  fi
  cat "$cache"
}

detect_merge_overlap() {
  _DMO_CACHE_DIR="$(mktemp -d)"
  local prs=("$@")
  local i j a b shared count
  for ((i=0; i<${#prs[@]}; i++)); do
    for ((j=i+1; j<${#prs[@]}; j++)); do
      a="${prs[$i]}"; b="${prs[$j]}"
      shared=$(comm -12 \
        <(_dmo_files_for_pr "$a" | LC_ALL=C sort -u) \
        <(_dmo_files_for_pr "$b" | LC_ALL=C sort -u))
      if [ -n "$shared" ]; then
        count=$(printf '%s\n' "$shared" | wc -l | tr -d ' ')
        printf 'OVERLAP %s %s %s\n' "$a" "$b" "$count"
        printf '  %s\n' $shared
      fi
    done
  done
  rm -rf "$_DMO_CACHE_DIR"
  unset _DMO_CACHE_DIR
  return 0
}
