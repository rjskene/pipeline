#!/bin/bash
set -uo pipefail

# Tests for scripts/back-sync-release.sh — cherry-picks release-please release
# commits from main onto staging. Conflict path opens a draft PR for human resolution.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/back-sync-release.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/back-sync-release.yml"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
assert() { if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

# ---------------------------------------------------------------------------
# Group 1: scaffolding
# ---------------------------------------------------------------------------
assert "script exists" "[ -f '$SCRIPT' ]"
assert "script is executable" "[ -x '$SCRIPT' ]"
assert "script has bash shebang" "head -1 '$SCRIPT' | grep -q '^#!/bin/bash'"

# ---------------------------------------------------------------------------
# Fixture helpers — build a throwaway git repo with main + staging branches
# and a synthetic release-please-style commit on main.
# ---------------------------------------------------------------------------
make_fixture() {
  local DIR="$1"
  mkdir -p "$DIR"
  (
    cd "$DIR"
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name  "Test"
    git config commit.gpgsign false
    echo "v0" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: initial"
    git branch staging
    # synthetic release-please release commit on main
    echo "v0.0.0-test" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore(main): release 0.0.0-test"
    # add a fake "origin" remote pointing at a bare clone so 'push' works
    git clone -q --bare . "$DIR.bare"
    git remote add origin "$DIR.bare"
    git push -q origin main
    git push -q origin staging
  )
}

# Install PATH shims that record gh/git push invocations to log files in $1.
install_shims() {
  local SHIM_DIR="$1"
  mkdir -p "$SHIM_DIR"
  : > "$SHIM_DIR/gh.log"
  : > "$SHIM_DIR/git-push.log"

  cat > "$SHIM_DIR/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_DIR/gh.log"
exit 0
GH
  chmod +x "$SHIM_DIR/gh"

  # Wrap git so we record any 'git push' invocation while delegating everything
  # else to the real git on PATH (after we strip $SHIM_DIR from PATH).
  cat > "$SHIM_DIR/git" <<'GIT'
#!/bin/bash
if [ "${1:-}" = "push" ]; then
  echo "git $*" >> "$SHIM_DIR/git-push.log"
fi
# Find the real git by stripping $SHIM_DIR from PATH.
REAL_PATH=$(echo "$PATH" | tr ':' '\n' | grep -vxF "$SHIM_DIR" | paste -sd: -)
PATH="$REAL_PATH" exec git "$@"
GIT
  chmod +x "$SHIM_DIR/git"
}

# ---------------------------------------------------------------------------
# Group 2: clean fast-forward path
# ---------------------------------------------------------------------------
TMP=$(mktemp -d)
trap "rm -rf '$TMP'" EXIT

if [ -x "$SCRIPT" ]; then
  FIX="$TMP/clean"
  make_fixture "$FIX"
  SHIM="$TMP/shim-clean"
  install_shims "$SHIM"
  (
    cd "$FIX"
    SHA=$(git rev-parse main)
    echo "$SHA" > "$TMP/clean.main-sha"
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/clean.out" 2>&1
    echo "$?" > "$TMP/clean.rc"
    git fetch -q origin staging 2>/dev/null || true
    git log staging --grep "release 0.0.0-test" --oneline > "$TMP/clean.staging-log"
    git rev-parse staging > "$TMP/clean.staging-sha"
  )
  assert "clean: script exits 0" "[ \"\$(cat '$TMP/clean.rc')\" = '0' ]"
  assert "clean: release commit's TREE is present on staging via merge or FF" "[ -s '$TMP/clean.staging-log' ]"
  assert "clean: no draft PR opened (gh shim not invoked for pr create)" "! grep -q 'pr create' '$SHIM/gh.log'"
  assert "clean: staging fast-forwarded to the release SHA" "[ \"\$(cat '$TMP/clean.staging-sha')\" = \"\$(cat '$TMP/clean.main-sha')\" ]"
  assert "clean: 'git push origin staging' was invoked" "grep -qE 'push.*origin.*staging' '$SHIM/git-push.log'"

  # -----------------------------------------------------------------------
  # Group 4: idempotency — re-running the same SHA is a no-op
  # -----------------------------------------------------------------------
  : > "$SHIM/gh.log"
  : > "$SHIM/git-push.log"
  (
    cd "$FIX"
    SHA=$(git rev-parse main)
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/idem.out" 2>&1
    echo "$?" > "$TMP/idem.rc"
  )
  assert "idempotent: re-run exits 0" "[ \"\$(cat '$TMP/idem.rc')\" = '0' ]"
  assert "idempotent: re-run reports 'already synced'" "grep -qi 'already synced' '$TMP/idem.out'"
  assert "idempotent: re-run did NOT invoke git push" "! grep -qE 'push' '$SHIM/git-push.log'"
fi

# ---------------------------------------------------------------------------
# Group 3: true conflict (delete/modify) -> draft PR fallback
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT" ]; then
  FIX="$TMP/conflict"
  make_fixture "$FIX"
  SHIM="$TMP/shim-conflict"
  install_shims "$SHIM"
  (
    cd "$FIX"
    # Pre-stage staging by deleting the same file the release commit modifies.
    # delete/modify conflicts cannot be auto-resolved by -X ours, so the helper
    # must fall through to the draft-PR fallback.
    git checkout -q staging
    git rm -q CHANGELOG.md
    git commit -q -m "staging: delete file release-please will touch"
    git push -q origin staging
    git checkout -q main
    SHA=$(git rev-parse main)
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/conflict.out" 2>&1
    echo "$?" > "$TMP/conflict.rc"
  )
  assert "conflict: script exits 0 (fail-soft)" "[ \"\$(cat '$TMP/conflict.rc')\" = '0' ]"
  assert "conflict: did NOT push directly to origin staging" "! grep -qE 'push.*origin.*staging( |\$)' '$SHIM/git-push.log' || grep -qE 'release-back-sync/' '$SHIM/git-push.log'"
  assert "conflict: opened a draft PR via gh pr create" "grep -qE 'pr create.*--draft' '$SHIM/gh.log'"
  assert "conflict: draft PR base is staging" "grep -qE 'pr create.*--base staging' '$SHIM/gh.log'"
  assert "conflict: branch name uses release-back-sync/ prefix" "grep -qE 'release-back-sync/' '$SHIM/gh.log'"
fi

# ---------------------------------------------------------------------------
# Group 6: -X ours real-merge path (overlapping files, staging wins)
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT" ]; then
  FIX="$TMP/xours"
  make_fixture "$FIX"
  SHIM="$TMP/shim-xours"
  install_shims "$SHIM"
  (
    cd "$FIX"
    # Pre-stage staging with a newer edit to CHANGELOG.md (the same file the
    # release commit touched on main) so FF is not possible and the merge has
    # a real overlapping file conflict.
    git checkout -q staging
    echo "staging-newer" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: staging-ahead change on shared file"
    git push -q origin staging
    git checkout -q main
    SHA=$(git rev-parse main)
    echo "$SHA" > "$TMP/xours.main-sha"
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/xours.out" 2>&1
    echo "$?" > "$TMP/xours.rc"
    git fetch -q origin staging 2>/dev/null || true
    git checkout -q staging
    git pull -q --ff-only origin staging 2>/dev/null || true
    cat CHANGELOG.md > "$TMP/xours.changelog"
    git rev-parse staging > "$TMP/xours.staging-sha"
    git log -1 staging --format=%P > "$TMP/xours.parents"
    git log -1 staging --format=%s > "$TMP/xours.subject"
  )
  assert "xours: script exits 0" "[ \"\$(cat '$TMP/xours.rc')\" = '0' ]"
  assert "xours: staging-version of CHANGELOG.md wins (content is 'staging-newer')" "[ \"\$(cat '$TMP/xours.changelog')\" = 'staging-newer' ]"
  assert "xours: a merge commit was created (not FF)" "[ \"\$(cat '$TMP/xours.staging-sha')\" != \"\$(cat '$TMP/xours.main-sha')\" ] && [ \"\$(wc -w < '$TMP/xours.parents')\" = '2' ]"
  assert "xours: merge commit subject starts with 'chore(back-sync):'" "grep -qE '^chore\\(back-sync\\):' '$TMP/xours.subject'"
  assert "xours: 'git push origin staging' was invoked" "grep -qE 'push.*origin.*staging' '$SHIM/git-push.log'"
  assert "xours: NO draft PR opened" "! grep -q 'pr create' '$SHIM/gh.log'"
fi

# ---------------------------------------------------------------------------
# Group 5: workflow YAML
# ---------------------------------------------------------------------------
assert "workflow file exists" "[ -f '$WORKFLOW' ]"
if [ -f "$WORKFLOW" ]; then
  assert "workflow named back-sync-release" "grep -qE '^name: back-sync-release' '$WORKFLOW'"
  assert "workflow triggers on push to main" "grep -qE 'branches:.*main|- main' '$WORKFLOW'"
  assert "workflow filters by chore(main): release prefix" "grep -qE \"startsWith\\\\(github.event.head_commit.message, 'chore\\\\(main\\\\): release \" '$WORKFLOW'"
  assert "workflow grants contents: write" "grep -qE 'contents: write' '$WORKFLOW'"
  assert "workflow grants pull-requests: write" "grep -qE 'pull-requests: write' '$WORKFLOW'"
  assert "workflow invokes back-sync-release.sh" "grep -qE 'bash scripts/back-sync-release.sh' '$WORKFLOW'"
  assert "workflow checks out with fetch-depth: 0" "grep -qE 'fetch-depth: 0' '$WORKFLOW'"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
