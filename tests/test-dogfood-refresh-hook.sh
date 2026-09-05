#!/bin/bash
set -uo pipefail

# Tests for dev/hooks/dogfood-refresh.sh — dogfood-only auto-refresh of the
# local marketplace repo working tree. Single source for both SessionStart hook
# and operator-driven manual refresh.
#
# Coverage:
#   1. Existence + executable bit.
#   2. Shebang line.
#   3. Happy-path: fast-forward consumes a new upstream commit; exit 0.
#   4. Dirty tree: exit 0, no destructive action (dirty file preserved).
#   5. No-network: bogus origin URL, exit 0 (fail-open).
#   6. Non-FF state: divergent local commit preserved, exit 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/dev/hooks/dogfood-refresh.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. Existence + executable.
if [ -f "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-refresh.sh exists"
else
  fail_msg "dev/hooks/dogfood-refresh.sh exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

if [ -x "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-refresh.sh is executable"
else
  fail_msg "dev/hooks/dogfood-refresh.sh is executable"
fi

# 2. Shebang.
first_line="$(head -n1 "$TARGET")"
case "$first_line" in
  "#!/usr/bin/env bash"|"#!/bin/bash")
    pass_msg "shebang is bash"
    ;;
  *)
    fail_msg "shebang is bash (got: $first_line)"
    ;;
esac

# Helpers for fixture setup.
mk_fixture() {
  # Args: <tempdir>
  # Creates: $T/origin.git (bare) and $T/clone (working clone on `staging`)
  # with one initial commit. Echoes the clone path.
  local T="$1"
  ( set -e
    mkdir -p "$T/origin.git"
    git -C "$T/origin.git" init --bare --quiet --initial-branch=staging
    mkdir -p "$T/seed"
    git -C "$T/seed" init --quiet --initial-branch=staging
    git -C "$T/seed" config user.email "test@example.com"
    git -C "$T/seed" config user.name "Test"
    : > "$T/seed/README"
    git -C "$T/seed" add README
    git -C "$T/seed" commit --quiet -m "initial"
    git -C "$T/seed" remote add origin "$T/origin.git"
    git -C "$T/seed" push --quiet origin staging
    git clone --quiet -b staging "$T/origin.git" "$T/clone"
    git -C "$T/clone" config user.email "test@example.com"
    git -C "$T/clone" config user.name "Test"
  ) >/dev/null 2>&1
}

# 3. Happy-path: upstream advances, clone fast-forwards.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

# Push a new commit to origin via the seed repo.
( set -e
  git -C "$T/seed" commit --quiet --allow-empty -m "new upstream commit"
  git -C "$T/seed" push --quiet origin staging
) >/dev/null 2>&1

upstream_head="$(git -C "$T/seed" rev-parse HEAD)"
clone_head_before="$(git -C "$T/clone" rev-parse HEAD)"

if [ "$upstream_head" = "$clone_head_before" ]; then
  fail_msg "fixture sanity: upstream HEAD differs from clone HEAD pre-refresh"
fi

DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "happy-path exit 0"
else
  fail_msg "happy-path exit 0 (got rc=$rc)"
fi

clone_head_after="$(git -C "$T/clone" rev-parse HEAD)"
if [ "$clone_head_after" = "$upstream_head" ]; then
  pass_msg "happy-path fast-forwarded clone to new upstream HEAD"
else
  fail_msg "happy-path fast-forwarded clone to new upstream HEAD (before=$clone_head_before after=$clone_head_after upstream=$upstream_head)"
fi

rm -rf "$T"

# 4. Dirty tree: untracked/modified file present, exit 0 and file preserved.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

# Advance origin so there's something to pull.
( set -e
  git -C "$T/seed" commit --quiet --allow-empty -m "dirty-test upstream"
  git -C "$T/seed" push --quiet origin staging
) >/dev/null 2>&1

echo "dirty contents" > "$T/clone/dirty.txt"
# Also modify a tracked file so merge would conflict if attempted.
echo "modified" >> "$T/clone/README"

DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "dirty-tree exit 0"
else
  fail_msg "dirty-tree exit 0 (got rc=$rc)"
fi

if [ -f "$T/clone/dirty.txt" ] && [ "$(cat "$T/clone/dirty.txt")" = "dirty contents" ]; then
  pass_msg "dirty-tree: untracked file preserved"
else
  fail_msg "dirty-tree: untracked file preserved"
fi

if grep -q "modified" "$T/clone/README"; then
  pass_msg "dirty-tree: tracked-file modifications preserved"
else
  fail_msg "dirty-tree: tracked-file modifications preserved"
fi

rm -rf "$T"

# 5. No-network: bogus origin URL, fail-open.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

