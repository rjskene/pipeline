#!/bin/bash
set -uo pipefail

# Tests that scripts/setup-worktree.sh rejects branch names without an allowed
# Conventional Commits prefix (issue #350). Without this guard, a bare integer
# like `setup-worktree.sh 81` silently produces a malformed `wt-81` worktree
# on a branch literally named `81`, which breaks downstream pipeline stages.
#
# Cases:
#   1. Bare integer rejection  : `setup-worktree.sh 81`        -> non-zero, no worktree dir
#   2. Positive control        : `setup-worktree.sh feature/foo 81` -> exit 0, wt-81-foo created
#   3. No-prefix rejection     : `setup-worktree.sh randomthing 81` -> non-zero

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/setup-worktree.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Build a minimal project skeleton with pipeline.config and PATH-stubbed
# git/gh binaries that satisfy the happy-path flow in setup-worktree.sh.
setup_env() {
  local proj="$1"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/hooks" "$proj/.claude/worktrees"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="test/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
EOF

  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"

  # git stub: handle every subcommand setup-worktree.sh issues on the happy
  # path. `worktree add` actually creates the target dir so the test can
  # assert on the post-condition.
  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
# Strip leading `-C <dir>` if present.
if [ "${1:-}" = "-C" ]; then shift 2; fi
case "${1:-}" in
  worktree)
    case "${2:-}" in
      list) exit 0 ;;
      add)
        # Args: add <path> [-b <branch> | <branch>]
        mkdir -p "$3"
        exit 0
        ;;
      *) exit 0 ;;
    esac ;;
  show-ref) exit 1 ;;        # branch doesn't exist yet -> use -b
  ls-files) exit 1 ;;        # treat all hooks as untracked (none in stub)
  rev-parse) echo "staging"; exit 0 ;;
  ls-remote) echo "abc123 refs/heads/staging"; exit 0 ;;
  push) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$stub_dir/git"

  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$stub_dir/gh"

  echo "$stub_dir"
}

run_setup() {
  local proj="$1" stub_dir="$2"; shift 2
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      PIPELINE_PROJECT_ROOT="$proj" \
      PIPELINE_LOGS_ENABLED="false" \
      bash "$SCRIPT_UNDER_TEST" "$@" 2>&1
    echo "EXIT=$?"
  )
}

# ---- Case 1: bare integer rejection ----
echo "Case 1: bare integer '81' must be rejected (no prefix)"
inc
PROJ="$WORKDIR/p1"
STUB=$(setup_env "$PROJ")
OUT=$(run_setup "$PROJ" "$STUB" 81)
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if [ "$exit_line" = "EXIT=0" ]; then
  fail_msg "case 1 expected non-zero exit, got $exit_line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
# Critical post-condition: no worktree dir should have been created under
# .claude/worktrees/ for the bogus branch name '81'.
if find "$PROJ/.claude/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  fail_msg "case 1 expected NO worktree dir under $PROJ/.claude/worktrees, but found one"
  ls -la "$PROJ/.claude/worktrees" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 1 rejects bare integer '81'"

# ---- Case 2: positive control (feature/foo 81 -> wt-81-foo) ----
echo "Case 2: 'feature/foo 81' must succeed and create wt-81-foo"
inc
PROJ="$WORKDIR/p2"
STUB=$(setup_env "$PROJ")
OUT=$(run_setup "$PROJ" "$STUB" feature/foo 81)
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if [ "$exit_line" != "EXIT=0" ]; then
  fail_msg "case 2 expected exit 0, got $exit_line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ ! -d "$PROJ/.claude/worktrees/wt-81-foo" ]; then
  fail_msg "case 2 expected $PROJ/.claude/worktrees/wt-81-foo to exist"
  ls -la "$PROJ/.claude/worktrees" 2>&1 | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 2 creates wt-81-foo for feature/foo 81"

# ---- Case 3: no-prefix rejection ----
echo "Case 3: 'randomthing 81' must be rejected (no allowed prefix)"
inc
PROJ="$WORKDIR/p3"
STUB=$(setup_env "$PROJ")
OUT=$(run_setup "$PROJ" "$STUB" randomthing 81)
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if [ "$exit_line" = "EXIT=0" ]; then
  fail_msg "case 3 expected non-zero exit, got $exit_line"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if find "$PROJ/.claude/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  fail_msg "case 3 expected NO worktree dir under $PROJ/.claude/worktrees, but found one"
  ls -la "$PROJ/.claude/worktrees" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 3 rejects 'randomthing' (no allowed prefix)"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
