#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$REPO_ROOT/compose.mock-web-eval.yml"
ENV_FILE="$REPO_ROOT/mock-web/.env.mock-web-eval"
PROBE="$REPO_ROOT/scripts/mock-web-eval-probe-port.sh"

PASS=0; FAIL=0; SKIP=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip_msg(){ echo "  SKIP: $1"; SKIP=$((SKIP+1)); }

# Gate: heavy smoke (downloads ~500 MB on first build). Default CI skips.
if [ "${MOCK_WEB_EVAL_SMOKE:-0}" != "1" ]; then
  skip_msg "MOCK_WEB_EVAL_SMOKE != 1; skipping container smoke"
  echo ""; echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  exit 0
fi
if ! command -v docker >/dev/null 2>&1; then
  skip_msg "docker CLI not available; skipping container smoke"
  echo ""; echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  exit 0
fi
if ! docker compose version >/dev/null 2>&1; then
  skip_msg "docker compose v2 plugin not available; skipping"
  echo ""; echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
  exit 0
fi

[ -f "$COMPOSE" ] || { fail_msg "compose file missing: $COMPOSE"; exit 1; }
[ -x "$PROBE" ]   || { fail_msg "probe missing: $PROBE"; exit 1; }

# Seed env file (UID/GID + HOST_PORT) so compose has what it needs.
bash "$PROBE" >/dev/null

cd "$REPO_ROOT"

# Build the image (cached on subsequent runs).
if ! docker compose -f "$COMPOSE" --env-file "$ENV_FILE" build mock-web-eval >/dev/null 2>&1; then
  fail_msg "docker compose build failed"
  exit 1
fi
pass_msg "image builds successfully"

# Probe Playwright/Chromium via npx (uses global-bin resolution — works
# regardless of cwd/NODE_PATH, unlike `node -e 'require("playwright")'`).
OUT=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval \
  npx --yes playwright --version 2>&1 || true)
if echo "$OUT" | grep -qE 'Version|playwright version'; then
  pass_msg "Playwright reports its version (Chromium install path is valid)"
else
  echo "$OUT" | sed 's/^/    /'
  fail_msg "Playwright could not report a version inside container"
fi

# Sanity: gh CLI must be present (so #231 wiring can shell out from inside).
OUT2=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval gh --version 2>&1 || true)
if echo "$OUT2" | grep -qE '^gh version '; then
  pass_msg "gh CLI is installed inside the container"
else
  echo "$OUT2" | sed 's/^/    /'
  fail_msg "gh CLI missing inside container"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