git -C "$T/clone" remote set-url origin "/nonexistent/repo.git" >/dev/null 2>&1

DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "no-network exit 0 (fail-open)"
else
  fail_msg "no-network exit 0 (fail-open) (got rc=$rc)"
fi

rm -rf "$T"

# 6. Non-FF state: divergent local commit, exit 0, local commit preserved.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

# Diverge: origin advances with commit A; clone advances with commit B.
( set -e
  git -C "$T/seed" commit --quiet --allow-empty -m "origin-divergent A"
  git -C "$T/seed" push --quiet origin staging

  git -C "$T/clone" commit --quiet --allow-empty -m "clone-divergent B"
) >/dev/null 2>&1

clone_local_head="$(git -C "$T/clone" rev-parse HEAD)"
clone_local_subject="$(git -C "$T/clone" log -1 --format=%s)"

DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "non-FF exit 0"
else
  fail_msg "non-FF exit 0 (got rc=$rc)"
fi

clone_post_head="$(git -C "$T/clone" rev-parse HEAD)"
if [ "$clone_post_head" = "$clone_local_head" ]; then
  pass_msg "non-FF: local divergent commit preserved (HEAD unchanged)"
else
  fail_msg "non-FF: local divergent commit preserved (was=$clone_local_head now=$clone_post_head subject was=$clone_local_subject)"
fi

rm -rf "$T"

# 7. Worktree redirect: when REPO_ROOT auto-resolves to a linked worktree,
# the script must redirect to the MAIN repo working tree and fast-forward
# THAT, leaving the worktree's own feature branch untouched. This is the
# plan Risk #5 mitigation for #611 (worktree SessionStart hook).
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

( set -e
  mkdir -p "$T/origin.git"
  git -C "$T/origin.git" init --bare --quiet --initial-branch=staging

  # Sidecar seed to populate staging.
  mkdir -p "$T/seed"
  git -C "$T/seed" init --quiet --initial-branch=staging
  git -C "$T/seed" config user.email "test@example.com"
  git -C "$T/seed" config user.name "Test"
  : > "$T/seed/README"
  git -C "$T/seed" add README
  git -C "$T/seed" commit --quiet -m "initial"
  git -C "$T/seed" remote add origin "$T/origin.git"
  git -C "$T/seed" push --quiet origin staging

  # Main repo: clone on staging.
  git clone --quiet -b staging "$T/origin.git" "$T/main"
  git -C "$T/main" config user.email "test@example.com"
  git -C "$T/main" config user.name "Test"

  # Add a feature branch and a linked worktree checked out on it.
  git -C "$T/main" branch feat
  git -C "$T/main" worktree add --quiet "$T/worktree-feat" feat

  # Push a new commit to origin/staging via the seed.
  git -C "$T/seed" commit --quiet --allow-empty -m "wt-redirect upstream commit"
  git -C "$T/seed" push --quiet origin staging

  # Copy the live script into the worktree's own dev/hooks/ tree so the
  # script's self-resolution of REPO_ROOT (dirname/../..) points at the
  # worktree, not the main repo. This is the SessionStart-hook shape.
  mkdir -p "$T/worktree-feat/dev/hooks"
  cp "$TARGET" "$T/worktree-feat/dev/hooks/dogfood-refresh.sh"
  chmod +x "$T/worktree-feat/dev/hooks/dogfood-refresh.sh"
) >/dev/null 2>&1

upstream_head="$(git -C "$T/seed" rev-parse HEAD)"
main_head_before="$(git -C "$T/main" rev-parse HEAD)"
wt_head_before="$(git -C "$T/worktree-feat" rev-parse HEAD)"

# Invoke the worktree's copy of the script with DOGFOOD_REFRESH_REPO_ROOT
# UNSET so the auto-detection (and the worktree-redirect block) runs.
unset DOGFOOD_REFRESH_REPO_ROOT
bash "$T/worktree-feat/dev/hooks/dogfood-refresh.sh"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "worktree-redirect exit 0"
else
  fail_msg "worktree-redirect exit 0 (got rc=$rc)"
fi

main_head_after="$(git -C "$T/main" rev-parse HEAD)"
if [ "$main_head_after" = "$upstream_head" ]; then
  pass_msg "worktree-redirect: main repo fast-forwarded to upstream HEAD"
else
  fail_msg "worktree-redirect: main repo fast-forwarded to upstream HEAD (before=$main_head_before after=$main_head_after upstream=$upstream_head)"
fi

wt_head_after="$(git -C "$T/worktree-feat" rev-parse HEAD)"
if [ "$wt_head_after" = "$wt_head_before" ]; then
  pass_msg "worktree-redirect: worktree HEAD unchanged (feature branch undisturbed)"
