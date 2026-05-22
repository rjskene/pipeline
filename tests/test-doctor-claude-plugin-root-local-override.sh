#!/bin/bash
set -uo pipefail

# Coverage for #294: doctor's claude_plugin_root check must surface the
# PIPELINE_USE_LOCAL_PLUGIN local-override as its own pass state
# (`pass detail=local-override at <repo>`) and must NOT emit a stale-resolution
# warn line in that case — the override's basename is not a semver, so the
# usual `basename(CLAUDE_PLUGIN_ROOT) != basename(highest-cache)` downgrade
# would otherwise misfire.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Hermetic cache with a couple of versions so the stale-resolution block has
# something to compute as the "expected highest semver" had the short-circuit
# been missing.
HHOME="$TMP/home"
CACHE="$HHOME/.claude/plugins/cache/claude-pipeline/pipeline"
mkdir -p "$CACHE/0.7.2" "$CACHE/0.8.0-rc.5"

# Hermetic fake repo: matching origin + sentinel manifest, so the resolver's
# local-override branch fires. Suppress global git config so signing/hooks
# can't stall the test.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.claude-plugin"
printf '{}' > "$FAKE_REPO/.claude-plugin/plugin.json"
GIT_CONFIG_GLOBAL=/dev/null git -C "$FAKE_REPO" init -q
GIT_CONFIG_GLOBAL=/dev/null git -C "$FAKE_REPO" remote add origin "https://github.com/rjskene/pipeline.git"

# Doctor's other checks may exit non-zero in this hermetic harness (missing
# gh auth, missing labels, etc.) — we only care about the claude_plugin_root
# CHECK line(s).
OUT=$(
  cd "$FAKE_REPO"
  HOME="$HHOME" \
  PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_BASE_BRANCH=staging \
    bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
)

CPR_LINES=$(echo "$OUT" | grep -E '^CHECK: claude_plugin_root ')

EXPECTED_DETAIL="local-override at $FAKE_REPO"
LINE=$(echo "$CPR_LINES" | tail -n 1)
case "$LINE" in
  *"status=pass"*"$EXPECTED_DETAIL"*)
    pass_msg "doctor emits pass with local-override detail naming the repo toplevel"
    ;;
  *)
    fail_msg "expected pass + 'local-override at $FAKE_REPO'; got: $LINE"
    ;;
esac

if echo "$CPR_LINES" | grep -q "status=warn"; then
  fail_msg "stale-resolution warn line must NOT appear under local-override; got: $(echo "$CPR_LINES" | grep status=warn)"
else
  pass_msg "no stale-resolution warn line emitted under local-override"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
