#!/bin/bash
set -uo pipefail

# Regression guard for #858: the CI-gating toggles
# PIPELINE_CI_CHECK_ENABLED / PIPELINE_CI_FIX_LOOP_ENABLED must default ON
# (true) when UNSET — matching what pipeline.config.example documents and
# scripts/init.sh generates — WITHOUT breaking the explicit-`=""`⇒OFF no-CI
# contract that scripts/init.sh relies on.
#
# The read site at skills/fullsend/SKILL.md (the 6b gate) MUST use the
# colon-LESS bash fallback `${VAR-true}`, NOT the colon form `${VAR:-true}`:
#   - `${VAR-true}` substitutes the default ONLY when VAR is unset.
#   - `${VAR:-true}` substitutes when VAR is unset OR empty — which would
#     silently flip a no-CI consumer (who sets VAR="") back ON.
#
# Semantics matrix the colon-less form guarantees at the gate:
#   UNSET   ⇒ true  (ON,  matches .example default)
#   =""     ⇒ ""    (OFF, preserves no-CI consumers)
#   ="true" ⇒ true  (ON)
#   ="false"⇒ false (OFF)
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI). Modeled on
# tests/test-pipeline-config-mock-web-eval-paths.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXAMPLE" ]; then
  echo "ERROR: $EXAMPLE not found" >&2
  exit 1
fi
if [ ! -f "$FULLSEND" ]; then
  echo "ERROR: $FULLSEND not found" >&2
  exit 1
fi

# --- Assertion 1: .example documents both toggles as "true" ---
inc
if grep -Eq '^PIPELINE_CI_CHECK_ENABLED="true"' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_CI_CHECK_ENABLED declared \"true\""
else
  fail_msg "example: PIPELINE_CI_CHECK_ENABLED not declared \"true\""
fi
inc
# #1052 (defaults-in-code): PIPELINE_CI_FIX_LOOP_ENABLED is now COMMENTED in the example
# (documentation default; the colon-less ${VAR-true} read site below owns the default),
# so `--fix config` does NOT seed it. Assert it is documented as a commented "true" knob
# rather than a live line.
if grep -Eq '^[[:space:]]*#[[:space:]]*PIPELINE_CI_FIX_LOOP_ENABLED="true"' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_CI_FIX_LOOP_ENABLED documented (commented) \"true\" per #1052"
else
  fail_msg "example: PIPELINE_CI_FIX_LOOP_ENABLED not documented as commented \"true\" (#1052)"
fi

# --- Assertion 2: read site pins the colon-LESS `${VAR-true}` form ---
# grep -F so the colon is significant (a regex `:-` could be mis-escaped).
inc
if grep -Fq '${PIPELINE_CI_FIX_LOOP_ENABLED-true}' "$FULLSEND"; then
  pass_msg "fullsend: PIPELINE_CI_FIX_LOOP_ENABLED uses colon-less \${VAR-true}"
else
  fail_msg "fullsend: PIPELINE_CI_FIX_LOOP_ENABLED missing colon-less \${VAR-true} at read site"
fi
inc
if grep -Fq '${PIPELINE_CI_CHECK_ENABLED-true}' "$FULLSEND"; then
  pass_msg "fullsend: PIPELINE_CI_CHECK_ENABLED uses colon-less \${VAR-true}"
else
  fail_msg "fullsend: PIPELINE_CI_CHECK_ENABLED missing colon-less \${VAR-true} at read site"
fi

# --- Assertion 3: forbid ANY `:-` colon-form drift on both vars ---
# under skills/ scripts/ hooks/ — forbids the OLD `:-false` AND the
# wrong-fix `:-true`, allowing only the colon-less `-true`.
for var in PIPELINE_CI_CHECK_ENABLED PIPELINE_CI_FIX_LOOP_ENABLED; do
  inc
  hits=$(grep -rIF "\${${var}:-" "$ROOT/skills" "$ROOT/scripts" "$ROOT/hooks" 2>/dev/null || true)
  if [ -z "$hits" ]; then
    pass_msg "drift: no colon-form \${${var}:- under skills/ scripts/ hooks/"
  else
    fail_msg "drift: colon-form \${${var}:- found under skills/ scripts/ hooks/:"
    echo "$hits" | sed 's/^/    /'
  fi
done

# --- Assertion 4: positive runtime invariant — exercise the gate logic ---
# `=""` ⇒ gate OFF; unset ⇒ gate ON. Run in clean subshells so the test's
# own env can't leak.
inc
if bash -c 'PIPELINE_CI_FIX_LOOP_ENABLED="" PIPELINE_CI_CHECK_ENABLED="" ; [ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]'; then
  fail_msg "semantics: explicit =\"\" should yield gate OFF but evaluated ON"
else
  pass_msg "semantics: explicit =\"\" yields gate OFF (no-CI consumer preserved)"
fi
inc
if bash -c 'unset PIPELINE_CI_FIX_LOOP_ENABLED PIPELINE_CI_CHECK_ENABLED ; [ "${PIPELINE_CI_FIX_LOOP_ENABLED-true}" = "true" ] && [ "${PIPELINE_CI_CHECK_ENABLED-true}" = "true" ]'; then
  pass_msg "semantics: unset yields gate ON (matches .example default)"
else
  fail_msg "semantics: unset should yield gate ON but evaluated OFF"
fi

# --- Assertion 5: live pipeline.config dual-scan (fail-soft) ---
# Belt-and-suspenders: the live config only sets values, not fallbacks, so it
# should never contain a colon-form `${VAR:-` either. Do NOT forbid `=""` —
# that is the legitimate no-CI marker and is correctly OFF under colon-less.
if [ -f "$LIVE" ]; then
  for var in PIPELINE_CI_CHECK_ENABLED PIPELINE_CI_FIX_LOOP_ENABLED; do
    inc
    if grep -Fq "\${${var}:-" "$LIVE"; then
      fail_msg "live: colon-form \${${var}:- found in pipeline.config"
    else
      pass_msg "live: no colon-form \${${var}:- in pipeline.config"
    fi
  done
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
