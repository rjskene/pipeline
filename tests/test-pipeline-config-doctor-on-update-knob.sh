#!/usr/bin/env bash
# test-pipeline-config-doctor-on-update-knob.sh — regression guard for the
# PIPELINE_DOCTOR_ON_UPDATE_ENABLED opt-out knob (issue #1038).
#
# Per CLAUDE.md "Configuration conventions", a reconcile/detector bug that only
# reproduces on the live, gitignored host pipeline.config cannot ship a tracked
# fix — so this guard dual-scans:
#   - pipeline.config.example (ALWAYS present, the only tracked surface);
#   - the live pipeline.config (gitignored, host-only) WHEN present (no-op in CI).
#
# Asserts:
#   1. the example documents PIPELINE_DOCTOR_ON_UPDATE_ENABLED (live or
#      commented — both document it to operators);
#   2. the detector hook single-sources the default at the read site via
#      ${PIPELINE_DOCTOR_ON_UPDATE_ENABLED:-true} (opt-out default true);
#   3. the live config (when present) does not assign the knob to a malformed
#      value that would silently disable a non-"false" intent.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO_ROOT/pipeline.config.example"
LIVE="$REPO_ROOT/pipeline.config"
HOOK="$REPO_ROOT/hooks/doctor-on-update.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$EXAMPLE" ]; then
  echo "ERROR: $EXAMPLE not found" >&2
  exit 1
fi

# 1. Example documents the knob (commented or live).
if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_DOCTOR_ON_UPDATE_ENABLED=' "$EXAMPLE"; then
  pass_msg "example documents PIPELINE_DOCTOR_ON_UPDATE_ENABLED"
else
  fail_msg "example missing PIPELINE_DOCTOR_ON_UPDATE_ENABLED"
fi

# 2. Detector single-sources the default at the read site (${VAR:-true}).
if [ -f "$HOOK" ] \
   && grep -Eq '\$\{PIPELINE_DOCTOR_ON_UPDATE_ENABLED:-true\}' "$HOOK"; then
  pass_msg "detector reads \${PIPELINE_DOCTOR_ON_UPDATE_ENABLED:-true}"
else
  fail_msg "detector does NOT single-source the default via \${VAR:-true}"
fi

# 3. Live config (when present) is not broken by the knob shape: if assigned,
#    the value must be a quoted-or-bare token (no trailing junk).
if [ -f "$LIVE" ]; then
  if grep -Eq '^[[:space:]]*PIPELINE_DOCTOR_ON_UPDATE_ENABLED=' "$LIVE"; then
    if grep -Eq '^[[:space:]]*PIPELINE_DOCTOR_ON_UPDATE_ENABLED="?[A-Za-z]+"?[[:space:]]*(#.*)?$' "$LIVE"; then
      pass_msg "live config knob assignment is well-formed"
    else
      fail_msg "live config knob assignment is malformed"
    fi
  else
    pass_msg "live config does not assign the knob (relies on \${VAR:-true} default)"
  fi
fi

echo ""
echo "================================"
echo "  test-pipeline-config-doctor-on-update-knob: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
