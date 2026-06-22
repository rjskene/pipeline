#!/usr/bin/env bash
# Shared git sandbox helper for pipeline bash tests. Source this file and call
# git_init_sandbox <dir> to initialise a temp git repo with a local identity,
# so subsequent commits (git -C <dir> commit …) succeed even in CI environments
# that have no global git identity configured.
#
# Root cause this guards against (#1117): a temp repo created with a bare
# `git init` does NOT inherit the checked-out repo's identity, and CI has no
# global identity. A bare `git commit` in such a repo fails with exit 128.
#
# Usage:
#   source "$(dirname "$0")/_lib/git-sandbox.sh"
#   d="$(mktemp -d)"
#   git_init_sandbox "$d"
#   git -C "$d" commit --allow-empty -m "first"

# Initialise <dir> as a git repo and stamp a local identity sufficient to
# commit. No top-level side effects — function definition only.
git_init_sandbox() {
  local d="$1"
  git -C "$d" init -q \
    && git -C "$d" config user.email t@t.t \
    && git -C "$d" config user.name t
}
