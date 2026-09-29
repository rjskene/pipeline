#!/bin/bash
set -euo pipefail

# Regression for issue #1185: BSD/macOS mktemp treats templates with
# XXXXXX before a suffix (e.g. /tmp/foo-XXXXXX.json) as a literal path.
# spawn-claude.sh must use a trailing-XXXXXX template (mktemp -d) and
# place named files inside that directory.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi

# -------------------------------------------------------------------------
# Test A: static guard — no XXXXXX.<suffix> mktemp templates remain.
# -------------------------------------------------------------------------
echo "Test A: no mktemp template places XXXXXX before a file suffix"
inc
if grep -nE 'mktemp[^|#]*XXXXXX\.[A-Za-z0-9]+' "$SCRIPT_UNDER_TEST"; then
  fail_msg "A: spawn-claude.sh still has XXXXXX-before-suffix mktemp template(s)"
else
  pass_msg "A: no XXXXXX-before-suffix mktemp templates"
fi

inc
if grep -qE 'mktemp -d /tmp/claude-spawn-XXXXXX' "$SCRIPT_UNDER_TEST"; then
  pass_msg "A: uses portable mktemp -d /tmp/claude-spawn-XXXXXX"
else
  fail_msg "A: missing portable mktemp -d spawn temp dir"
fi

# -------------------------------------------------------------------------
# Test B: live BSD/GNU mktemp — concurrent calls with trailing XXXXXX succeed
# and return distinct randomized paths (control for the platform contract).
# -------------------------------------------------------------------------
echo "Test B: trailing-XXXXXX mktemp -d is unique under concurrency"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

B1="$WORKDIR/b1"
B2="$WORKDIR/b2"
( mktemp -d "$WORKDIR/spawn-XXXXXX" >"$B1" ) &
( mktemp -d "$WORKDIR/spawn-XXXXXX" >"$B2" ) &
wait || true
P1=$(cat "$B1" 2>/dev/null || true)
P2=$(cat "$B2" 2>/dev/null || true)

inc
if [ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" != "$P2" ] \
  && [ -d "$P1" ] && [ -d "$P2" ] \
  && [[ "$P1" != *XXXXXX* ]] && [[ "$P2" != *XXXXXX* ]]; then
  pass_msg "B: concurrent mktemp -d yields two distinct randomized dirs"
else
  fail_msg "B: concurrent mktemp -d failed (p1='$P1' p2='$P2')"
fi

# Contrast: the old shape fails on BSD (and is unsafe everywhere).
echo "Test B2: old XXXXXX.json shape is non-unique / fails on second call"
OLD1="$WORKDIR/old1"
OLD2="$WORKDIR/old2"
rm -f "$WORKDIR/oldpat-XXXXXX.json"
set +e
( mktemp "$WORKDIR/oldpat-XXXXXX.json" >"$OLD1" 2>/dev/null )
RC1=$?
( mktemp "$WORKDIR/oldpat-XXXXXX.json" >"$OLD2" 2>/dev/null )
RC2=$?
set -e
O1=$(cat "$OLD1" 2>/dev/null || true)
O2=$(cat "$OLD2" 2>/dev/null || true)

inc
# On BSD: first succeeds with literal path, second fails. On GNU: both may
# succeed with randomized names (GNU accepts the mid-template X's). Either
# way, document that spawn-claude must not use this shape — the static
# guard above is the enforceable contract. This probe only asserts the
# BSD failure mode when we are on a BSD mktemp (Darwin).
if [ "$(uname -s)" = "Darwin" ]; then
  if [ "$RC1" -eq 0 ] && [[ "$O1" == *XXXXXX* ]] && [ "$RC2" -ne 0 ]; then
    pass_msg "B2: Darwin reproduces literal-path / second-call failure"
  else
    fail_msg "B2: Darwin did not reproduce expected BSD mktemp failure (rc1=$RC1 o1='$O1' rc2=$RC2 o2='$O2')"
  fi
else
  pass_msg "B2: skipped Darwin-only BSD repro on $(uname -s)"
fi

# -------------------------------------------------------------------------
# Test C: dry-run spawn produces randomized EMPTY_MCP_FILE under SPAWN_TMPDIR
# -------------------------------------------------------------------------
echo "Test C: dry-run EMPTY_MCP_FILE is randomized and has .json suffix"

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude/scripts" "$PROJ/worktree"
cp "$SCRIPT_UNDER_TEST" "$PROJ/.claude/scripts/spawn-claude.sh"
chmod +x "$PROJ/.claude/scripts/spawn-claude.sh"

cat > "$PROJ/pipeline.config" <<'CFG'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="pipeline"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
CFG

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'GH'
#!/bin/bash
exit 0
GH
chmod +x "$STUB_DIR/gh"

RUNS_LOG="$WORKDIR/runs.log"

run_dryrun() {
  local outf="$1"
  cd "$PROJ"
  PATH="$STUB_DIR:$PATH" \
    PIPELINE_SPAWN_DRY_RUN=1 \
    PIPELINE_LOGS_ENABLED=true \
    PIPELINE_RUNS_LOG_OVERRIDE="$RUNS_LOG" \
    bash .claude/scripts/spawn-claude.sh "$PROJ/worktree" 1185 slug tmux >"$outf" 2>/dev/null || true
  cd - >/dev/null
}

OUT1="$WORKDIR/out1"
OUT2="$WORKDIR/out2"
run_dryrun "$OUT1" &
run_dryrun "$OUT2" &
wait || true

MCP1=$(sed -n 's/^EMPTY_MCP_FILE=//p' "$OUT1" | head -1)
MCP2=$(sed -n 's/^EMPTY_MCP_FILE=//p' "$OUT2" | head -1)

inc
if [ -n "$MCP1" ] && [ -n "$MCP2" ] && [ "$MCP1" != "$MCP2" ] \
  && [[ "$MCP1" == *.json ]] && [[ "$MCP2" == *.json ]] \
  && [[ "$MCP1" != *XXXXXX* ]] && [[ "$MCP2" != *XXXXXX* ]] \
  && [[ "$MCP1" == */claude-spawn-*/mcp-empty.json ]] \
  && [[ "$MCP2" == */claude-spawn-*/mcp-empty.json ]]; then
  pass_msg "C: concurrent dry-runs yield distinct randomized mcp-empty.json paths"
else
  fail_msg "C: dry-run EMPTY_MCP_FILE not portable (mcp1='$MCP1' mcp2='$MCP2')"
  echo "---- out1 ----"; sed -n '1,40p' "$OUT1" | sed 's/^/    /'
  echo "---- out2 ----"; sed -n '1,40p' "$OUT2" | sed 's/^/    /'
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
