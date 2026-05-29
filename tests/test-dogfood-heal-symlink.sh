#!/bin/bash
set -uo pipefail

# Tests for dev/hooks/dogfood-heal-symlink.sh — dogfood-only, heal-ONLY wrapper
# that re-asserts the local-marketplace install symlink on every UserPromptSubmit
# (issue #624). Unlike dogfood-refresh.sh, it pays NO git fetch/merge cost — it is
# the cheap per-prompt path that closes the mid-session gap left by SessionStart-only
# healing (e.g. /remote-control wiping the cache dir).
#
# Coverage:
#   1. Existence.
#   2. Executable bit.
#   3. Shebang.
#   4. No `git fetch` / `git merge` (proves cheap path, not a dogfood-refresh clone).
#   5. Delegates to dogfood-symlink-swap.sh passing DOGFOOD_SYMLINK_SWAP_REPO_ROOT.
#   6. Happy-path: cache install dir replaced with symlink to REPO_ROOT, exit 0.
#   7. Mid-session re-removal heal: delete symlink, re-run, symlink restored.
#   8. Fail-open: missing installed_plugins.json → exit 0, no crash.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/dev/hooks/dogfood-heal-symlink.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. Existence.
if [ -f "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-heal-symlink.sh exists"
else
  fail_msg "dev/hooks/dogfood-heal-symlink.sh exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# 2. Executable.
if [ -x "$TARGET" ]; then
  pass_msg "dev/hooks/dogfood-heal-symlink.sh is executable"
else
  fail_msg "dev/hooks/dogfood-heal-symlink.sh is executable"
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

# 4. No git fetch / git merge — the wrapper must be the cheap per-prompt path.
#    Strip comment lines first: we care about executed commands, not the prose
#    that documents WHY this path skips fetch/merge.
code_only="$(grep -vE '^[[:space:]]*#' "$TARGET")"
if printf '%s\n' "$code_only" | grep -Eq 'git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(fetch|merge)\b'; then
  fail_msg "wrapper must NOT run git fetch/merge (cheap per-prompt path)"
else
  pass_msg "wrapper does not run git fetch/merge"
fi

# 5. Delegates to swap helper passing DOGFOOD_SYMLINK_SWAP_REPO_ROOT.
if grep -q "dogfood-symlink-swap.sh" "$TARGET" \
   && grep -q "DOGFOOD_SYMLINK_SWAP_REPO_ROOT" "$TARGET"; then
  pass_msg "delegates to dogfood-symlink-swap.sh via DOGFOOD_SYMLINK_SWAP_REPO_ROOT"
else
  fail_msg "delegates to dogfood-symlink-swap.sh via DOGFOOD_SYMLINK_SWAP_REPO_ROOT"
fi

# Fixture helpers (mirror tests/test-dogfood-symlink-swap.sh).
mk_repo() {
  local R="$1"
  mkdir -p "$R"
  : > "$R/marker.txt"
}

write_ip_json() {
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

# 6. Happy-path: cache dir replaced with symlink to REPO_ROOT.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
: > "$T/fakecache/pipeline/0.20.1/sentinel.txt"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_HEAL_SYMLINK_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "happy-path exit 0"
else
  fail_msg "happy-path exit 0 (got rc=$rc)"
fi

if [ -L "$T/fakecache/pipeline/0.20.1" ] \
   && [ "$(readlink "$T/fakecache/pipeline/0.20.1" 2>/dev/null || true)" = "$T/repo" ]; then
  pass_msg "happy-path: install path is now a symlink to REPO_ROOT"
else
  fail_msg "happy-path: install path is now a symlink to REPO_ROOT"
fi

rm -rf "$T"

# 7. Mid-session re-removal heal: simulate /remote-control wiping the symlink,
#    then re-run the wrapper and confirm the symlink is restored.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
mkdir -p "$T/fakecache/pipeline/0.20.1"
write_ip_json "$T" "$T/repo" "$T/fakecache/pipeline/0.20.1"

HOME="$T" DOGFOOD_HEAL_SYMLINK_REPO_ROOT="$T/repo" bash "$TARGET" >/dev/null 2>&1
# Mid-session wipe: remove the freshly-created symlink.
rm -f "$T/fakecache/pipeline/0.20.1"
if [ ! -e "$T/fakecache/pipeline/0.20.1" ]; then
  pass_msg "re-removal: symlink wiped (mid-session re-materialization simulated)"
else
  fail_msg "re-removal: symlink wiped"
fi

HOME="$T" DOGFOOD_HEAL_SYMLINK_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ] \
   && [ -L "$T/fakecache/pipeline/0.20.1" ] \
   && [ "$(readlink "$T/fakecache/pipeline/0.20.1" 2>/dev/null || true)" = "$T/repo" ]; then
  pass_msg "re-removal heal: symlink restored on re-run"
else
  fail_msg "re-removal heal: symlink restored on re-run (rc=$rc)"
fi

rm -rf "$T"

# 8. Fail-open: missing installed_plugins.json → exit 0.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mk_repo "$T/repo"
# Deliberately do NOT create installed_plugins.json.

HOME="$T" DOGFOOD_HEAL_SYMLINK_REPO_ROOT="$T/repo" bash "$TARGET"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "missing-file fail-open exit 0"
else
  fail_msg "missing-file fail-open exit 0 (got rc=$rc)"
fi

rm -rf "$T"
trap - EXIT

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
