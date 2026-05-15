#!/bin/bash
set -uo pipefail
#
# Tests for scripts/find-grouping-candidates.sh — the helper that scores
# proposed issue titles against the open-issues list and recommends one of
# TRACKER #N / GROUP #A,#B / STANDALONE per input. See Issue #62.
#
# The gh CLI is replaced by a PATH-resident shim that responds to
# `gh issue list ... --json number,title,body,labels` with canned JSON
# fixtures specified via $ISSUES_JSON.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/find-grouping-candidates.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — supports `gh issue list ... --json ...` only.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  printf '%s' "${ISSUES_JSON:-[]}"
  exit 0
fi
echo "shim: unsupported gh invocation: $*" >&2
exit 99
GH
chmod +x "$TMP/bin/gh"

# Minimal pipeline.config so the helper can source it.
cat > "$TMP/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/test-repo"
CFG

export PATH="$TMP/bin:$PATH"

# --- Scenario 1: tracker hit ---
inc_scenario() { echo ""; echo "-- $1 --"; }

inc_scenario "Scenario 1: tracker scope match"
export ISSUES_JSON='[
  {"number":100,"title":"epic(harness-isolation): top-level rollup","body":"## Rollout sequence\n- [ ] foo","labels":[{"name":"tracker"}]},
  {"number":99,"title":"feat(other): unrelated","body":"","labels":[]}
]'
out1=$(cd "$TMP" && bash "$HELPER" --title "feat(harness-isolation): bar" 2>&1)
rc1=$?
echo "$out1" | sed 's/^/    /'
if [ "$rc1" -eq 0 ] && echo "$out1" | grep -qE '^INPUT="feat\(harness-isolation\): bar" REC=TRACKER #100 REASON='; then
  pass_msg "tracker hit emits TRACKER #100"
else
  fail_msg "tracker hit emits TRACKER #100 (rc=$rc1)"
fi

# --- Scenario 2: standalone cluster ---
inc_scenario "Scenario 2: standalone cluster"
export ISSUES_JSON='[
  {"number":10,"title":"feat(foo): first","body":"","labels":[]},
  {"number":11,"title":"fix(foo): second","body":"","labels":[]},
  {"number":12,"title":"feat(other): unrelated","body":"","labels":[]}
]'
out2=$(cd "$TMP" && bash "$HELPER" --title "feat(foo): baz" 2>&1)
rc2=$?
echo "$out2" | sed 's/^/    /'
if [ "$rc2" -eq 0 ] && echo "$out2" | grep -qE '^INPUT="feat\(foo\): baz" REC=GROUP #10,#11 REASON='; then
  pass_msg "standalone cluster emits GROUP #10,#11"
else
  fail_msg "standalone cluster emits GROUP #10,#11 (rc=$rc2)"
fi

# --- Scenario 3: no candidate ---
inc_scenario "Scenario 3: no candidate"
export ISSUES_JSON='[
  {"number":1,"title":"feat(alpha): something","body":"","labels":[]},
  {"number":2,"title":"fix(beta): another","body":"","labels":[]}
]'
out3=$(cd "$TMP" && bash "$HELPER" --title "feat(gamma): lonely" 2>&1)
rc3=$?
echo "$out3" | sed 's/^/    /'
if [ "$rc3" -eq 0 ] && echo "$out3" | grep -qE '^INPUT="feat\(gamma\): lonely" REC=STANDALONE REASON='; then
  pass_msg "no-candidate emits STANDALONE"
else
  fail_msg "no-candidate emits STANDALONE (rc=$rc3)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
