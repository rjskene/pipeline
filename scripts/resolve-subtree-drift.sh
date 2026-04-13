#!/bin/bash
set -euo pipefail

# resolve-subtree-drift.sh — Resolve detected drift between .claude-pipeline/
# and its upstream source repo.
#
# Usage: bash .claude/scripts/resolve-subtree-drift.sh [--auto]
#   --auto: auto-pull + reinstall without prompting (full-send mode)
#           never pushes — push is a deliberate sharing decision
#
# Exit codes:
#   0 = resolved (or no drift)
#   1 = error during resolution
#   2 = user declined action (interactive mode)

AUTO=false
[ "${1:-}" = "--auto" ] && AUTO=true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ "$SCRIPT_DIR" == *".claude/scripts"* ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
elif [[ "$SCRIPT_DIR" == *".claude-pipeline/scripts"* ]]; then
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
else
  PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

PREFIX=".claude-pipeline"
CONFIG_FILE="$PROJECT_ROOT/pipeline.config"
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

REMOTE="${PIPELINE_SUBTREE_REMOTE:-}"
BRANCH="${PIPELINE_SUBTREE_BRANCH:-main}"

cd "$PROJECT_ROOT"

# --- Step A: Run drift check and capture exit code ---
DRIFT_CODE=0
bash "$SCRIPT_DIR/check-subtree-drift.sh" || DRIFT_CODE=$?

if [ "$DRIFT_CODE" -eq 0 ]; then
  echo "  [ok] No drift detected — nothing to do."
  exit 0
fi

# Codes: 2=upstream ahead, 3=local ahead, 4=bidirectional

# --- Step B: Auto-detect remote (same logic as check-subtree-drift.sh) ---
if [ -z "$REMOTE" ]; then
  REMOTE=$(git remote -v 2>/dev/null | grep -i 'claude-pipeline' | head -1 | awk '{print $1}' || true)
fi
if [ -z "$REMOTE" ]; then
  echo "  [error] No subtree remote found. Cannot resolve drift."
  exit 1
fi

# --- Step C: Helper functions ---
do_pull() {
  echo "  → Pulling upstream changes..."
  git subtree pull --prefix="$PREFIX" "$REMOTE" "$BRANCH" --squash
  echo "  [ok] Pull complete."
}

do_push() {
  echo "  → Pushing local changes to upstream..."
  git subtree push --prefix="$PREFIX" "$REMOTE" "$BRANCH"
  echo "  [ok] Push complete."
}

do_reinstall() {
  echo "  → Re-running install.sh..."
  bash "$PROJECT_ROOT/$PREFIX/install.sh"
  echo ""
  echo "  Skills updated. Exit and \`/resume\` to pick up changes,"
  echo "  or continue (spawned agents will use updated skills either way)."
}

prompt_yn() {
  local msg="$1"
  if $AUTO; then
    return 0  # auto-approve (caller checks context)
  fi
  echo -n "  $msg (y/n) "
  read -r ans
  case "$ans" in
    [yY]|[yY]es) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Step D: Resolve based on drift code ---
PULLED=false
PUSHED=false
REINSTALLED=false

case "$DRIFT_CODE" in
  2)  # Upstream ahead
    if $AUTO; then
      do_pull
      PULLED=true
      do_reinstall
      REINSTALLED=true
    else
      if prompt_yn "Pull upstream changes?"; then
        do_pull
        PULLED=true
        if prompt_yn "Re-run install.sh to update skills?"; then
          do_reinstall
          REINSTALLED=true
        fi
      else
        echo "  [skip] User declined pull."
        exit 2
      fi
    fi
    ;;
  3)  # Local ahead
    if $AUTO; then
      echo "  [skip] Local ahead — push is a sharing decision, not auto-resolved."
      echo "  → To push: git subtree push --prefix=$PREFIX $REMOTE $BRANCH"
      exit 0
    else
      if prompt_yn "Push local changes to upstream?"; then
        do_push
        PUSHED=true
      else
        echo "  [skip] User declined push."
        exit 2
      fi
    fi
    ;;
  4)  # Bidirectional
    if $AUTO; then
      echo "  [info] Bidirectional drift detected. Auto-pulling upstream..."
      do_pull
      PULLED=true
      do_reinstall
      REINSTALLED=true
      echo "  [skip] Push skipped — sharing decision, not auto-resolved."
      echo "  → To push: git subtree push --prefix=$PREFIX $REMOTE $BRANCH"
    else
      echo "  Bidirectional drift — both sides have changes."
      if prompt_yn "Pull upstream changes first?"; then
        do_pull
        PULLED=true
      fi
      if prompt_yn "Push local changes to upstream?"; then
        do_push
        PUSHED=true
      fi
      if $PULLED; then
        if prompt_yn "Re-run install.sh to update skills?"; then
          do_reinstall
          REINSTALLED=true
        fi
      fi
    fi
    ;;
  *)
    echo "  [error] Unexpected drift code: $DRIFT_CODE"
    exit 1
    ;;
esac

# --- Step E: Summary report ---
echo ""
echo "=== Drift Resolution Summary ==="
$PULLED && echo "  Pull:      done" || echo "  Pull:      skipped"
$PUSHED && echo "  Push:      done" || echo "  Push:      skipped"
$REINSTALLED && echo "  Reinstall: done" || echo "  Reinstall: skipped"
echo ""
exit 0
