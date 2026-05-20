#!/bin/bash
set -euo pipefail

# Tests that scripts/setup-worktree.sh mirrors
# $MAIN_REPO/.claude/scratch/issue-<N>/ into
# $WORKTREE_PATH/.claude/scratch/issue-<N>/ when ISSUE_NUM is provided
# and the source dir exists.
#
# `git worktree` and the install command are stubbed; we exercise only the
# new copy step.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/setup-worktree.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stage a fake "main repo" with a pipeline.config and a scratch dir for #42.
MAIN_REPO="$TMP/main"
mkdir -p "$MAIN_REPO/.claude/scratch/issue-42"
echo "deadbeef" > "$MAIN_REPO/.claude/scratch/issue-42/screenshot.png"

cat > "$MAIN_REPO/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
CFG

# Stub `git` so the helper's `git -C ... worktree add` and `git ... rev-parse`
# calls succeed deterministically. The stub creates the target worktree dir
# instead of invoking real git.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<'GIT_STUB'
#!/bin/bash
# Strip leading `-C <dir>` if present.
if [ "${1:-}" = "-C" ]; then shift 2; fi
cmd="${1:-}"
case "$cmd" in
  worktree)
    sub="${2:-}"
    case "$sub" in
      list)
        # Pretend no worktrees yet exist.
        ;;
      add)
        # Args: [-b <branch>] <path> <branch>  OR  <path> <branch>
        # We just need to create the target directory.
        shift 2
        # Optional -b
        if [ "${1:-}" = "-b" ]; then shift 2; fi
        path="$1"
        mkdir -p "$path"
        ;;
    esac
    ;;
  rev-parse)
    echo "staging"
    ;;
  show-ref)
    # Pretend the branch does not yet exist (so the helper takes the -b path).
    exit 1
    ;;
  ls-remote)
    # Pretend the base branch already exists on remote.
    echo "refs/heads/${3:-staging}"
    ;;
  ls-files)
    exit 1
    ;;
  push)
    ;;
  *)
    ;;
esac
GIT_STUB
chmod +x "$STUB_BIN/git"
export PATH="$STUB_BIN:$PATH"

# Drive the helper.
cd "$MAIN_REPO"
export PIPELINE_PROJECT_ROOT="$MAIN_REPO"

set +e
bash "$HELPER" feature/wt-42 42 >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "STDOUT:"; cat "$TMP/out"
  echo "STDERR:"; cat "$TMP/err"
  fail_msg "setup-worktree.sh exited $rc"
fi

WORKTREE_PATH="$MAIN_REPO/.claude/worktrees/wt-42-wt-42"
TARGET="$WORKTREE_PATH/.claude/scratch/issue-42/screenshot.png"

if [ -f "$TARGET" ]; then
  pass_msg "scratch attachment mirrored to worktree"
else
  fail_msg "expected $TARGET to exist (worktree contents: $(ls -la "$WORKTREE_PATH/.claude/" 2>/dev/null))"
fi

if [ -f "$TARGET" ] && diff -q "$MAIN_REPO/.claude/scratch/issue-42/screenshot.png" "$TARGET" >/dev/null 2>&1; then
  pass_msg "mirrored bytes identical to source"
else
  fail_msg "mirrored file differs from source"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
