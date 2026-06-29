#!/bin/bash
set -euo pipefail

# End-to-end label -> --base resolution contract for next-branch routing (#1128).
#
# Pins that the three surfaces AGREE on routing a next-labelled issue onto the
# configured next-branch:
#   1. skills/fullsend/SKILL.md Step 5 documents prepending
#      --base "${PIPELINE_NEXT_BRANCH:-next}" when the next-label is present.
#   2. scripts/render-status-table.sh renders Target Base = <next-branch> for a
#      next-labelled issue (the operator-visible signal).
#   3. scripts/setup-worktree.sh, given --base <next-branch>, records that branch
#      in .claude/base-branch (the value the enforce-base-branch hook reads).
# A divergence between the renderer's Target Base and the worktree's base-branch
# would mean the status table promised a route the executor did not take.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FULLSEND="$REPO_ROOT/skills/fullsend/SKILL.md"
RENDER="$REPO_ROOT/scripts/render-status-table.sh"
SETUP="$REPO_ROOT/scripts/setup-worktree.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- 1. fullsend Step 5 documents the label -> --base directive -------------
echo "1. fullsend Step 5 documents the next-label --base directive"
inc
STEP5_LINE=$(grep -nE '^5\. \*\*Set up worktrees\*\*' "$FULLSEND" | head -1 | cut -d: -f1)
if [ -z "$STEP5_LINE" ]; then
  fail_msg "could not find Step 5 anchor in fullsend SKILL.md"
else
  WINDOW_END=$((STEP5_LINE + 30))
  STEP5=$(sed -n "${STEP5_LINE},${WINDOW_END}p" "$FULLSEND")
  # The directive must reference the configurable next-branch read-site default
  # and the --base flag together.
  if echo "$STEP5" | grep -qF '${PIPELINE_NEXT_BRANCH:-next}' \
     && echo "$STEP5" | grep -qE -- '--base'; then
    pass_msg "Step 5 documents --base \${PIPELINE_NEXT_BRANCH:-next} for next-labelled issues"
  else
    fail_msg "Step 5 window lacks the --base \${PIPELINE_NEXT_BRANCH:-next} directive"
  fi
fi

inc
# The legacy next-major-release alias must also be named in Step 5 so existing
# labelled issues keep routing.
if grep -qF 'next-major-release' "$FULLSEND"; then
  pass_msg "fullsend names the legacy next-major-release alias"
else
  fail_msg "fullsend does not mention the legacy next-major-release alias"
fi

# --- 2 + 3. renderer Target Base agrees with setup-worktree base-branch -----
echo "2+3. renderer Target Base == setup-worktree .claude/base-branch for a next-labelled issue"

# Renderer: a next-labelled issue must render Target Base = next.
cat >"$WORKDIR/next-issue.json" <<'JSON'
[{"number": 4242, "title": "feat(core): next-routed issue", "labels": [{"name": "priority/P1"}, {"name": "next"}], "body": "", "updatedAt": "2026-05-21T00:00:00Z"}]
JSON
RENDER_PROJ=$(mktemp -d)
RENDERED_BASE=$(PIPELINE_PROJECT_ROOT="$RENDER_PROJ" bash "$RENDER" \
  --issues "$WORKDIR/next-issue.json" --today 2026-05-21 2>/dev/null \
  | grep -E '#4242[[:space:]]*\|' | sed -E 's/^[[:space:]]*#4242[[:space:]]*\|[[:space:]]*([^ |]+).*/\1/')
rm -rf "$RENDER_PROJ"
inc
if [ "$RENDERED_BASE" = "next" ]; then
  pass_msg "renderer Target Base = next for a next-labelled issue"
else
  fail_msg "renderer Target Base != next (got '$RENDERED_BASE')"
fi

# setup-worktree: given --base next, .claude/base-branch must record next.
PROJ="$WORKDIR/proj"
rm -rf "$PROJ" "$WORKDIR/origin.git"
mkdir -p "$PROJ/.claude/scripts"
git init --bare -q "$WORKDIR/origin.git"
git -c init.defaultBranch=main init -q "$PROJ"
git -C "$PROJ" remote add origin "$WORKDIR/origin.git"
git -C "$PROJ" config user.email "tester@example.com"
git -C "$PROJ" config user.name "tester"
echo seed > "$PROJ/seed.txt"
git -C "$PROJ" add seed.txt
git -C "$PROJ" commit -q -m seed
git -C "$PROJ" branch -q staging
git -C "$PROJ" branch -q next
git -C "$PROJ" push -q origin main staging next
git -C "$PROJ" checkout -q staging
cat > "$PROJ/pipeline.config" <<'CFG'
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="ct"
PIPELINE_INSTALL_CMD=""
PIPELINE_SEED_CMD=""
PIPELINE_TEST_CMD=""
PIPELINE_TYPECHECK_CMD=""
PIPELINE_CONTEXT_FILES=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
PIPELINE_SYNC_DOCS=""
PIPELINE_SYNC_FILES=""
PIPELINE_LABELS_EXCLUDED=""
PIPELINE_LABELS_LATER=""
PIPELINE_LABELS_HUMAN=""
PIPELINE_WIN_TEMP=""
PIPELINE_SUBTREE_REMOTE=""
PIPELINE_SUBTREE_BRANCH=""
CFG
cp "$SETUP" "$PROJ/.claude/scripts/setup-worktree.sh"
chmod +x "$PROJ/.claude/scripts/setup-worktree.sh"

inc
if ! ( cd "$PROJ" && bash .claude/scripts/setup-worktree.sh --base next feature/foo 4242 ) \
        >"$WORKDIR/setup.log" 2>&1; then
  fail_msg "setup-worktree.sh --base next exited non-zero"
  sed 's/^/    /' "$WORKDIR/setup.log"
else
  SETUP_BASE=$(cat "$PROJ/.claude/worktrees/ct-4242-foo/.claude/base-branch" 2>/dev/null || echo "")
  if [ "$SETUP_BASE" = "next" ]; then
    pass_msg "setup-worktree records .claude/base-branch = next"
  else
    fail_msg "setup-worktree .claude/base-branch != next (got '$SETUP_BASE')"
  fi

  inc
  # The contract: renderer Target Base and worktree base-branch must AGREE.
  if [ -n "$RENDERED_BASE" ] && [ "$RENDERED_BASE" = "$SETUP_BASE" ]; then
    pass_msg "renderer Target Base ('$RENDERED_BASE') == worktree base-branch ('$SETUP_BASE')"
  else
    fail_msg "routing surfaces disagree: renderer='$RENDERED_BASE' worktree='$SETUP_BASE'"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