else
  fail_msg "worktree-redirect: worktree HEAD unchanged (before=$wt_head_before after=$wt_head_after)"
fi

wt_branch="$(git -C "$T/worktree-feat" rev-parse --abbrev-ref HEAD)"
if [ "$wt_branch" = "feat" ]; then
  pass_msg "worktree-redirect: worktree still on feat branch"
else
  fail_msg "worktree-redirect: worktree still on feat branch (got=$wt_branch)"
fi

rm -rf "$T"

# 8. Swap-helper invocation: after ff-merge, refresh must call the symlink-swap
# helper so the local-marketplace install path is replaced with a symlink to
# the repo working tree (the dogfood-as-live promise — #618).
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

# Pre-create a fake installed_plugins.json + cache install dir.
mkdir -p "$T/.claude/plugins"
mkdir -p "$T/fakecache/pipeline/0.20.1"
cat > "$T/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "pipeline@claude-pipeline-local": [
      {
        "projectPath": "$T/clone",
        "installPath": "$T/fakecache/pipeline/0.20.1",
        "marketplace": "claude-pipeline-local"
      }
    ]
  }
}
JSON

HOME="$T" DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "swap-helper invocation exit 0"
else
  fail_msg "swap-helper invocation exit 0 (got rc=$rc)"
fi

if [ -L "$T/fakecache/pipeline/0.20.1" ] && \
   [ "$(readlink "$T/fakecache/pipeline/0.20.1")" = "$T/clone" ]; then
  pass_msg "swap-helper invocation: install path is now a symlink to REPO_ROOT"
else
  fail_msg "swap-helper invocation: install path is now a symlink to REPO_ROOT"
fi

rm -rf "$T"

# 9. Non-staging HEAD guard (#1274 scope 4): the hook hardcodes `origin/staging`
# as its merge target, so it may only fast-forward when HEAD actually IS
# `staging`. In the harness evolve clone this hook fires at SessionStart on
# `evolve` and would silently fast-forward `evolve` onto staging until the
# branches diverge. The symlink-swap half must STILL run on the skip path —
# the guard covers the git half only.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_fixture "$T"

git -C "$T/clone" checkout -q -b evolve

# Advance origin/staging so an unguarded hook would have something to merge.
( set -e
  git -C "$T/seed" commit --quiet --allow-empty -m "non-staging guard upstream"
  git -C "$T/seed" push --quiet origin staging
) >/dev/null 2>&1

# Swap-helper scaffolding (mirrors case 8) so the skip path can be observed.
mkdir -p "$T/.claude/plugins"
mkdir -p "$T/fakecache/pipeline/0.20.1"
cat > "$T/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "pipeline@claude-pipeline-local": [
      {
        "projectPath": "$T/clone",
        "installPath": "$T/fakecache/pipeline/0.20.1",
        "marketplace": "claude-pipeline-local"
      }
    ]
  }
}
JSON

upstream_head="$(git -C "$T/seed" rev-parse HEAD)"
clone_head_before="$(git -C "$T/clone" rev-parse HEAD)"
if [ "$clone_head_before" != "$upstream_head" ]; then
  pass_msg "non-staging guard fixture sanity: origin/staging is ahead of the clone"
else
  fail_msg "non-staging guard fixture sanity: origin/staging is ahead of the clone"
fi

HOME="$T" DOGFOOD_REFRESH_REPO_ROOT="$T/clone" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "non-staging guard exit 0"
else
  fail_msg "non-staging guard exit 0 (got rc=$rc)"
fi

clone_head_after="$(git -C "$T/clone" rev-parse HEAD)"
if [ "$clone_head_after" = "$clone_head_before" ]; then
  pass_msg "non-staging guard: HEAD unchanged (no fast-forward onto origin/staging)"
else
  fail_msg "non-staging guard: HEAD unchanged (before=$clone_head_before after=$clone_head_after upstream=$upstream_head)"
fi

clone_branch="$(git -C "$T/clone" symbolic-ref --short HEAD 2>/dev/null || true)"
if [ "$clone_branch" = "evolve" ]; then
  pass_msg "non-staging guard: still checked out on evolve"
else
  fail_msg "non-staging guard: still checked out on evolve (got=$clone_branch)"
fi

# Control: skipping the fetch/merge must NOT swallow the symlink swap.
if [ -L "$T/fakecache/pipeline/0.20.1" ] && \
   [ "$(readlink "$T/fakecache/pipeline/0.20.1")" = "$T/clone" ]; then
  pass_msg "non-staging guard: swap helper still ran (install path is a symlink to REPO_ROOT)"
else
  fail_msg "non-staging guard: swap helper still ran (install path is a symlink to REPO_ROOT)"
fi

rm -rf "$T"
trap - EXIT

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
