#!/bin/bash
set -euo pipefail
# Regression test for #1368: scripts/setup-worktree.sh must not abort with an
# unbound-variable error when a pipeline.config predates the sync knobs
# (PIPELINE_SYNC_ENVS / PIPELINE_SYNC_VENVS). Two cases: (1) a knobless
# config — omits both of those entirely, the pre-knob shape that repros the
# bug; (2) a control config with the same knobs explicitly set to "". Both
# must produce the same result: exit 0, worktree created. Fixture shape
# follows tests/test-setup-worktree-config-copy.sh.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/setup-worktree.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
mkdir -p "$PWD/.claude/scratch"
TMP=$(mktemp -d -p "$PWD/.claude/scratch"); trap 'rm -rf "$TMP"' EXIT

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

mk_repo() {
  local dir="$1" sync_lines="$2"
  mkdir -p "$dir"
  {
    echo 'PIPELINE_REPO="rjskene/pipeline"'
    echo 'PIPELINE_BASE_BRANCH="staging"'
    echo 'PIPELINE_WORKTREE_PREFIX="wt"'
    echo 'PIPELINE_INSTALL_CMD="true"'
    echo 'PIPELINE_SEED_CMD=""'
    printf '%s\n' "$sync_lines"
  } > "$dir/pipeline.config"
}

run_case() {
  local dir="$1" label="$2" rc
  set +e
  # Unset ambient PIPELINE_SYNC_ENVS / PIPELINE_SYNC_VENVS first: the calling session may already
  # export them (agents source pipeline.config with `set -a`), which would
  # mask the pre-knob repro by leaking a defined value into the child even
  # when the fixture's own pipeline.config omits the assignment.
  ( unset PIPELINE_SYNC_ENVS PIPELINE_SYNC_VENVS
    cd "$dir" && PIPELINE_PROJECT_ROOT="$dir" bash "$HELPER" feature/wt-77 77 ) \
    >"$TMP/$label.out" 2>"$TMP/$label.err"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass_msg "$label: setup-worktree.sh exited 0"
  else
    echo "STDOUT:"; cat "$TMP/$label.out"; echo "STDERR:"; cat "$TMP/$label.err"
    fail_msg "$label: setup-worktree.sh exited $rc"
  fi
  if [ -d "$dir/.claude/worktrees/wt-77-wt-77" ]; then
    pass_msg "$label: worktree directory exists"
  else
    fail_msg "$label: expected worktree dir missing"
  fi
}

# Case 1: knobless config — omits PIPELINE_SYNC_ENVS / PIPELINE_SYNC_VENVS.
mk_repo "$TMP/knobless" ""
run_case "$TMP/knobless" "knobless"

# Case 2 (control): same config, knobs explicitly set to "".
mk_repo "$TMP/control" $'PIPELINE_SYNC_ENVS=""\nPIPELINE_SYNC_VENVS=""'
run_case "$TMP/control" "control"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
