#!/bin/bash
set -euo pipefail

# Tests that scripts/sync-worktrees.sh mirrors freshly-added scratch
# attachments into already-active worktrees by parsing the issue number
# from the worktree path's PIPELINE_WORKTREE_PREFIX-<N>-<slug> suffix.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/sync-worktrees.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MAIN_REPO="$TMP/main"
WT="$MAIN_REPO/.claude/worktrees/wt-42-something"
mkdir -p "$MAIN_REPO/.claude/scratch/issue-42"
mkdir -p "$WT/.claude"
# Stage existing files in main that the sync loop already handles.
mkdir -p "$MAIN_REPO/.claude/hooks"
echo "{}" > "$MAIN_REPO/.claude/settings.local.json"

# Add a NEW attachment after the worktree exists — sync should pick it up.
echo "newshot" > "$MAIN_REPO/.claude/scratch/issue-42/newshot.png"

cat > "$MAIN_REPO/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_SYNC_FILES=""
PIPELINE_SYNC_DOCS=""
CFG

# Stub git so worktree list emits our staged worktrees.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<GIT_STUB
#!/bin/bash
if [ "\${1:-}" = "-C" ]; then shift 2; fi
case "\${1:-}" in
  worktree)
    case "\${2:-}" in
      list)
        printf '%s\n' "$MAIN_REPO        deadbeef [main]"
        printf '%s\n' "$WT        cafe1234 [feature/wt-42]"
        ;;
    esac
    ;;
  fetch|push) ;;
  branch)
    # branch -r --list 'origin/feature/*' → empty (no remote branches).
    ;;
  ls-files) exit 1 ;;
  *) ;;
esac
GIT_STUB
chmod +x "$STUB_BIN/git"

# Stub gh so the branch-pruning step is a no-op.
cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
exit 0
GH
chmod +x "$STUB_BIN/gh"

# Stub jq just enough for ALLOW_DELETIONS extraction (returns empty → skip).
# (Real jq is fine if present; if not, this fallback works.)
if ! command -v jq >/dev/null 2>&1; then
  cat > "$STUB_BIN/jq" <<'JQ'
#!/bin/bash
echo ""
JQ
  chmod +x "$STUB_BIN/jq"
fi

export PATH="$STUB_BIN:$PATH"
export PIPELINE_PROJECT_ROOT="$MAIN_REPO"

cd "$MAIN_REPO"
set +e
bash "$HELPER" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "STDOUT:"; cat "$TMP/out"
  echo "STDERR:"; cat "$TMP/err"
  fail_msg "sync-worktrees.sh exited $rc"
fi

TARGET="$WT/.claude/scratch/issue-42/newshot.png"
if [ -f "$TARGET" ]; then
  pass_msg "freshly-added scratch attachment mirrored into worktree"
else
  fail_msg "expected $TARGET to exist; out=$(cat "$TMP/out")"
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
