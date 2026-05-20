#!/bin/bash
# tests/test-doctor-container-assets.sh — integration tests for the
# container_assets_unwired CHECK in scripts/doctor.sh. Asserts the CHECK line
# is emitted, status fields are correct on representative fixtures, and the
# summary table includes the new check name.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# Build a fixture project that has the minimum doctor.sh needs to run past
# the gh / config gates without bailing early. Doctor only emits the new
# CHECK when it gets that far.
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj"
  mkdir -p "$root/plugin/scripts" "$root/plugin/hooks"
  cat > "$root/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
  # Stage a git repo so doctor's base_branch_local check has something to
  # poke at (it won't fail the run, but a missing .git dir keeps doctor from
  # advancing past that point in some environments).
  (cd "$root/proj" && git init -q --initial-branch=staging 2>/dev/null \
     && git -c user.email=test@test -c user.name=test commit -q --allow-empty -m init 2>/dev/null) || true
  echo "$root"
}

# Run doctor with the project as CWD and CLAUDE_PLUGIN_ROOT pointed at the
# fixture plugin dir. The plugin dir is empty enough that doctor will skip
# helper-driven checks for surfaces we don't care about here; container
# assets live on the project root, not under $CLAUDE_PLUGIN_ROOT.
run_doctor() {
  local root="$1"; shift
  (
    cd "$root/proj"
    # shellcheck disable=SC1091
    source ./pipeline.config
    CLAUDE_PLUGIN_ROOT="$root/plugin" bash "$DOCTOR" 2>&1 || true
  )
}

# ---------------------------------------------------------------------------
# Case 1: clean fixture (no compose files) → CHECK pass.
# ---------------------------------------------------------------------------
echo "Case 1: clean fixture → container_assets_unwired status=pass"
ROOT=$(fresh_fx fx-clean)
out=$(run_doctor "$ROOT")
if echo "$out" | grep -qE '^CHECK: container_assets_unwired status=pass'; then
  pass_msg "CHECK line emitted with status=pass"
else
  fail_msg "missing CHECK: container_assets_unwired status=pass"
  echo "$out" | grep -E 'container_assets_unwired|CHECK:' | sed 's/^/    /'
fi
if echo "$out" | grep -qE 'container_assets_unwired'; then
  pass_msg "summary table mentions container_assets_unwired"
else
  fail_msg "summary table does not mention container_assets_unwired"
fi

# ---------------------------------------------------------------------------
# Case 2: triangle fixture → CHECK fail + doctor exits non-zero.
# ---------------------------------------------------------------------------
echo "Case 2: full-triangle fixture → container_assets_unwired status=fail"
ROOT=$(fresh_fx fx-triangle)
cat > "$ROOT/proj/compose.web-eval.yml" <<'YAML'
services:
  claude-web-eval:
    environment:
      BOMON_WEB_EVAL: "1"
YAML
: > "$ROOT/proj/Dockerfile.web-eval"
: > "$ROOT/proj/.env.web-eval"
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-web-eval-evidence.py" <<'PY'
import os
if os.environ.get('BOMON_WEB_EVAL'):
    pass
PY
out=$(run_doctor "$ROOT")
if echo "$out" | grep -qE '^CHECK: container_assets_unwired status=fail'; then
  pass_msg "fail CHECK line emitted"
else
  fail_msg "expected status=fail for full-triangle fixture"
  echo "$out" | grep -E 'container_assets_unwired|CHECK:' | sed 's/^/    /'
fi
# Doctor exit must be non-zero when any check is fail. Re-run capturing rc.
rc=$(
  cd "$ROOT/proj"
  # shellcheck disable=SC1091
  source ./pipeline.config
  CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR" >/dev/null 2>&1
  echo $?
)
if [ "$rc" != "0" ]; then
  pass_msg "doctor exits non-zero on triangle fixture"
else
  fail_msg "doctor exited 0 despite container_assets_unwired status=fail"
fi
# Per-asset diagnostic lines from the helper must be replayed in doctor output.
if echo "$out" | grep -qE 'compose\.web-eval\.yml.*FAIL'; then
  pass_msg "per-asset diagnostic line replayed by doctor"
else
  fail_msg "per-asset diagnostic missing from doctor output"
  echo "$out" | grep -E 'web-eval|container_assets' | sed 's/^/    /'
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
