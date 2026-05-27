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

# Allocate the port by composing the broker (no formula duplication).
PORT=$(bash "${SCRIPT_DIR}/visual-proof-port-broker.sh" "$slate_index" "$slate_width" \
         | sed -n 's/^PORT=//p')
if [ -z "$PORT" ]; then
  echo "block-server-start: port broker emitted no PORT for slate_index=$slate_index" >&2
  exit 1
fi

# Start the loopback server detached. --bind 127.0.0.1 is load-bearing
# (never 0.0.0.0 — avoids external exposure during concurrent fullsend runs).
# --directory <target_dir> is load-bearing too: reap-stale-visual-proof-servers.sh
# tracks servers by parsing this flag out of the cmdline.
nohup python3 -m http.server "$PORT" --directory "$target_dir" --bind 127.0.0.1 \
  >/dev/null 2>&1 &
SERVER_PID=$!

# Readiness probe — mirrors evaluate-issue-pr Step 6c, plus --retry-connrefused
# so curl retries while the freshly-detached http.server is still binding the
# port (without it, curl --retry treats connection-refused as fatal and exits 7
# before the server is up — racy on a cold start).
if ! curl --silent --fail --retry 5 --retry-delay 1 --retry-connrefused --max-time 10 \
          "http://127.0.0.1:$PORT/" >/dev/null; then
  echo "block-server-start: http.server not ready on 127.0.0.1:$PORT (dir=$target_dir)" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  exit 1
fi

echo "SERVER: pid=${SERVER_PID} port=${PORT} dir=${target_dir}"
exit 0
