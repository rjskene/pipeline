#!/bin/bash
set -euo pipefail

# Check if the backend and frontend are responding on their expected ports.
# Usage: bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-server.sh [backend-port] [frontend-port]
#
# Examples:
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-server.sh                # default ports 3001, 5173
#   bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-server.sh 3000 4025      # custom ports
#
# Exit codes:
#   0 = healthy
#   1 = one or more checks failed

BACKEND_PORT="${1:-3001}"
FRONTEND_PORT="${2:-5173}"
MAX_WAIT=30
ERRORS_FOUND=0

echo "=== Server Health Check ==="
echo ""

# --- 1. Wait for backend to respond ---
echo "[1/2] Waiting for backend (port $BACKEND_PORT)..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl -sf "http://localhost:$BACKEND_PORT/api/health" >/dev/null 2>&1 || \
     curl -sf "http://localhost:$BACKEND_PORT/" >/dev/null 2>&1; then
    echo "  OK: Backend responding (${ELAPSED}s)"
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "  FAIL: Backend not responding after ${MAX_WAIT}s"
  ERRORS_FOUND=1
fi
echo ""

# --- 2. Wait for frontend to respond ---
echo "[2/2] Waiting for frontend (port $FRONTEND_PORT)..."
ELAPSED=0
while [ $ELAPSED -lt $MAX_WAIT ]; do
  if curl -sf "http://localhost:$FRONTEND_PORT/" >/dev/null 2>&1; then
    echo "  OK: Frontend responding (${ELAPSED}s)"
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
if [ $ELAPSED -ge $MAX_WAIT ]; then
  echo "  FAIL: Frontend not responding after ${MAX_WAIT}s"
  ERRORS_FOUND=1
fi
echo ""

# --- Summary ---
if [ $ERRORS_FOUND -eq 0 ]; then
  echo "=== ALL CHECKS PASSED ==="
  exit 0
else
  echo "=== ERRORS DETECTED — review above ==="
  exit 1
fi
