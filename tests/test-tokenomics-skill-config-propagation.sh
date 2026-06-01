#!/bin/bash
set -uo pipefail
# Regression guard for issue #790.
#
# pipeline.config assigns PIPELINE_* without `export`, so `source pipeline.config`
# sets them in the tokenomics skill's shell but NOT in any child `bash` it forks.
# The tokenomics SKILL.md Step 1 (capture-agent-costs.sh) and Step 2
# (cost-latency-report.sh) invocation blocks MUST inline-wrap the gate vars
# (PIPELINE_REPO / PIPELINE_LOGS_ENABLED / CLAUDE_PROJECT_DIR), mirroring the
# run skill's `PIPELINE_REPO="$PIPELINE_REPO" bash $CLAUDE_PLUGIN_ROOT/scripts/...`
# convention (see tests/test-skill-helper-env-export.sh). capture-agent-costs.sh
# must also emit a distinct stdout skip-marker so the skill can distinguish an
# intentional opt-out from a propagation failure.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/tokenomics/SKILL.md"
CAPTURE="$ROOT/scripts/capture-agent-costs.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

[ -f "$SKILL" ]   || { echo "ERROR: $SKILL not found" >&2; exit 1; }
[ -f "$CAPTURE" ] || { echo "ERROR: $CAPTURE not found" >&2; exit 1; }

# --- Static scan: each script invocation in SKILL.md carries the wrap prefix ---
HELPERS=(capture-agent-costs.sh cost-latency-report.sh)
REQUIRED_VARS=(PIPELINE_REPO= PIPELINE_LOGS_ENABLED= CLAUDE_PROJECT_DIR=)

scan_lines() {
  local helper="$1"
  local pat='bash [^|]*\$\{?CLAUDE_PLUGIN_ROOT[^}]*\}?/scripts/'"$helper"
  grep -nE "$pat" "$SKILL" 2>/dev/null || true
}

for HELPER in "${HELPERS[@]}"; do
  found_any=0
  while IFS= read -r match; do
    [ -z "$match" ] && continue
    found_any=1
    lineno="${match%%:*}"
    content="${match#*:}"
    prefix="${content%%bash *}"
    for V in "${REQUIRED_VARS[@]}"; do
      inc
      if printf '%s' "$prefix" | grep -qF "$V"; then
        pass_msg "$HELPER:$lineno prefix carries $V"
      else
        fail_msg "$HELPER:$lineno invokes without $V prefix"
        echo "    line: $content"
      fi
    done
  done < <(scan_lines "$HELPER")
  inc
  if [ "$found_any" -eq 1 ]; then
    pass_msg "$HELPER: found at least one wrapped invocation in SKILL.md"
  else
    fail_msg "$HELPER: no wrapped \`bash \$CLAUDE_PLUGIN_ROOT/scripts/$HELPER\` invocation found in SKILL.md"
  fi
done

# --- The skill must document detection of the skip-marker ---
inc
if grep -qF 'SKIP_LOGGING_DISABLED' "$SKILL"; then
  pass_msg "SKILL.md references the SKIP_LOGGING_DISABLED marker"
else
  fail_msg "SKILL.md does not reference the SKIP_LOGGING_DISABLED skip-marker"
fi

# --- capture-agent-costs.sh emits the distinct stdout skip-marker on gate-skip ---
inc
OUT="$(env PIPELINE_LOGS_ENABLED=false bash "$CAPTURE" 2>/dev/null)"
if printf '%s' "$OUT" | grep -qF 'SKIP_LOGGING_DISABLED'; then
  pass_msg "capture-agent-costs.sh prints SKIP_LOGGING_DISABLED to stdout when gated off"
else
  fail_msg "capture-agent-costs.sh did not print SKIP_LOGGING_DISABLED to stdout when gated off"
  echo "    stdout: $OUT"
fi

# --- Gate-skip still exits 0 (behavior contract unchanged) ---
inc
env PIPELINE_LOGS_ENABLED=false bash "$CAPTURE" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "capture-agent-costs.sh still exits 0 on gate-skip"
else
  fail_msg "capture-agent-costs.sh exited $rc on gate-skip (expected 0)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
