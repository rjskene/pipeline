#!/bin/bash
set -uo pipefail

# Tests the PIPELINE_BRANCH_SUFFIX knob in scripts/setup-worktree.sh (#1579).
# When set, the knob appends `-<suffix>` to every feature branch (and so to the
# worktree slug); the final branch is printed on a `Branch:` output line.
#
# Cases:
#   1. knob unset             : feature/foo 81 -> wt-81-foo, -b feature/foo, `Branch:      feature/foo`
#   2. knob=r221900           : feature/foo 81 -> wt-81-foo-r221900, -b feature/foo-r221900
#   3. already suffixed input : feature/foo-r221900 81 + knob -> no doubled suffix
#   4. knob=R22-x (invalid)   : exit 2, ERROR on stderr, no worktree, no git call

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

# The knob must come only from each case's explicit setting.
unset PIPELINE_BRANCH_SUFFIX

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Minimal project skeleton with pipeline.config and PATH-stubbed git/gh
# (harness copied from tests/test-setup-worktree-arg-validation.sh). The git
# stub also logs every call (after the `-C <dir>` strip) to git-calls.log.
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

  cat > "$stub_dir/git" <<'EOF'
#!/bin/bash
# Strip leading `-C <dir>` if present.
if [ "${1:-}" = "-C" ]; then shift 2; fi
echo "$*" >> "$PIPELINE_PROJECT_ROOT/git-calls.log"
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
  ls-files) exit 1 ;;
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

# run_setup <proj> <stub_dir> <args...>
# Passes PIPELINE_BRANCH_SUFFIX through from the caller env. stdout goes to
# the captured output; stderr is written to <proj>/stderr.log.
run_setup() {
  local proj="$1" stub_dir="$2"; shift 2
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      PIPELINE_PROJECT_ROOT="$proj" \
      PIPELINE_LOGS_ENABLED="false" \
      bash "$SCRIPT_UNDER_TEST" "$@" 2>"$proj/stderr.log"
    echo "EXIT=$?"
  )
}

# ---- Case 1: knob unset ----
echo "Case 1: knob unset — 'feature/foo 81' -> wt-81-foo, Branch: feature/foo"
inc
PROJ="$WORKDIR/p1"
STUB=$(setup_env "$PROJ")
OUT=$(run_setup "$PROJ" "$STUB" feature/foo 81)
ok=1
if [ "$(echo "$OUT" | tail -n1)" != "EXIT=0" ]; then
  fail_msg "case 1 expected exit 0, got $(echo "$OUT" | tail -n1)"; ok=0
fi
if [ ! -d "$PROJ/.claude/worktrees/wt-81-foo" ]; then
  fail_msg "case 1 expected wt-81-foo to exist"; ok=0
fi
if ! grep -q -- "-b feature/foo\( \|$\)" "$PROJ/git-calls.log" 2>/dev/null; then
  fail_msg "case 1 expected git call with '-b feature/foo'"; ok=0
fi
if ! echo "$OUT" | grep -qxF "  Branch:      feature/foo"; then
  fail_msg "case 1 expected output line 'Branch:      feature/foo'"; ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 1 knob unset keeps feature/foo and prints Branch: line"

# ---- Case 2: knob set ----
echo "Case 2: PIPELINE_BRANCH_SUFFIX=r221900 — 'feature/foo 81' -> wt-81-foo-r221900"
inc
PROJ="$WORKDIR/p2"
STUB=$(setup_env "$PROJ")
OUT=$(PIPELINE_BRANCH_SUFFIX=r221900 run_setup "$PROJ" "$STUB" feature/foo 81)
ok=1
if [ "$(echo "$OUT" | tail -n1)" != "EXIT=0" ]; then
  fail_msg "case 2 expected exit 0, got $(echo "$OUT" | tail -n1)"; ok=0
fi
if [ ! -d "$PROJ/.claude/worktrees/wt-81-foo-r221900" ]; then
  fail_msg "case 2 expected wt-81-foo-r221900 to exist"; ok=0
fi
if [ -d "$PROJ/.claude/worktrees/wt-81-foo" ]; then
  fail_msg "case 2 found unsuffixed wt-81-foo"; ok=0
fi
if ! grep -q -- "-b feature/foo-r221900\( \|$\)" "$PROJ/git-calls.log" 2>/dev/null; then
  fail_msg "case 2 expected git call with '-b feature/foo-r221900'"; ok=0
fi
if ! echo "$OUT" | grep -qxF "  Branch:      feature/foo-r221900"; then
  fail_msg "case 2 expected output line 'Branch:      feature/foo-r221900'"; ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 2 knob appends -r221900 to branch and worktree"

# ---- Case 3: already suffixed input ----
echo "Case 3: 'feature/foo-r221900 81' with knob r221900 — no doubled suffix"
inc
PROJ="$WORKDIR/p3"
STUB=$(setup_env "$PROJ")
OUT=$(PIPELINE_BRANCH_SUFFIX=r221900 run_setup "$PROJ" "$STUB" feature/foo-r221900 81)
ok=1
if [ "$(echo "$OUT" | tail -n1)" != "EXIT=0" ]; then
  fail_msg "case 3 expected exit 0, got $(echo "$OUT" | tail -n1)"; ok=0
fi
if [ ! -d "$PROJ/.claude/worktrees/wt-81-foo-r221900" ]; then
  fail_msg "case 3 expected wt-81-foo-r221900 to exist"; ok=0
fi
if ! grep -q -- "-b feature/foo-r221900\( \|$\)" "$PROJ/git-calls.log" 2>/dev/null; then
  fail_msg "case 3 expected git call with '-b feature/foo-r221900'"; ok=0
fi
if ! echo "$OUT" | grep -qxF "  Branch:      feature/foo-r221900"; then
  fail_msg "case 3 expected output line 'Branch:      feature/foo-r221900'"; ok=0
fi
if echo "$OUT" | grep -q "r221900-r221900" \
   || grep -q "r221900-r221900" "$PROJ/git-calls.log" 2>/dev/null \
   || ls "$PROJ/.claude/worktrees" | grep -q "r221900-r221900"; then
  fail_msg "case 3 found a doubled suffix 'r221900-r221900'"; ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 3 already-suffixed branch is not doubled"

# ---- Case 4: invalid knob value ----
echo "Case 4: PIPELINE_BRANCH_SUFFIX=R22-x — exit 2, no worktree, no git call"
inc
PROJ="$WORKDIR/p4"
STUB=$(setup_env "$PROJ")
OUT=$(PIPELINE_BRANCH_SUFFIX=R22-x run_setup "$PROJ" "$STUB" feature/foo 81)
ok=1
if [ "$(echo "$OUT" | tail -n1)" != "EXIT=2" ]; then
  fail_msg "case 4 expected EXIT=2, got $(echo "$OUT" | tail -n1)"; ok=0
fi
if ! grep -qF "PIPELINE_BRANCH_SUFFIX must be lowercase letters and digits — got: R22-x" "$PROJ/stderr.log"; then
  fail_msg "case 4 expected the lowercase-letters-and-digits ERROR on stderr"
  sed 's/^/    /' "$PROJ/stderr.log"; ok=0
fi
if find "$PROJ/.claude/worktrees" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  fail_msg "case 4 expected NO worktree dir under .claude/worktrees"; ok=0
fi
if [ -s "$PROJ/git-calls.log" ]; then
  fail_msg "case 4 expected no git call, got:"
  sed 's/^/    /' "$PROJ/git-calls.log"; ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 4 rejects invalid suffix before any git call"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
