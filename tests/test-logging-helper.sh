#!/bin/bash
set -uo pipefail

# Tests for scripts/_logging.sh — sourceable helper exposing
# pipeline_logging_enabled, which gates dogfood-only observability writes on
# the lowercase string "true" in PIPELINE_LOGS_ENABLED.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/_logging.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
  fail_msg "helper exists at scripts/_logging.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# (a) Sourcing twice succeeds and is idempotent (no errors, guard variable set).
# shellcheck source=/dev/null
. "$HELPER"
# shellcheck source=/dev/null
. "$HELPER"
if [ "${_PIPELINE_LOGGING_SH_SOURCED:-}" = "1" ]; then
  pass_msg "double-source succeeds with guard set"
else
  fail_msg "double-source leaves guard set (_PIPELINE_LOGGING_SH_SOURCED=${_PIPELINE_LOGGING_SH_SOURCED:-})"
fi

# (b) Unset → non-zero.
unset PIPELINE_LOGS_ENABLED
if pipeline_logging_enabled; then
  fail_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED unset"
else
  pass_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED unset"
fi

# (c) false → non-zero.
PIPELINE_LOGS_ENABLED=false
if pipeline_logging_enabled; then
  fail_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED=false"
else
  pass_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED=false"
fi

# (d) true → rc=0.
PIPELINE_LOGS_ENABLED=true
if pipeline_logging_enabled; then
  pass_msg "pipeline_logging_enabled rc=0 when PIPELINE_LOGS_ENABLED=true"
else
  fail_msg "pipeline_logging_enabled rc=0 when PIPELINE_LOGS_ENABLED=true"
fi

# (e) TRUE (uppercase) → non-zero. Strict lowercase only.
PIPELINE_LOGS_ENABLED=TRUE
if pipeline_logging_enabled; then
  fail_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED=TRUE (strict lowercase)"
else
  pass_msg "pipeline_logging_enabled rc!=0 when PIPELINE_LOGS_ENABLED=TRUE (strict lowercase)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
