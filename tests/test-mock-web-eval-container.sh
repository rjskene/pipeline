#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE="$REPO_ROOT/mock-web-eval/docker/compose.yml"
ENV_FILE="$REPO_ROOT/mock-web-eval/target/.env.mock-web-eval"
PROBE="$REPO_ROOT/mock-web-eval/scripts/mock-web-eval-probe-port.sh"

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

# Fixtures for issue #237: build under two host UID/GID layouts.
#   A — collision path: HOST_UID=HOST_GID=1000 matches the base image's
#       `node` user/group, which is the most-common Linux host layout.
#   B — no-collision path: HOST_UID=HOST_GID=1500 exercises the fresh
#       create branch as a regression check that the rename path didn't
#       break the create path.
# Each fixture asserts the build exits 0 AND that `id -u`/`id -g` inside
# the running container match the requested UID/GID (the bind-mount
# ownership contract).
echo "  -- Fixture A: HOST_UID=1000 HOST_GID=1000 (collision path) --"
if ! docker compose -f "$COMPOSE" --env-file "$ENV_FILE" build \
       --build-arg HOST_UID=1000 --build-arg HOST_GID=1000 mock-web-eval >/dev/null 2>&1; then
  fail_msg "fixture A — build with HOST_UID=1000 HOST_GID=1000"
else
  A_UID=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval id -u 2>/dev/null | tr -d '\r\n')
  A_GID=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval id -g 2>/dev/null | tr -d '\r\n')
  if [ "$A_UID" = "1000" ] && [ "$A_GID" = "1000" ]; then
    pass_msg "fixture A — build + id check at HOST_UID=1000 HOST_GID=1000"
  else
    fail_msg "fixture A — id mismatch: uid='$A_UID' gid='$A_GID' (expected 1000/1000)"
  fi
fi

echo "  -- Fixture B: HOST_UID=1500 HOST_GID=1500 (no-collision path) --"
if ! docker compose -f "$COMPOSE" --env-file "$ENV_FILE" build \
       --build-arg HOST_UID=1500 --build-arg HOST_GID=1500 mock-web-eval >/dev/null 2>&1; then
  fail_msg "fixture B — build with HOST_UID=1500 HOST_GID=1500"
else
  B_UID=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval id -u 2>/dev/null | tr -d '\r\n')
  B_GID=$(docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps mock-web-eval id -g 2>/dev/null | tr -d '\r\n')
  if [ "$B_UID" = "1500" ] && [ "$B_GID" = "1500" ]; then
    pass_msg "fixture B — build + id check at HOST_UID=1500 HOST_GID=1500"
  else
    fail_msg "fixture B — id mismatch: uid='$B_UID' gid='$B_GID' (expected 1500/1500)"
  fi
fi

# Build the image (cached on subsequent runs). The probe-seeded env file
# drives HOST_UID/HOST_GID for the default build that follows; the two
# fixtures above already exercised the collision and no-collision paths.
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

# Fixture for issue #505: /pipeline:* slash commands MUST be discoverable
# inside the container. Regression guard for #241 (same symptom one layer
# deeper): the real eval dispatch sets working_dir to a *worktree* under the
# registered project root, not the project root itself. PR #504's fullsend hit
# `Unknown command: /pipeline:evaluate-issue-pr` here — the plugin was
# registered (installed_plugins.json) but not discoverable from the worktree
# cwd. This fixture reproduces that dispatch shape and asserts the command
# RESOLVES (no `Unknown command:`) AND the doctor skill actually runs
# (positive structural marker: doctor.sh emits `CHECK:` / `=== Summary ===`).
# The positive assertion is deliberate anti-cheat: a fix that silently restores
# exit 0 without loading the plugin would emit neither marker and still FAIL.
# Goes GREEN via the same-absolute-path ~/.claude/plugins mount in compose.yml
# (root cause: marketplace installLocation host-path mismatch — see
# mock-web-eval/docs/diagnosis-505.md).
echo "  -- Fixture #505: /pipeline:* discoverable inside container --"
# The registered projectPath in ~/.claude/plugins/installed_plugins.json is the
# MAIN worktree (first `git worktree list` entry), which is NOT this checkout
# when the suite runs from a linked worktree. Mount THAT and point working_dir
# at a fresh worktree beneath it — mirroring scripts/spawn-claude.sh container
# dispatch (PIPELINE_PROJECT_ROOT=<main root>, working_dir=<worktree>).
MAIN_ROOT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$REPO_ROOT"
TEST_WT="$MAIN_ROOT/.claude/worktrees/test-505-discovery"
_cleanup_505() {
  git -C "$MAIN_ROOT" worktree remove --force "$TEST_WT" >/dev/null 2>&1 || true
  rm -rf "$TEST_WT" 2>/dev/null || true
}
trap _cleanup_505 EXIT
_cleanup_505  # clear any stale worktree from an aborted prior run
if ! git -C "$MAIN_ROOT" worktree add --detach "$TEST_WT" HEAD >/dev/null 2>&1; then
  fail_msg "fixture #505 — could not create test worktree at $TEST_WT"
else
  # Real pipeline worktrees carry an untracked .claude/settings.local.json copied
  # in by setup-worktree.sh / worktree-sync — it enables the local-scoped plugin.
  # A raw `git worktree add` omits it, so seed it here to mirror the production
  # worktree shape. Without this the fixture would exercise plugin ENABLEMENT (a
  # state production never reaches) instead of the marketplace-resolution
  # regression #505 actually fixes. See mock-web-eval/docs/diagnosis-505.md.
  mkdir -p "$TEST_WT/.claude"
  printf '{\n  "enabledPlugins": {\n    "pipeline@claude-pipeline": true\n  }\n}\n' \
    > "$TEST_WT/.claude/settings.local.json"
  # Shell exports take precedence over --env-file for compose interpolation, so
  # working_dir/volumes resolve to the #505 reproduction layout. HOST_* still
  # come from the probe-seeded $ENV_FILE.
  OUT505=$(PIPELINE_PROJECT_ROOT="$MAIN_ROOT" PIPELINE_WORKTREE_PATH="$TEST_WT" \
    docker compose -f "$COMPOSE" --env-file "$ENV_FILE" run --rm --no-deps \
      mock-web-eval claude --dangerously-skip-permissions -p '/pipeline:doctor' 2>&1 || true)
  if echo "$OUT505" | grep -qi 'Unknown command'; then
    echo "$OUT505" | sed 's/^/    /'
    fail_msg "container plugin slash-command discovery (got: Unknown command:)"
  elif echo "$OUT505" | grep -qiE 'CHECK:|=== Summary ===|gh_auth|pipeline_config|base_branch'; then
    pass_msg "container plugin slash-command discovery (/pipeline:doctor resolved + ran)"
  else
    echo "$OUT505" | sed 's/^/    /'
    fail_msg "container plugin slash-command discovery (no doctor output marker)"
  fi
fi
trap - EXIT
_cleanup_505

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
