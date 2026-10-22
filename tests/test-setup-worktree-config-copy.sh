#!/bin/bash
set -euo pipefail
# Tests that scripts/setup-worktree.sh copies $MAIN_REPO/pipeline.config into
# $WORKTREE_PATH/pipeline.config so the worktree-local `source ./pipeline.config`
# in execute-issue-plan / evaluate-issue-pr Boot resolves PIPELINE_* vars.
# pipeline.config is gitignored + host-specific, so this test stages a synthetic
# config in a temp main checkout — it never reads the host's live config (#529).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/setup-worktree.sh"
PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
MAIN_REPO="$TMP/main"; mkdir -p "$MAIN_REPO"
cat > "$MAIN_REPO/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS=""
PIPELINE_SYNC_VENVS=""
CFG
STUB_BIN="$TMP/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/git" <<'GIT_STUB'
#!/bin/bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
cmd="${1:-}"
case "$cmd" in
  worktree)
    sub="${2:-}"
    case "$sub" in
      list) ;;
      add)
        shift 2
        if [ "${1:-}" = "-b" ]; then shift 2; fi
        path="$1"; mkdir -p "$path" ;;
    esac ;;
  rev-parse) echo "staging" ;;
  show-ref) exit 1 ;;
  ls-remote) echo "refs/heads/${3:-staging}" ;;
  ls-files) exit 1 ;;
  push) ;;
  *) ;;
esac
GIT_STUB
chmod +x "$STUB_BIN/git"
REAL_PATH="$PATH"
export PATH="$STUB_BIN:$PATH"
cd "$MAIN_REPO"
export PIPELINE_PROJECT_ROOT="$MAIN_REPO"
set +e
bash "$HELPER" feature/wt-77 77 >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then echo "STDOUT:"; cat "$TMP/out"; echo "STDERR:"; cat "$TMP/err"; fail_msg "setup-worktree.sh exited $rc"; fi
WORKTREE_PATH="$MAIN_REPO/.claude/worktrees/wt-77-wt-77"
TARGET="$WORKTREE_PATH/pipeline.config"
if [ -f "$TARGET" ]; then pass_msg "pipeline.config copied to worktree"; else fail_msg "expected $TARGET to exist"; fi
if [ -f "$TARGET" ] && diff -q "$MAIN_REPO/pipeline.config" "$TARGET" >/dev/null 2>&1; then
  pass_msg "copied bytes identical to source"
else
  fail_msg "copied file differs from source"
fi
# Sourcing the worktree copy must populate PIPELINE_REPO (the real-world symptom).
RESOLVED=$(cd "$WORKTREE_PATH" && source ./pipeline.config 2>/dev/null && echo "$PIPELINE_REPO")
if [ "$RESOLVED" = "rjskene/pipeline" ]; then
  pass_msg "worktree-local source resolves PIPELINE_REPO"
else
  fail_msg "worktree-local source did not resolve PIPELINE_REPO (got '$RESOLVED')"
fi
HELPER_SRC="$SCRIPT_DIR/../scripts/setup-worktree.sh"
if grep -q 'pipeline.config' "$HELPER_SRC" && grep -q 'cp "$MAIN_REPO/pipeline.config"' "$HELPER_SRC"; then
  pass_msg "setup-worktree.sh references the pipeline.config copy in its sync step"
else
  fail_msg "setup-worktree.sh does not copy pipeline.config"
fi
# The worktree copy must be ignored by the shared .gitignore (never tracked).
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if grep -qE '^/?pipeline\.config$' "$REPO_ROOT/.gitignore"; then
  pass_msg "pipeline.config is gitignored (worktree copy auto-ignored)"
else
  fail_msg "pipeline.config not gitignored — worktree copy could be tracked"
fi
# --- Real-git cases (#1565): a TRACKED pipeline.config / env file keeps the
# committed copy; a gitignored one is still copied from the main checkout.
export PATH="$REAL_PATH"
make_fixture() { # <dir> — repo with a bare origin, main pushed
  local proj="$1"
  mkdir -p "$proj"
  git init -q "$proj"
  git -C "$proj" config user.email t@t.t
  git -C "$proj" config user.name t
}
push_fixture() { # <dir>
  local proj="$1"
  git init --bare -q "$proj.origin.git"
  git -C "$proj" remote add origin "$proj.origin.git"
  git -C "$proj" push -q origin HEAD:refs/heads/main
}
write_cfg() { # <file> <sync-envs>
  cat > "$1" <<CFG
PIPELINE_REPO="fake/repo"
PIPELINE_BASE_BRANCH="main"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_INSTALL_CMD="true"
PIPELINE_SEED_CMD=""
PIPELINE_SYNC_ENVS="$2"
PIPELINE_SYNC_VENVS=""
CFG
}

