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
trap - EXIT

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
