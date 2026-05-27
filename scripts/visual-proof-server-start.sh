#!/bin/bash
set -uo pipefail
#
# visual-proof-server-start.sh — bootstrap a loopback static file server for
# inline browser-eval. Composes visual-proof-port-broker.sh (port allocation)
# then starts `python3 -m http.server --directory <target> --bind 127.0.0.1`.
# Single reusable entry point for the single-issue orchestrator path (which
# never reaches run-queue.sh launch_agent()), manual operators, and the
# evaluate-issue-pr inline path (Step 6c). See Issue #527 (PR #519 follow-up).
#
# Argv:
#   $1  slate_index  (required; forwarded to the broker)
#   $2  target_dir   (required; must exist — served by http.server)
#   $3  slate_width  (optional; forwarded to the broker; default 0)
#
# Env:
#   PIPELINE_VISUAL_PROOF_PORT_BASE  (honored transitively by the broker)
#
# Output (stdout, on success): SERVER: pid=<P> port=<PORT> dir=<target_dir>
# Exit codes:
#   0  server up + ready
#   1  server failed readiness probe (stderr: block-server-start: ...)
#   2  invalid input (missing/nonexistent target_dir)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <slate_index> <target_dir> [<slate_width>]" >&2
  exit 2
fi

slate_index="$1"
target_dir="$2"
slate_width="${3:-0}"

if [ ! -d "$target_dir" ]; then
  echo "ERROR: target_dir does not exist: $target_dir" >&2
  exit 2
fi
