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

  # -----------------------------------------------------------------------
  # Group 4b: re-run with staging ahead of $SHA is also a no-op
  # -----------------------------------------------------------------------
  : > "$SHIM/gh.log"
  : > "$SHIM/git-push.log"
  (
    cd "$FIX"
    git checkout -q staging
    git pull -q --ff-only origin staging 2>/dev/null || true
    echo "staging-ahead" > NEW_FILE.md
    git add NEW_FILE.md
    git commit -q -m "chore: staging-ahead change after back-sync"
    git push -q origin staging
    SHA=$(cat "$TMP/clean.main-sha")
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/idem-ahead.out" 2>&1
    echo "$?" > "$TMP/idem-ahead.rc"
  )
  assert "idempotent: re-run with staging ahead of \$SHA is also a no-op" "[ \"\$(cat '$TMP/idem-ahead.rc')\" = '0' ] && grep -qi 'already synced' '$TMP/idem-ahead.out' && ! grep -qE 'push' '$SHIM/git-push.log'"
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
# Group 6: -X theirs real-merge path (overlapping files, main wins)
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT" ]; then
  FIX="$TMP/xtheirs"
  make_fixture "$FIX"
  SHIM="$TMP/shim-xtheirs"
  install_shims "$SHIM"
  (
    cd "$FIX"
    # Pre-stage staging with an edit to CHANGELOG.md (the same file the release
    # commit touched on main) so FF is not possible and the merge has a real
    # overlapping file conflict. Under -X theirs main wins.
    git checkout -q staging
    echo "staging-newer" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: staging-ahead change on shared file"
    git push -q origin staging
    git checkout -q main
    SHA=$(git rev-parse main)
    echo "$SHA" > "$TMP/xtheirs.main-sha"
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/xtheirs.out" 2>&1
    echo "$?" > "$TMP/xtheirs.rc"
    git fetch -q origin staging 2>/dev/null || true
    git checkout -q staging
    git pull -q --ff-only origin staging 2>/dev/null || true
    cat CHANGELOG.md > "$TMP/xtheirs.changelog"
    git rev-parse staging > "$TMP/xtheirs.staging-sha"
    git log -1 staging --format=%P > "$TMP/xtheirs.parents"
    git log -1 staging --format=%s > "$TMP/xtheirs.subject"
  )
  assert "xtheirs: script exits 0" "[ \"\$(cat '$TMP/xtheirs.rc')\" = '0' ]"
  assert "xtheirs: main-version of CHANGELOG.md wins (content is 'v0.0.0-test')" "[ \"\$(cat '$TMP/xtheirs.changelog')\" = 'v0.0.0-test' ]"
  assert "xtheirs: a merge commit was created (not FF)" "[ \"\$(cat '$TMP/xtheirs.staging-sha')\" != \"\$(cat '$TMP/xtheirs.main-sha')\" ] && [ \"\$(wc -w < '$TMP/xtheirs.parents')\" = '2' ]"
  assert "xtheirs: merge commit subject starts with 'chore(back-sync):'" "grep -qE '^chore\\(back-sync\\):' '$TMP/xtheirs.subject'"
  assert "xtheirs: 'git push origin staging' was invoked" "grep -qE 'push.*origin.*staging' '$SHIM/git-push.log'"
  assert "xtheirs: NO draft PR opened" "! grep -q 'pr create' '$SHIM/gh.log'"
fi

# ---------------------------------------------------------------------------
# Group 7: version-manifest collision (main wins under -X theirs)
#
# Mirrors the v0.7.1 regression. Staging carries an older snapshot of the
# version-manifest files; main carries release-please's bumped versions. The
# back-sync MUST favor main on every collision so the bumps survive on staging.
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT" ]; then
  FIX="$TMP/vmanifest"
  make_fixture "$FIX"
  SHIM="$TMP/shim-vmanifest"
  install_shims "$SHIM"
  (
    cd "$FIX"
    # Stage staging with older version-manifest content so FF is impossible.
    git checkout -q staging
    mkdir -p .claude-plugin
    echo '{"version": "0.7.0"}'           > .claude-plugin/plugin.json
    echo '{"version": "0.7.0"}'           > .claude-plugin/marketplace.json
    echo '{".":"0.7.0"}'                  > .release-please-manifest.json
    git add .claude-plugin .release-please-manifest.json
    git commit -q -m "chore: staging carries pre-release manifest snapshot"
    git push -q origin staging

    # Build a release-please-style commit on main that bumps every manifest +
    # the CHANGELOG. This overwrites the same paths staging just touched.
    git checkout -q main
    mkdir -p .claude-plugin
    echo '{"version": "0.7.1"}'           > .claude-plugin/plugin.json
    echo '{"version": "0.7.1"}'           > .claude-plugin/marketplace.json
    echo '{".":"0.7.1"}'                  > .release-please-manifest.json
    echo "## 0.7.1" >> CHANGELOG.md
    git add .claude-plugin .release-please-manifest.json CHANGELOG.md
    git commit -q -m "chore(main): release 0.7.1"
    git push -q origin main

    SHA=$(git rev-parse main)
    echo "$SHA" > "$TMP/vmanifest.main-sha"
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/vmanifest.out" 2>&1
    echo "$?" > "$TMP/vmanifest.rc"

    git fetch -q origin staging 2>/dev/null || true
    git checkout -q staging
    git pull -q --ff-only origin staging 2>/dev/null || true
    cat .claude-plugin/plugin.json          > "$TMP/vmanifest.plugin"
    cat .claude-plugin/marketplace.json     > "$TMP/vmanifest.marketplace"
    cat .release-please-manifest.json       > "$TMP/vmanifest.rp-manifest"
    cat CHANGELOG.md                        > "$TMP/vmanifest.changelog"
    git log -1 staging --format=%s          > "$TMP/vmanifest.subject"
  )
  assert "vmanifest: script exits 0" "[ \"\$(cat '$TMP/vmanifest.rc')\" = '0' ]"
  assert "vmanifest: staging's .claude-plugin/plugin.json contains \"0.7.1\"" "grep -q '\"0.7.1\"' '$TMP/vmanifest.plugin'"
  assert "vmanifest: staging's .claude-plugin/marketplace.json contains \"0.7.1\"" "grep -q '\"0.7.1\"' '$TMP/vmanifest.marketplace'"
  assert "vmanifest: staging's .release-please-manifest.json contains \"0.7.1\"" "grep -q '\"0.7.1\"' '$TMP/vmanifest.rp-manifest'"
  assert "vmanifest: staging's CHANGELOG.md contains '## 0.7.1'" "grep -q '## 0.7.1' '$TMP/vmanifest.changelog'"
  assert "vmanifest: merge commit subject starts with 'chore(back-sync):'" "grep -qE '^chore\\(back-sync\\):' '$TMP/vmanifest.subject'"
  assert "vmanifest: no draft PR opened" "! grep -q 'pr create' '$SHIM/gh.log'"
