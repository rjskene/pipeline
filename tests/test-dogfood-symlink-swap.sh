#!/bin/bash
set -uo pipefail

# Tests for dev/hooks/dogfood-symlink-swap.sh — dogfood-only self-heal that
# replaces the local-marketplace cache install directory with a symlink to
# the repo working tree. Invoked from dogfood-refresh.sh after the ff-merge.
#
# Coverage:
#   1. Existence.
#   2. Executable bit.
#   3. Shebang.
#   4. Happy-path: cache dir replaced with symlink to REPO_ROOT.
#   5. Idempotence: re-run preserves the symlink (no inode/mtime churn).
#   6. Missing jq → fail-open (cache path unchanged).
#   7. Malformed JSON → fail-open.
#   8. Missing installed_plugins.json → fail-open.
#   9. No matching projectPath entry → fail-open (cache path unchanged).
#  10. Array with multiple entries — only the matching projectPath swapped.
#  11. Already-symlinked correctly → no inode change.
#  12. Already-symlinked elsewhere → replaced to point at REPO_ROOT.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/dev/hooks/dogfood-symlink-swap.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. Existence.
if [ -f "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-symlink-swap.sh exists"
else
  fail_msg "dev/hooks/dogfood-symlink-swap.sh exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# 2. Executable.
if [ -x "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-symlink-swap.sh is executable"
else
  fail_msg "dev/hooks/dogfood-symlink-swap.sh is executable"
fi

# 3. Shebang.
first_line="$(head -n1 "$TARGET")"
case "$first_line" in
  "#!/usr/bin/env bash"|"#!/bin/bash")
    pass_msg "shebang is bash"
    ;;
  *)
    fail_msg "shebang is bash (got: $first_line)"
    ;;
esac

# Fixture helpers.
mk_repo() {
  # Args: <abs-path>
  # Create a minimal directory that "looks like" the repo working tree.
  local R="$1"
  mkdir -p "$R"
  : > "$R/marker.txt"
}

write_ip_json() {
  # Args: <home> <project_path> <install_path>
  local H="$1" PP="$2" IP="$3"
  mkdir -p "$H/.claude/plugins"
  cat > "$H/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "pipeline@claude-pipeline-local": [
      {
        "projectPath": "$PP",
        "installPath": "$IP",
        "marketplace": "claude-pipeline-local"
      }
    ]
  }
}
JSON
}

# 4. Happy-path: cache dir replaced with symlink to REPO_ROOT.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
: > "$T/fakecache/pipeline/0.20.1/sentinel.txt"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "happy-path exit 0"
else
  fail_msg "happy-path exit 0 (got rc=$rc)"
fi

