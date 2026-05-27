#!/bin/bash
set -euo pipefail
# Tests that scripts/setup-worktree.sh copies $MAIN_REPO/pipeline.config into
# $WORKTREE_PATH/pipeline.config so the worktree-local `source ./pipeline.config`
# in execute-issue-plan / evaluate-issue-pr Boot resolves PIPELINE_* vars.
# pipeline.config is gitignored + host-specific, so this test stages a synthetic
# config in a temp main checkout — it never reads the host's live config (#529).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/setup-worktree.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
MAIN_REPO="$TMP/main"; mkdir -p "$MAIN_REPO"
cat > "$MAIN_REPO/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
CFG
STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<'GIT_STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
cmd="${1:-}"
case "$cmd" in
  worktree)
    sub="${2:-}"
    case "$sub" in
      list) ;;
      add)
        shift 2
        if [ "${1:-}" = "-b" ]; then shift 2; fi
        path="$1"; mkdir -p "$path" ;;
    esac ;;
  rev-parse) echo "staging" ;;
  show-ref) exit 1 ;;
  ls-remote) echo "refs/heads/${3:-staging}" ;;
  ls-files) exit 1 ;;
  push) ;;
  *) ;;
esac
GIT_STUB
chmod +x "$STUB_BIN/git"
export PATH="$STUB_BIN:$PATH"
cd "$MAIN_REPO"
export PIPELINE_PROJECT_ROOT="$MAIN_REPO"
set +e
bash "$HELPER" feature/wt-77 77 >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then echo "STDOUT:"; cat "$TMP/out"; echo "STDERR:"; cat "$TMP/err"; fail_msg "setup-worktree.sh exited $rc"; fi
WORKTREE_PATH="$MAIN_REPO/.claude/worktrees/wt-77-wt-77"
TARGET="$WORKTREE_PATH/pipeline.config"
if [ -f "$TARGET" ]; then pass_msg "pipeline.config copied to worktree"; else fail_msg "expected $TARGET to exist"; fi
if [ -f "$TARGET" ] && diff -q "$MAIN_REPO/pipeline.config" "$TARGET" >/dev/null 2>&1; then
  pass_msg "copied bytes identical to source"
else
  fail_msg "copied file differs from source"
fi
# Sourcing the worktree copy must populate PIPELINE_REPO (the real-world symptom).
RESOLVED=$(cd "$WORKTREE_PATH" && source ./pipeline.config 2>/dev/null && echo "$PIPELINE_REPO")
if [ "$RESOLVED" = "rjskene/pipeline" ]; then
  pass_msg "worktree-local source resolves PIPELINE_REPO"
else
  fail_msg "worktree-local source did not resolve PIPELINE_REPO (got '$RESOLVED')"
fi
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
