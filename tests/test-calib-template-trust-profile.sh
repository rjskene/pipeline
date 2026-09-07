#!/bin/bash
set -uo pipefail

# Guard (issue #1291): the calibration sandbox template config must carry the
# trust profile under test into the sandbox session.
#
# scripts/calibration-run.sh --profile EXPORTS PIPELINE_TRUST_PROFILE into the
# headless launch env. dev/calib/template/pipeline.config is copied verbatim into
# the sandbox repo and sourced there, so it must honour an inherited value and
# fall back to `strict` when the launch env carries none.
#
# PIPELINE_CALIB_PROFILE is the DRIVER-side seam (read on the host by
# calibration-run.sh); it must not leak into the sandbox-side template.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/dev/calib/template/pipeline.config"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$T" ]; then
  echo "ERROR: $T not found" >&2
  exit 1
fi

# --- (1) nothing in the env: the template supplies the strict default ------
inc
got=$(env -u PIPELINE_TRUST_PROFILE bash -c "source '$T'; printf '%s' \"\${PIPELINE_TRUST_PROFILE:-}\"")
if [ "$got" = "strict" ]; then
  pass_msg "unset PIPELINE_TRUST_PROFILE resolves to 'strict'"
else
  fail_msg "unset PIPELINE_TRUST_PROFILE resolves to '$got' (want 'strict')"
fi

# --- (2) value in the env: the template passes it through unchanged --------
inc
got=$(PIPELINE_TRUST_PROFILE=lean bash -c "source '$T'; printf '%s' \"\$PIPELINE_TRUST_PROFILE\"")
if [ "$got" = "lean" ]; then
  pass_msg "PIPELINE_TRUST_PROFILE=lean survives sourcing the template"
else
  fail_msg "PIPELINE_TRUST_PROFILE=lean resolves to '$got' (want 'lean')"
fi

# --- (3) the assignment is inside the set -a / set +a export block ---------
inc
if [ -n "$(awk '/^set -a/{a=1} /^set \+a/{a=0} a && /^PIPELINE_TRUST_PROFILE=/' "$T")" ]; then
  pass_msg "PIPELINE_TRUST_PROFILE is assigned inside the set -a/set +a export block"
else
  fail_msg "PIPELINE_TRUST_PROFILE is not assigned inside the set -a/set +a export block"
fi

# --- (4) the driver-side seam name stays out of the sandbox template -------
inc
n=$(grep -c PIPELINE_CALIB_PROFILE "$T" || true)
if [ "$n" = "0" ]; then
  pass_msg "template carries no PIPELINE_CALIB_PROFILE reference"
else
  fail_msg "template references PIPELINE_CALIB_PROFILE on $n line(s) (want 0)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
