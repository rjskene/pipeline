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

EXPECTED_DETAIL="local-override at $FAKE_REPO"

# ---------------------------------------------------------------------------
# Scenario 1 (#294): the knob lives in the ENVIRONMENT. No pipeline.config in
# the fixture yet — this scenario must stay a pure env-knob path.
#
# Doctor's other checks may exit non-zero in this hermetic harness (missing
# gh auth, missing labels, etc.) — we only care about the claude_plugin_root
# CHECK line(s).
# ---------------------------------------------------------------------------
OUT=$(
  cd "$FAKE_REPO"
  HOME="$HHOME" \
  PIPELINE_USE_LOCAL_PLUGIN=true \
  PIPELINE_BASE_BRANCH=staging \
    bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
)

CPR_LINES=$(echo "$OUT" | grep -E '^CHECK: claude_plugin_root ')

LINE=$(echo "$CPR_LINES" | tail -n 1)
case "$LINE" in
  *"status=pass"*"$EXPECTED_DETAIL"*)
    pass_msg "S1 (env knob): doctor emits pass with local-override detail naming the repo toplevel"
    ;;
  *)
    fail_msg "S1 (env knob): expected pass + 'local-override at $FAKE_REPO'; got: $LINE"
    ;;
esac

if echo "$CPR_LINES" | grep -q "status=warn"; then
  fail_msg "S1 (env knob): stale-resolution warn line must NOT appear under local-override; got: $(echo "$CPR_LINES" | grep status=warn)"
else
  pass_msg "S1 (env knob): no stale-resolution warn line emitted under local-override"
fi

# ---------------------------------------------------------------------------
# From here on the knob lives ONLY in the fixture pipeline.config — the shape
# every real dogfood host actually uses.
# ---------------------------------------------------------------------------
cat > "$FAKE_REPO/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_USE_LOCAL_PLUGIN=true
CFG

# ---------------------------------------------------------------------------
# Scenario 2 (#1274 scope 6): the knob is set ONLY in pipeline.config, which
# doctor sources ~60 lines AFTER the resolver runs. The initial resolve must
# still see it, so the check records exactly ONE line — the local-override pass
# — instead of a self-resolved pass PLUS a spurious stale-resolution warn.
# ---------------------------------------------------------------------------
OUT2=$(
  cd "$FAKE_REPO"
  env -u PIPELINE_USE_LOCAL_PLUGIN -u CLAUDE_PLUGIN_ROOT \
    HOME="$HHOME" bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
)
CPR2=$(echo "$OUT2" | grep -E '^CHECK: claude_plugin_root ' || true)
N2=$(printf '%s\n' "$CPR2" | grep -c '^CHECK: claude_plugin_root ' || true)

if [ "$N2" = "1" ]; then
  pass_msg "S2 (config knob): exactly one claude_plugin_root CHECK line"
else
  fail_msg "S2 (config knob): expected exactly 1 claude_plugin_root CHECK line, got $N2:"$'\n'"$CPR2"
fi

case "$CPR2" in
  *"status=pass"*"$EXPECTED_DETAIL"*)
    pass_msg "S2 (config knob): pass with local-override detail naming the repo toplevel"
    ;;
  *)
    fail_msg "S2 (config knob): expected pass + 'local-override at $FAKE_REPO'; got: $CPR2"
    ;;
esac

if echo "$CPR2" | grep -q "status=warn"; then
  fail_msg "S2 (config knob): spurious warn line; got: $(echo "$CPR2" | grep status=warn)"
else
  pass_msg "S2 (config knob): no stale-resolution warn line emitted"
fi

# ---------------------------------------------------------------------------
# Scenario 3 — ENV-PRECEDENCE CONTROL (green today, must stay green).
# The same config knob, but with an explicit CLAUDE_PLUGIN_ROOT in the env.
# _resolve-plugin-root.sh runs its PIPELINE_USE_LOCAL_PLUGIN=true branch BEFORE
# the CLAUDE_PLUGIN_ROOT short-circuit, so any hoist of the config knob into the
# pre-resolve environment MUST be guarded on CLAUDE_PLUGIN_ROOT being empty —
# otherwise a config file silently outranks an explicit env var and doctor's
# `env pre-set` + stale-resolution states become unreachable on every host whose
# config sets the knob.
# ---------------------------------------------------------------------------
OUT3=$(
  cd "$FAKE_REPO"
  env -u PIPELINE_USE_LOCAL_PLUGIN \
    HOME="$HHOME" CLAUDE_PLUGIN_ROOT="$CACHE/0.7.2" \
    bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
)
CPR3=$(echo "$OUT3" | grep -E '^CHECK: claude_plugin_root ' || true)

case "$CPR3" in
  *"status=pass"*"env pre-set to $CACHE/0.7.2"*)
    pass_msg "S3 (env precedence): explicit CLAUDE_PLUGIN_ROOT wins — pass 'env pre-set to $CACHE/0.7.2'"
    ;;
  *)
    fail_msg "S3 (env precedence): expected pass + 'env pre-set to $CACHE/0.7.2'; got: $CPR3"
    ;;
esac

if echo "$CPR3" | grep -Fq "$EXPECTED_DETAIL"; then
  fail_msg "S3 (env precedence): config knob outranked the explicit env var; got: $CPR3"
else
  pass_msg "S3 (env precedence): no local-override line when CLAUDE_PLUGIN_ROOT is pre-set"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