if [ -L "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "happy-path: install path is now a symlink"
else
  fail_msg "happy-path: install path is now a symlink"
fi

current="$(readlink "$T/fakecache/pipeline/0.20.1" 2>/dev/null || true)"
if [ "$current" = "$T/repo" ]; then
  pass_msg "happy-path: symlink target = REPO_ROOT"
else
  fail_msg "happy-path: symlink target = REPO_ROOT (got: $current)"
fi

rm -rf "$T"

# 5. Idempotence: re-run preserves symlink, no inode churn.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET" >/dev/null 2>&1
inode_before="$(stat -c %i "$T/fakecache/pipeline/0.20.1" 2>/dev/null || echo X)"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
inode_after="$(stat -c %i "$T/fakecache/pipeline/0.20.1" 2>/dev/null || echo Y)"

if [ "$rc" -eq 0 ]; then
  pass_msg "idempotence exit 0"
else
  fail_msg "idempotence exit 0 (got rc=$rc)"
fi

if [ "$inode_before" = "$inode_after" ]; then
  pass_msg "idempotence: symlink inode preserved"
else
  fail_msg "idempotence: symlink inode preserved (before=$inode_before after=$inode_after)"
fi

rm -rf "$T"

# 6. Missing jq → fail-open.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

# Empty PATH excludes jq (and most other things). Use /usr/bin/env via absolute
# shebang to keep the helper invocable. We invoke via `bash` explicitly.
HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" PATH="/empty" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "missing-jq fail-open exit 0"
else
  fail_msg "missing-jq fail-open exit 0 (got rc=$rc)"
fi

if [ -d "$T/fakecache/pipeline/0.20.1" ] && [ ! -L "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "missing-jq fail-open: cache dir unchanged (still regular dir)"
else
  fail_msg "missing-jq fail-open: cache dir unchanged"
fi

rm -rf "$T"

# 7. Malformed JSON → fail-open.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
mkdir -p "$T/.claude/plugins"
echo "not-json" > "$T/.claude/plugins/installed_plugins.json"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "malformed-JSON fail-open exit 0"
else
  fail_msg "malformed-JSON fail-open exit 0 (got rc=$rc)"
fi

if [ -d "$T/fakecache/pipeline/0.20.1" ] && [ ! -L "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "malformed-JSON fail-open: cache dir unchanged"
else
  fail_msg "malformed-JSON fail-open: cache dir unchanged"
fi

rm -rf "$T"

# 8. Missing installed_plugins.json → fail-open.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
# Deliberately do NOT create installed_plugins.json.

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "missing-file fail-open exit 0"
else
  fail_msg "missing-file fail-open exit 0 (got rc=$rc)"
fi

if [ -d "$T/fakecache/pipeline/0.20.1" ] && [ ! -L "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "missing-file fail-open: cache dir unchanged"
else
  fail_msg "missing-file fail-open: cache dir unchanged"
fi

rm -rf "$T"

# 9. No matching projectPath → fail-open.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
# JSON references a DIFFERENT projectPath.
write_ip_json "$T" "$T/some-other-repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "no-matching-projectPath fail-open exit 0"
else
  fail_msg "no-matching-projectPath fail-open exit 0 (got rc=$rc)"
fi

if [ -d "$T/fakecache/pipeline/0.20.1" ] && [ ! -L "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "no-matching-projectPath fail-open: cache dir unchanged"
else
  fail_msg "no-matching-projectPath fail-open: cache dir unchanged"
fi

rm -rf "$T"

# 10. Array with multiple entries — only matching projectPath swapped.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repoA"
mk_repo "$T/repoB"
mkdir -p "$T/fakecache/pipeline/0.20.1-A"
mkdir -p "$T/fakecache/pipeline/0.20.1-B"
mkdir -p "$T/.claude/plugins"
cat > "$T/.claude/plugins/installed_plugins.json" <<JSON
{
  "plugins": {
    "pipeline@claude-pipeline-local": [
      {
        "projectPath": "$T/repoA",
        "installPath": "$T/fakecache/pipeline/0.20.1-A",
        "marketplace": "claude-pipeline-local"
      },
      {
        "projectPath": "$T/repoB",
        "installPath": "$T/fakecache/pipeline/0.20.1-B",
        "marketplace": "claude-pipeline-local"
      }
    ]
  }
}
JSON

# Swap only the A entry.
HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repoA" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "multi-entry exit 0"
else
  fail_msg "multi-entry exit 0 (got rc=$rc)"
fi

if [ -L "$T/fakecache/pipeline/0.20.1-A" ] && \
   [ "$(readlink "$T/fakecache/pipeline/0.20.1-A")" = "$T/repoA" ]; then
  pass_msg "multi-entry: matching projectPath swapped to symlink"
else
  fail_msg "multi-entry: matching projectPath swapped to symlink"
fi

if [ -d "$T/fakecache/pipeline/0.20.1-B" ] && [ ! -L "$T/fakecache/pipeline/0.20.1-B" ]; then
  pass_msg "multi-entry: non-matching entry untouched"
else
  fail_msg "multi-entry: non-matching entry untouched"
fi

rm -rf "$T"

# 11. Already-symlinked-correctly → no inode change.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline"
ln -s "$T/repo" "$T/fakecache/pipeline/0.20.1"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

inode_before="$(stat -c %i "$T/fakecache/pipeline/0.20.1" 2>/dev/null || echo X)"
HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
inode_after="$(stat -c %i "$T/fakecache/pipeline/0.20.1" 2>/dev/null || echo Y)"

if [ "$rc" -eq 0 ]; then
  pass_msg "already-correct-symlink exit 0"
else
  fail_msg "already-correct-symlink exit 0 (got rc=$rc)"
fi

if [ "$inode_before" = "$inode_after" ]; then
  pass_msg "already-correct-symlink: inode preserved"
else
  fail_msg "already-correct-symlink: inode preserved (before=$inode_before after=$inode_after)"
fi

rm -rf "$T"

# 12. Already-symlinked-elsewhere → replaced.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mk_repo "$T/wrong-target"
mkdir -p "$T/fakecache/pipeline"
ln -s "$T/wrong-target" "$T/fakecache/pipeline/0.20.1"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_SYMLINK_SWAP_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "already-wrong-symlink exit 0"
else
  fail_msg "already-wrong-symlink exit 0 (got rc=$rc)"
fi

current="$(readlink "$T/fakecache/pipeline/0.20.1" 2>/dev/null || true)"
if [ "$current" = "$T/repo" ]; then
  pass_msg "already-wrong-symlink: target updated to REPO_ROOT"
else
  fail_msg "already-wrong-symlink: target updated to REPO_ROOT (got: $current)"
fi

rm -rf "$T"
trap - EXIT

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