# Case A: tracked config + tracked env — the main checkout drifts, the
# worktree must keep the committed bytes and stay clean.
PROJ="$TMP/case-a"
make_fixture "$PROJ"
write_cfg "$PROJ/pipeline.config" ".env.tracked"
echo "X=committed" > "$PROJ/.env.tracked"
git -C "$PROJ" add pipeline.config .env.tracked && git -C "$PROJ" commit -qm seed
push_fixture "$PROJ"
echo 'PIPELINE_EXTRA="drift"' >> "$PROJ/pipeline.config"
echo "X=drift" >> "$PROJ/.env.tracked"
set +e
(cd "$PROJ" && PIPELINE_PROJECT_ROOT="$PROJ" bash "$HELPER" feature/tracked 11) >"$TMP/out-a" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] && pass_msg "case A: setup-worktree.sh exited 0" || { cat "$TMP/out-a"; fail_msg "case A: setup-worktree.sh exited $rc"; }
WT="$PROJ/.claude/worktrees/wt-11-tracked"
if [ -f "$WT/pipeline.config" ] && cmp -s "$WT/pipeline.config" <(git -C "$PROJ" show HEAD:pipeline.config); then
  pass_msg "case A: tracked pipeline.config keeps the committed copy"
else
  fail_msg "case A: worktree pipeline.config differs from HEAD:pipeline.config"
fi
if [ -f "$WT/.env.tracked" ] && cmp -s "$WT/.env.tracked" <(git -C "$PROJ" show HEAD:.env.tracked); then
  pass_msg "case A: tracked env file keeps the committed copy"
else
  fail_msg "case A: worktree .env.tracked differs from HEAD:.env.tracked"
fi
STATUS="$(git -C "$WT" status --porcelain 2>&1 || true)"
[ -z "$STATUS" ] && pass_msg "case A: worktree status clean" || fail_msg "case A: worktree not clean: $STATUS"
grep -qF 'pipeline.config is tracked; worktree keeps the committed copy' "$TMP/out-a" \
  && pass_msg "case A: skip line printed" || fail_msg "case A: skip line missing"
git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null || true

# Case B: gitignored config + untracked env — copied from the main checkout.
PROJ="$TMP/case-b"
make_fixture "$PROJ"
printf 'pipeline.config\n.env.local\n' > "$PROJ/.gitignore"
echo seed > "$PROJ/seed.txt"
git -C "$PROJ" add .gitignore seed.txt && git -C "$PROJ" commit -qm seed
push_fixture "$PROJ"
write_cfg "$PROJ/pipeline.config" ".env.local"
echo "Y=local" > "$PROJ/.env.local"
set +e
(cd "$PROJ" && PIPELINE_PROJECT_ROOT="$PROJ" bash "$HELPER" feature/ignored 12) >"$TMP/out-b" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] && pass_msg "case B: setup-worktree.sh exited 0" || { cat "$TMP/out-b"; fail_msg "case B: setup-worktree.sh exited $rc"; }
WT="$PROJ/.claude/worktrees/wt-12-ignored"
cmp -s "$PROJ/pipeline.config" "$WT/pipeline.config" \
  && pass_msg "case B: gitignored pipeline.config copied" || fail_msg "case B: worktree pipeline.config differs from main copy"
cmp -s "$PROJ/.env.local" "$WT/.env.local" \
  && pass_msg "case B: untracked env file copied" || fail_msg "case B: worktree .env.local differs from main copy"
grep -qF 'Copied pipeline.config' "$TMP/out-b" \
  && pass_msg "case B: copy line printed" || fail_msg "case B: copy line missing"
STATUS="$(git -C "$WT" status --porcelain 2>&1 || true)"
[ -z "$STATUS" ] && pass_msg "case B: worktree status clean" || fail_msg "case B: worktree not clean: $STATUS"
git -C "$PROJ" worktree remove --force "$WT" 2>/dev/null || true

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
