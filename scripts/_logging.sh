#!/bin/bash
# _logging.sh — sourceable helper.
#
# Purpose: expose a single predicate, pipeline_logging_enabled, that callers
# use to gate dogfood-only observability writes (e.g. .claude/logs/* hooks
# and audit substrate). Centralizing the check keeps the env-var contract in
# one place so every writer agrees on what "logging on" means.
#
# Default behavior: logging is OFF. pipeline_logging_enabled returns rc=0
# only when PIPELINE_LOGS_ENABLED is the exact lowercase string "true".
# Any other value (unset, "false", "TRUE", "1", "yes", ...) returns non-zero.
# Strict lowercase match is intentional - it avoids the matrix of truthy
# spellings drifting between callers.
#
# Idempotent. Sourcing twice is a no-op: the second call short-circuits on
# the _PIPELINE_LOGGING_SH_SOURCED guard and returns 0 without redefining
# the function.

if [ "${_PIPELINE_LOGGING_SH_SOURCED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_PIPELINE_LOGGING_SH_SOURCED=1

pipeline_logging_enabled() {
  [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]
}
