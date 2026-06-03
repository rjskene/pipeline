#!/bin/bash
set -euo pipefail

# Per-leaf-worktree fan-out helper for PATH C inline execution (#896).
#
# Inline PATH C fans out one `tdd-implementer` leaf per `target=<dir>`. If every
# leaf shares ONE issue worktree, concurrent leaves share ONE git index and
# race: transient index.lock collisions and one leaf's files swept into another
# leaf's commit (the #894 c+d collision), breaking per-target commit isolation.
#
# This helper gives each leaf its OWN worktree+branch off the parent (feature)
# worktree's HEAD, so concurrent commits can never collide. After the leaves
# finish, `reassemble` cherry-picks each leaf's commits back onto the feature
# branch — disjoint targets => conflict-free, preserving one commit per target.
#
# Usage:
#   path-c-split-worktree.sh setup      <parent-worktree> <leaf-id>
#   path-c-split-worktree.sh reassemble <parent-worktree> <leaf-id> [<leaf-id> ...]
#   path-c-split-worktree.sh teardown   <parent-worktree> <leaf-id> [<leaf-id> ...]
#
# <leaf-id> is the leaf's `target=<dir>` value (or any stable identifier); the
# helper sanitizes it identically across subcommands so derived worktree/branch
# names always match. setup prints the absolute leaf worktree path on stdout.

usage() {
  echo "Usage: $0 {setup|reassemble|teardown} <parent-worktree> <leaf-id> [<leaf-id> ...]" >&2
  exit 2
}

# Sanitize a leaf-id (e.g. "dev/probe/a/") into a single-segment slug
# ("dev-probe-a") so worktree dir + branch names are filesystem/ref safe and
# deterministic across setup/reassemble/teardown.
sanitize() {
  printf '%s' "$1" | tr -c 'a-zA-Z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//'
}

parent_branch() {
  git -C "$1" rev-parse --abbrev-ref HEAD
}

CMD="${1:-}"; [ -n "$CMD" ] || usage
PARENT="${2:-}"; [ -n "$PARENT" ] || usage
shift 2 || usage

if [ ! -d "$PARENT" ] || ! git -C "$PARENT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: parent worktree '$PARENT' is not a git worktree" >&2
  exit 1
fi
PARENT=$(cd "$PARENT" && pwd)              # absolutize
PBRANCH=$(parent_branch "$PARENT")

case "$CMD" in
  setup)
    [ $# -eq 1 ] || usage
    SLUG=$(sanitize "$1")
    [ -n "$SLUG" ] || { echo "ERROR: leaf-id sanitized to empty: '$1'" >&2; exit 1; }
    LEAF_BRANCH="${PBRANCH}--leaf-${SLUG}"
    LEAF_WT="${PARENT}-leaf-${SLUG}"
    # Branch each leaf off the parent worktree's CURRENT HEAD so it inherits all
    # work merged into the feature branch so far, with its own isolated index.
    git -C "$PARENT" worktree add -q -b "$LEAF_BRANCH" "$LEAF_WT" HEAD
    printf '%s\n' "$LEAF_WT"
    ;;

  reassemble)
    [ $# -ge 1 ] || usage
    for leaf in "$@"; do
      SLUG=$(sanitize "$leaf")
      LEAF_BRANCH="${PBRANCH}--leaf-${SLUG}"
      if ! git -C "$PARENT" rev-parse --verify -q "$LEAF_BRANCH" >/dev/null; then
        echo "ERROR: leaf branch '$LEAF_BRANCH' not found" >&2
        exit 1
      fi
      # Cherry-pick exactly the commits the leaf added on top of the shared
      # ancestor. merge-base (not the live branch tip) keeps the range correct
      # even after earlier leaves have advanced the feature branch.
      BASE=$(git -C "$PARENT" merge-base HEAD "$LEAF_BRANCH")
      if [ "$BASE" = "$(git -C "$PARENT" rev-parse "$LEAF_BRANCH")" ]; then
        continue   # leaf added no commits — nothing to reassemble
      fi
      if ! git -C "$PARENT" cherry-pick "${BASE}..${LEAF_BRANCH}" >/dev/null 2>&1; then
        git -C "$PARENT" cherry-pick --abort >/dev/null 2>&1 || true
        echo "ERROR: cherry-pick of '$LEAF_BRANCH' conflicted — targets are not disjoint" >&2
        exit 1
      fi
    done
    ;;

  teardown)
    [ $# -ge 1 ] || usage
    for leaf in "$@"; do
      SLUG=$(sanitize "$leaf")
      LEAF_BRANCH="${PBRANCH}--leaf-${SLUG}"
      LEAF_WT="${PARENT}-leaf-${SLUG}"
      git -C "$PARENT" worktree remove --force "$LEAF_WT" 2>/dev/null || true
      git -C "$PARENT" branch -D "$LEAF_BRANCH" >/dev/null 2>&1 || true
    done
    ;;

  *)
    usage
    ;;
esac
