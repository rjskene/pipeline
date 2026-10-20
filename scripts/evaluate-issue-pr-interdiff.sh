#!/usr/bin/env bash
# evaluate-issue-pr-interdiff.sh — evaluate-issue-pr REEVAL=rebase-fix: compare
# the PR's net change before the rebase-fix (<old-head-sha> against its
# merge-base with origin/<base>) with its net change now (HEAD against its
# merge-base). Read-only; no fetch. Hunk-header line numbers are normalized so a
# base commit that only shifts lines does not count as a moved file.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: evaluate-issue-pr-interdiff.sh <old-head-sha>

Run from the feature worktree. First stdout line, exit 0 on every decision:
  INTERDIFF=none                  the net change is unchanged by the rebase-fix
  INTERDIFF=files=<csv>           paths whose net change moved; a diff -u of the
                                  old vs new normalized net diffs follows
  INTERDIFF=unknown reason=<r>    old-head-unreachable | no-merge-base
Exit 2 on usage errors.
Env: PIPELINE_BASE_BRANCH.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac
OLD="$1"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
BASE="${PIPELINE_BASE_BRANCH:?PIPELINE_BASE_BRANCH unset}"

if ! git cat-file -e "$OLD^{commit}" 2>/dev/null; then
  echo "INTERDIFF=unknown reason=old-head-unreachable"
  exit 0
fi
OLD_BASE=$(git merge-base "origin/$BASE" "$OLD" 2>/dev/null) \
  && NEW_BASE=$(git merge-base "origin/$BASE" HEAD 2>/dev/null) || {
  echo "INTERDIFF=unknown reason=no-merge-base"
  exit 0
}

norm() {
  sed -E '/^index /d; /^(dis)?similarity index /d; s/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/@@ @@/'
}

PATHS=$( { git diff --no-renames --name-only "$OLD_BASE" "$OLD"
           git diff --no-renames --name-only "$NEW_BASE" HEAD; } | sed '/^$/d' | sort -u)

MOVED=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  a=$(git diff --no-renames "$OLD_BASE" "$OLD" -- "$p" | norm)
  b=$(git diff --no-renames "$NEW_BASE" HEAD -- "$p" | norm)
  [ "$a" = "$b" ] || MOVED+=("$p")
done <<< "$PATHS"

if [ "${#MOVED[@]}" -eq 0 ]; then
  echo "INTERDIFF=none"
  exit 0
fi
echo "INTERDIFF=files=$(printf '%s\n' "${MOVED[@]}" | paste -sd, -)"
diff -u --label old --label new \
  <(git diff --no-renames "$OLD_BASE" "$OLD" | norm) \
  <(git diff --no-renames "$NEW_BASE" HEAD | norm)
exit 0
