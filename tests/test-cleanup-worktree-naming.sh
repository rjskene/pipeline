#!/bin/bash
set -uo pipefail

# Tests that scripts/cleanup-worktree.sh discovers the worktree by basename for
# BOTH shapes the pipeline produces in the wild:
#   - bare:     wt-<N>            (current setup-worktree.sh output when no slug given)
#   - slugged:  wt-<N>-<slug>     (orchestrator-supplied slug)
# Also verifies that the discovery does NOT widen to a substring match that
# would mis-collide adjacent issue numbers (issue 42 must not match wt-99-other).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/cleanup-worktree.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Build a project skeleton, a worktree dir at $wt_basename, and PATH-stubbed
# git/gh binaries. The stub `git worktree list` always points at a single
# worktree path: $proj/$wt_basename. Returns the stub dir path on stdout.
setup_env() {
  local proj="$1" wt_basename="$2"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
EOF

  local wt="$proj/$wt_basename"
  mkdir -p "$wt/.claude/logs"

  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/git" <<EOF
#!/bin/bash
if [ "\$1" = "-C" ]; then shift 2; fi
case "\$1" in
  worktree)
    case "\$2" in
      list) echo "$wt  abc123 [feature/foo]"; exit 0 ;;
      remove|prune) exit 0 ;;
    esac ;;
  rev-parse) echo "feature/foo"; exit 0 ;;
  push|branch) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$stub_dir/git"
  cat > "$stub_dir/gh" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    state) echo "CLOSED"; exit 0 ;;
    number) echo "999"; exit 0 ;;
    .state) echo "CLOSED"; exit 0 ;;
  esac
done
echo ""
exit 0
EOF
  chmod +x "$stub_dir/gh"
  echo "$stub_dir"
}

run_cleanup() {
  local proj="$1" issue="$2" stub_dir="$3"
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      PIPELINE_PROJECT_ROOT="$proj" \
      PIPELINE_LOGS_ENABLED="false" \
      bash "$SCRIPT_UNDER_TEST" "$issue" --force 2>&1
  )
  echo "EXIT=$?"
}

# ---- Case 1: bare basename (wt-42) discovered ----
echo "Case 1: bare basename wt-42 must be discovered for issue 42"
inc
PROJ="$WORKDIR/p1"
STUB=$(setup_env "$PROJ" "wt-42")
OUT=$(run_cleanup "$PROJ" 42 "$STUB")
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if ! echo "$OUT" | grep -q "Worktree: $PROJ/wt-42"; then
  fail_msg "case 1 (no-slug) expected stdout to contain 'Worktree: $PROJ/wt-42'"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$exit_line" != "EXIT=0" ]; then
  fail_msg "case 1 (no-slug) expected exit 0, got $exit_line"
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 1 (no-slug) discovers wt-42"

# ---- Case 2: slugged basename (wt-42-feature-foo) discovered ----
echo "Case 2: slugged basename wt-42-feature-foo must be discovered for issue 42"
inc
PROJ="$WORKDIR/p2"
STUB=$(setup_env "$PROJ" "wt-42-feature-foo")
OUT=$(run_cleanup "$PROJ" 42 "$STUB")
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if ! echo "$OUT" | grep -q "Worktree: $PROJ/wt-42-feature-foo"; then
  fail_msg "case 2 (with-slug) expected stdout to contain 'Worktree: $PROJ/wt-42-feature-foo'"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$exit_line" != "EXIT=0" ]; then
  fail_msg "case 2 (with-slug) expected exit 0, got $exit_line"
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 2 (with-slug) discovers wt-42-feature-foo"

# ---- Case 3: negative — wt-99-other must NOT match issue 42 ----
echo "Case 3: wt-99-other must NOT be matched when looking up issue 42"
inc
PROJ="$WORKDIR/p3"
STUB=$(setup_env "$PROJ" "wt-99-other")
OUT=$(run_cleanup "$PROJ" 42 "$STUB")
exit_line=$(echo "$OUT" | tail -n1)
ok=1
if ! echo "$OUT" | grep -q "No worktree found for issue #42"; then
  fail_msg "case 3 (negative) expected stdout to contain 'No worktree found for issue #42'"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
if [ "$exit_line" != "EXIT=1" ]; then
  fail_msg "case 3 (negative) expected exit 1, got $exit_line"
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "case 3 (negative) refuses to match wt-99-other for issue #42"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