fi

# ---------------------------------------------------------------------------
# Group 8: asymmetric-collision regression (mixed vintage in one back-sync)
#
# Proves a single back-sync correctly handles both vintages in one merge:
#   - staging-only file (STAGING_FEATURE.md) — survives unchanged
#   - both-sides-touched manifest (.claude-plugin/plugin.json) — main wins
# Guards against any future "global strategy flip" reintroducing a regression
# in the opposite direction.
# ---------------------------------------------------------------------------
if [ -x "$SCRIPT" ]; then
  FIX="$TMP/asym"
  make_fixture "$FIX"
  SHIM="$TMP/shim-asym"
  install_shims "$SHIM"
  (
    cd "$FIX"
    # Staging carries (a) a new file main never touches and (b) an older
    # snapshot of .claude-plugin/plugin.json — only the latter overlaps main.
    git checkout -q staging
    echo "post-release feature work" > STAGING_FEATURE.md
    mkdir -p .claude-plugin
    echo '{"version": "0.7.0"}'      > .claude-plugin/plugin.json
    git add STAGING_FEATURE.md .claude-plugin/plugin.json
    git commit -q -m "chore: staging-only feature + older manifest snapshot"
    git push -q origin staging

    # Main carries release-please's bump — only touches .claude-plugin/plugin.json.
    git checkout -q main
    mkdir -p .claude-plugin
    echo '{"version": "0.7.1"}'      > .claude-plugin/plugin.json
    git add .claude-plugin/plugin.json
    git commit -q -m "chore(main): release 0.7.1"
    git push -q origin main

    SHA=$(git rev-parse main)
    echo "$SHA" > "$TMP/asym.main-sha"
    export SHIM_DIR="$SHIM"
    PATH="$SHIM:$PATH" bash "$SCRIPT" "$SHA" >"$TMP/asym.out" 2>&1
    echo "$?" > "$TMP/asym.rc"

    git fetch -q origin staging 2>/dev/null || true
    git checkout -q staging
    git pull -q --ff-only origin staging 2>/dev/null || true
    cat STAGING_FEATURE.md            > "$TMP/asym.staging-feature"
    cat .claude-plugin/plugin.json    > "$TMP/asym.plugin"
    git rev-parse staging             > "$TMP/asym.staging-sha"
    git log -1 staging --format=%P    > "$TMP/asym.parents"
    git log -1 staging --format=%s    > "$TMP/asym.subject"
  )
  assert "asym: script exits 0" "[ \"\$(cat '$TMP/asym.rc')\" = '0' ]"
  assert "asym: staging's STAGING_FEATURE.md survives unchanged" "[ \"\$(cat '$TMP/asym.staging-feature')\" = 'post-release feature work' ]"
  assert "asym: staging's .claude-plugin/plugin.json contains \"0.7.1\"" "grep -q '\"0.7.1\"' '$TMP/asym.plugin'"
  assert "asym: a single merge commit was created" "[ \"\$(cat '$TMP/asym.staging-sha')\" != \"\$(cat '$TMP/asym.main-sha')\" ]"
  assert "asym: merge commit has 2 parents" "[ \"\$(wc -w < '$TMP/asym.parents')\" = '2' ]"
  assert "asym: merge commit subject starts with 'chore(back-sync):'" "grep -qE '^chore\\(back-sync\\):' '$TMP/asym.subject'"
fi

# ---------------------------------------------------------------------------
# Group 5: workflow YAML
# ---------------------------------------------------------------------------
assert "workflow file exists" "[ -f '$WORKFLOW' ]"
if [ -f "$WORKFLOW" ]; then
  assert "workflow named back-sync-release" "grep -qE '^name: back-sync-release' '$WORKFLOW'"
  assert "workflow triggers on push to main" "grep -qE 'branches:.*main|- main' '$WORKFLOW'"
  assert "workflow filters by chore(main): release token (contains, survives merge-commit subjects per #459)" "grep -qE \"contains\\\\(github.event.head_commit.message, 'chore\\\\(main\\\\): release \" '$WORKFLOW'"
  assert "workflow grants contents: write" "grep -qE 'contents: write' '$WORKFLOW'"
  assert "workflow grants pull-requests: write" "grep -qE 'pull-requests: write' '$WORKFLOW'"
  assert "workflow invokes back-sync-release.sh" "grep -qE 'bash scripts/back-sync-release.sh' '$WORKFLOW'"
  assert "workflow checks out with fetch-depth: 0" "grep -qE 'fetch-depth: 0' '$WORKFLOW'"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
