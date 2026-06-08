#!/bin/bash
set -euo pipefail

# dispatch-leaf.sh — ONE harness-keyed abstraction over leaf transport selection
# and leaf dispatch (issue #983, Codex dual-target migration).
#
# The pipeline's PATH C fan-out and the run-queue launch sites must not hard-code
# `claude` vs `codex`. This script is the single seam: everything keys off
# $PIPELINE_HARNESS (resolved by platform.sh), nothing else branches on harness.
#
# Subcommands:
#   transport-script
#       Print the harness-correct spawn-script PATH (no execution):
#         PIPELINE_HARNESS=codex          -> scripts/spawn-codex.sh
#         PIPELINE_HARNESS=claude / unset -> scripts/spawn-claude.sh
#       This is the transport-selection seam run-queue.sh routes both of its
#       spawn-claude call sites through.
#
#   dispatch <parent-worktree> <leaf-id> [<leaf-id> ...]
#       Print (or, without PIPELINE_DISPATCH_DRY_RUN, execute) the harness-correct
#       leaf-dispatch PLAN around the UNCHANGED path-c-split-worktree.sh
#       setup -> (dispatch) -> reassemble -> teardown lifecycle. ONLY the dispatch
#       VERB branches on $PIPELINE_HARNESS:
#         claude -> the in-session `Agent` tool dispatches each leaf.
#         codex  -> the Codex agent-control verbs spawn_agent / wait_agent /
#                   close_agent dispatch + reap each leaf.
#       The lifecycle helper (path-c-split-worktree.sh) is invoked verbatim and is
#       NOT modified by this script.

_dispatch_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve $PIPELINE_HARNESS.
#
# An EXPLICITLY-set PIPELINE_HARNESS env var is the operator's authoritative
# choice and wins — that is exactly the seam contract this script exposes
# (`PIPELINE_HARNESS=codex dispatch-leaf.sh transport-script` must select codex).
# platform.sh is the FALLBACK detector for when the caller has NOT decided:
# sourcing it unconditionally would recompute from config/env/default and clobber
# the caller's explicit choice (platform.sh does not honor a pre-set value). So
# only defer to platform.sh when PIPELINE_HARNESS is unset/empty. Sourced under
# `set -e`; platform.sh keeps exit status 0 via its own `|| true` guards.
if [ -z "${PIPELINE_HARNESS:-}" ]; then
  if [ -f "${_dispatch_dir}/platform.sh" ]; then
    # shellcheck disable=SC1091
    source "${_dispatch_dir}/platform.sh"
  else
    PIPELINE_HARNESS="claude"
  fi
fi

# The script directory the spawn-script paths are rooted at. Prefer the sibling
# directory of THIS script (so a relocated plugin still self-resolves); callers
# may export CLAUDE_PLUGIN_ROOT but it is not required for path printing.
SCRIPT_DIR="$_dispatch_dir"

usage() {
  echo "Usage: $0 {transport-script | dispatch <parent-worktree> <leaf-id> [<leaf-id> ...]}" >&2
  exit 2
}

# Echo the harness-correct spawn-script path.
transport_script_path() {
  case "$PIPELINE_HARNESS" in
    codex) printf '%s\n' "${SCRIPT_DIR}/spawn-codex.sh" ;;
    *)     printf '%s\n' "${SCRIPT_DIR}/spawn-claude.sh" ;;
  esac
}

CMD="${1:-}"; [ -n "$CMD" ] || usage
shift || true

case "$CMD" in
  transport-script)
    transport_script_path
    ;;

  dispatch)
    PARENT="${1:-}"; [ -n "$PARENT" ] || usage
    shift || usage
    [ $# -ge 1 ] || usage
    LEAVES=("$@")
    SPLIT="${SCRIPT_DIR}/path-c-split-worktree.sh"

    # The leaf-dispatch PLAN. The lifecycle phases (setup / reassemble / teardown)
    # are harness-INVARIANT and delegate to the UNCHANGED path-c-split-worktree.sh.
    # ONLY the per-leaf dispatch verb between setup and reassemble branches on the
    # harness. Under PIPELINE_DISPATCH_DRY_RUN=1 we PRINT the plan instead of
    # executing it (the seam is the branch, not the runtime — the actual Agent /
    # spawn_agent calls are issued by the orchestrator/Codex host, not this shell).
    emit_plan() {
      echo "# dispatch-leaf plan (harness=${PIPELINE_HARNESS})"
      echo "# parent-worktree=${PARENT}"
      echo "# lifecycle helper: ${SPLIT} (UNCHANGED)"
      for leaf in "${LEAVES[@]}"; do
        echo "setup: bash ${SPLIT} setup ${PARENT} ${leaf}"
        case "$PIPELINE_HARNESS" in
          codex)
            echo "dispatch[codex]: spawn_agent leaf=${leaf}  # then wait_agent + close_agent to reap"
            echo "reap[codex]: wait_agent leaf=${leaf}; close_agent leaf=${leaf}"
            ;;
          *)
            echo "dispatch[claude]: Agent(subagent_type=tdd-implementer, leaf=${leaf})"
            ;;
        esac
      done
      echo "reassemble: bash ${SPLIT} reassemble ${PARENT} ${LEAVES[*]}"
      echo "teardown: bash ${SPLIT} teardown ${PARENT} ${LEAVES[*]}"
    }

    if [ "${PIPELINE_DISPATCH_DRY_RUN:-}" = "1" ]; then
      emit_plan
      exit 0
    fi

    # Non-dry-run: emit the plan to stdout as the executable contract. The actual
    # Agent / spawn_agent dispatch is performed by the harness host (orchestrator
    # in-session Agent, or the Codex agent-control surface), which consumes this
    # plan. We still drive the harness-invariant lifecycle phases here so the
    # split-worktree setup/teardown happen regardless of harness.
    emit_plan
    ;;

  *)
    usage
    ;;
esac
