#!/bin/bash
set -uo pipefail

# Tests that scripts/cleanup-worktree.sh gates the per-issue tool-use log copy
# on PIPELINE_LOGS_ENABLED. Stubs git/gh on PATH so the script can run end-to-end
# inside a tmpdir without touching the real repo.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/cleanup-worktree.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

setup_env() {
  local proj="$1" issue="$2"
  rm -rf "$proj"
  mkdir -p "$proj/.claude/logs"
  cat > "$proj/pipeline.config" <<'EOF'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
EOF

  # Fake worktree dir with a populated tool-use.log.
  local wt="$proj/wt-${issue}-foo"
  mkdir -p "$wt/.claude/logs"
  printf '2026-01-01\tBash\tabc\tls\n' > "$wt/.claude/logs/tool-use.log"

  # Stub git + gh on PATH.
  local stub_dir="$proj/stub"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/git" <<EOF
#!/bin/bash
# Args may include -C <dir>; consume them.
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
# pr list ... --json state -> CLOSED
# pr list ... --json number -> 999
# issue view -> CLOSED (so cleanup skips closing)
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
  local proj="$1" issue="$2" stub_dir="$3" logs_flag="$4"
  (
    cd "$proj"
    PATH="$stub_dir:$PATH" \
      PIPELINE_PROJECT_ROOT="$proj" \
      PIPELINE_LOGS_ENABLED="$logs_flag" \
      bash "$SCRIPT_UNDER_TEST" "$issue" --force 2>&1
  )
}

# ---- Test 1: PIPELINE_LOGS_ENABLED=false -> no per-issue log copy ----
echo "Test 1: logs disabled -> tool-use-issue-<N>.log NOT created; stdout mentions skip"
inc
PROJ="$WORKDIR/p1"
STUB=$(setup_env "$PROJ" 42)
OUT=$(run_cleanup "$PROJ" 42 "$STUB" "false")
ok=1
if [ -f "$PROJ/.claude/logs/tool-use-issue-42.log" ]; then
  fail_msg "tool-use-issue-42.log should NOT exist when PIPELINE_LOGS_ENABLED=false"
  ok=0
fi
if ! echo "$OUT" | grep -q "Skipping tool-use log copy"; then
  fail_msg "stdout missing 'Skipping tool-use log copy' message"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "no copy; skip message printed"

# ---- Test 2: PIPELINE_LOGS_ENABLED=true -> per-issue log copy created ----
echo "Test 2: logs enabled -> tool-use-issue-<N>.log IS created"
inc
PROJ="$WORKDIR/p2"
STUB=$(setup_env "$PROJ" 43)
OUT=$(run_cleanup "$PROJ" 43 "$STUB" "true")
ok=1
if [ ! -f "$PROJ/.claude/logs/tool-use-issue-43.log" ]; then
  fail_msg "tool-use-issue-43.log SHOULD exist when PIPELINE_LOGS_ENABLED=true"
  echo "$OUT" | sed 's/^/    /'
  ok=0
fi
[ "$ok" = "1" ] && pass_msg "per-issue log copied"

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
