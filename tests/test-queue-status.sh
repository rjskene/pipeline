#!/usr/bin/env bash
# Smoke tests for scripts/queue-status.sh project-root resolution.
# Mirrors the test shape of tests/test-review-logs.sh (PR #289).
set -uo pipefail

export PIPELINE_LOGS_ENABLED=true

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/queue-status.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
_fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; echo "    -- output --"; echo "$2" | sed 's/^/    /'; }

_seed_consumer() {
  # Args: $1=dir. Seeds a consumer root with pipeline.config + .git/
  # and a fake queue log so queue-status renders its summary block.
  local dir="$1"
  mkdir -p "$dir/.claude/logs"
  mkdir -p "$dir/.git"
  cat > "$dir/pipeline.config" <<'EOF'
PIPELINE_REPO="seed/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_TMUX_SESSION="dev"
EOF
  # Empty queue log file is enough to flip the early-exit short-circuit
  # past the "no queue logs" branch.
  : > "$dir/.claude/logs/queue-test.log"
}

# ---- Test 1: walk-up from $0 resolves seeded consumer dir ----
echo "Test 1: walk-up resolves consumer root"
TMP1="$(mktemp -d)"
_seed_consumer "$TMP1"
mkdir -p "$TMP1/fake-plugin/scripts"
cp "$SCRIPT" "$TMP1/fake-plugin/scripts/queue-status.sh"
chmod +x "$TMP1/fake-plugin/scripts/queue-status.sh"
OUT1=$(env -u PIPELINE_PROJECT_ROOT bash "$TMP1/fake-plugin/scripts/queue-status.sh" 2>&1 || true)
if echo "$OUT1" | grep -q "PIPELINE STATUS"; then
  _pass "Test 1: walk-up rendered status header"
else
  _fail "Test 1: status header missing — likely sourced wrong pipeline.config" "$OUT1"
fi
rm -rf "$TMP1"

# ---- Test 2: PIPELINE_PROJECT_ROOT override wins ----
echo "Test 2: PIPELINE_PROJECT_ROOT override"
TMP2="$(mktemp -d)"
_seed_consumer "$TMP2"
OUT2=$(PIPELINE_PROJECT_ROOT="$TMP2" bash "$SCRIPT" 2>&1 || true)
if echo "$OUT2" | grep -q "PIPELINE STATUS"; then
  _pass "Test 2: override rendered status header"
else
  _fail "Test 2: override path missed seeded pipeline.config" "$OUT2"
fi
rm -rf "$TMP2"

# ---- Test 3: stray pipeline.config without .git/ is rejected ----
echo "Test 3: stray pipeline.config without .git is rejected"
TMP3="$(mktemp -d)"
# Outer dir has pipeline.config but NO .git/ — the plugin-tree shape that
# caused #292. Inner dir is the real consumer.
touch "$TMP3/pipeline.config"
mkdir -p "$TMP3/inner/.git"
mkdir -p "$TMP3/inner/.claude/logs"
cat > "$TMP3/inner/pipeline.config" <<'EOF'
PIPELINE_REPO="inner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_TMUX_SESSION="dev"
EOF
: > "$TMP3/inner/.claude/logs/queue-test.log"
mkdir -p "$TMP3/inner/fake-plugin/scripts"
cp "$SCRIPT" "$TMP3/inner/fake-plugin/scripts/queue-status.sh"
chmod +x "$TMP3/inner/fake-plugin/scripts/queue-status.sh"
OUT3=$(env -u PIPELINE_PROJECT_ROOT bash "$TMP3/inner/fake-plugin/scripts/queue-status.sh" 2>&1 || true)
# Walk-up must stop at "inner" (which has both), not at the outer stray.
# If it stops at the outer stray, sourcing the empty pipeline.config
# leaves PIPELINE_REPO unbound and set -u will trip OR the resolver will
# error out — either way, "PIPELINE STATUS" should not render.
if echo "$OUT3" | grep -q "PIPELINE STATUS" && ! echo "$OUT3" | grep -qi "no such file\|unbound variable"; then
  _pass "Test 3: walk-up stops at directory with both pipeline.config AND .git"
else
  _fail "Test 3: stray pipeline.config was not rejected" "$OUT3"
fi
rm -rf "$TMP3"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
