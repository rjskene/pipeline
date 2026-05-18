# shellcheck shell=bash
# Shared harness for auto-merge-gate.sh unit tests.
#
# Sources scripts/auto-merge-gate.sh from the repo root and ensures
# MANUAL_MERGE starts unset so test fixtures own the env entirely.
#
# Callers must export PIPELINE_REPO and PIPELINE_BASE_BRANCH and stage a
# PATH-shadowed gh shim before sourcing this harness.

_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HARNESS_ROOT="$(cd "${_HARNESS_DIR}/../.." && pwd)"

unset MANUAL_MERGE

# shellcheck disable=SC1091
source "${_HARNESS_ROOT}/scripts/auto-merge-gate.sh"
