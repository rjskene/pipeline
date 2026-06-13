#!/bin/bash
set -uo pipefail

# Unit test for scripts/_resolve-config.sh — the shared sourceable helper that
# self-resolves PIPELINE_* config (issue #1022).
#
# ROOT CAUSE under test: SKILL `## Boot` blocks `source pipeline.config` into the
# skill's shell scope but do NOT `export` the vars, so a downstream `bash
# script.sh` subshell does not inherit them. Helpers running under `set -u` then
# abort at their `: "${PIPELINE_*:?}"` guard on the FIRST invocation. The helper
# fixes this script-side via export-on-source: when a required PIPELINE_* var is
# unset, it locates the project root (PIPELINE_PROJECT_ROOT > git toplevel >
# walk-up for a dir with both pipeline.config + .git) and `set -a; source
# pipeline.config; set +a` so the vars are EXPORTED into child subshells.
#
# Contract:
#   - Idempotent / no-clobber: when the vars are already set, the helper is a
#     no-op and never overwrites pre-set values.
#   - Export-on-source: resolved vars propagate to child `bash` subshells.
#   - Fail-closed: when no config is findable, the helper leaves vars UNSET so
#     the caller's own `:?` guard still fires with its original message.
#   - set -u-safe: the helper reads its own inputs via ${VAR:-} so sourcing it
#     into a `set -u` host never trips -u before resolution.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/_resolve-config.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

# Build a fixture project dir holding a `pipeline.config` (with set -a wrapper,
# matching pipeline.config.example) and a `.git` marker so the combined
# pipeline.config+.git walk-up check accepts it as a consumer repo.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/pipeline.config" <<'CFG'
set -a
PIPELINE_REPO="fix/repo"
PIPELINE_BASE_BRANCH="trunk"
set +a
CFG
  # A regular .git FILE is enough for the combined marker check (git worktrees
  # use a regular file, not a dir).
  echo "gitdir: /tmp/fake" > "$dir/.git"
}

if [ ! -f "$HELPER" ]; then
  echo "FAIL: $HELPER not found (helper not yet created)"
  echo ""
  echo "================================"
  echo "  1 tests: PASS=0 FAIL=1"
  echo "================================"
  exit 1
fi

# ============== Case 1: resolve via explicit PIPELINE_PROJECT_ROOT ============
echo "Case 1: PIPELINE_PROJECT_ROOT resolves PIPELINE_REPO + PIPELINE_BASE_BRANCH"
inc
F1="$ROOT/f1"; make_fixture "$F1"
OUT=$(env -i HOME="$HOME" PATH="$PATH" PIPELINE_PROJECT_ROOT="$F1" \
        bash -c "source '$HELPER'; echo \"\$PIPELINE_REPO \$PIPELINE_BASE_BRANCH\"" 2>&1)
if [ "$OUT" = "fix/repo trunk" ]; then
  pass_msg "explicit PIPELINE_PROJECT_ROOT -> 'fix/repo trunk'"
else
  fail_msg "explicit PIPELINE_PROJECT_ROOT: expected 'fix/repo trunk', got: '$OUT'"
fi

# ============== Case 2: idempotent / no-clobber when vars already set =========
echo ""
echo "Case 2: pre-set vars are NOT clobbered (idempotent no-op)"
inc
F2="$ROOT/f2"; make_fixture "$F2"
OUT=$(env -i HOME="$HOME" PATH="$PATH" PIPELINE_PROJECT_ROOT="$F2" \
        PIPELINE_REPO="already/set" PIPELINE_BASE_BRANCH="preset" \
        bash -c "source '$HELPER'; echo \"\$PIPELINE_REPO \$PIPELINE_BASE_BRANCH\"" 2>&1)
if [ "$OUT" = "already/set preset" ]; then
  pass_msg "pre-set vars preserved -> 'already/set preset'"
else
  fail_msg "no-clobber: expected 'already/set preset', got: '$OUT'"
fi

# ============== Case 3: walk-up from cwd, NO PIPELINE_PROJECT_ROOT ============
echo ""
echo "Case 3: walk-up / git-toplevel resolution from a cwd inside the fixture"
inc
F3="$ROOT/f3"; make_fixture "$F3"
mkdir -p "$F3/sub/deep"
# env -i drops PIPELINE_PROJECT_ROOT; cd into a nested subdir so the helper must
# walk up to find the dir holding both pipeline.config + .git.
OUT=$(cd "$F3/sub/deep" && env -i HOME="$HOME" PATH="$PATH" \
        bash -c "cd '$F3/sub/deep'; source '$HELPER'; echo \"\$PIPELINE_REPO\"" 2>&1)
if [ "$OUT" = "fix/repo" ]; then
  pass_msg "walk-up from nested cwd -> 'fix/repo'"
else
  fail_msg "walk-up: expected 'fix/repo', got: '$OUT'"
fi

# ============== Case 4: export-on-source — child subshell inherits (the bug) ==
echo ""
echo "Case 4: resolved var is EXPORTED to a child subshell (core of #1022)"
inc
F4="$ROOT/f4"; make_fixture "$F4"
# source the helper, then spawn a CHILD bash -c that prints the var WITHOUT
# re-sourcing. If the helper only set a shell-local (not exported), the child
# sees an empty value — exactly the sourced-but-not-exported failure.
OUT=$(env -i HOME="$HOME" PATH="$PATH" PIPELINE_PROJECT_ROOT="$F4" \
        bash -c "source '$HELPER'; bash -c 'echo \"\$PIPELINE_REPO\"'" 2>&1)
if [ "$OUT" = "fix/repo" ]; then
  pass_msg "child subshell inherits exported PIPELINE_REPO -> 'fix/repo'"
else
  fail_msg "export-on-source: child subshell expected 'fix/repo', got: '$OUT'"
fi

# ============== Case 5: fail-closed — no config findable leaves vars unset ====
echo ""
echo "Case 5: no resolvable config -> vars stay UNSET (caller's :? still fires)"
inc
EMPTY="$ROOT/empty-no-config"; mkdir -p "$EMPTY"
# No pipeline.config anywhere up the tree from $EMPTY, no PIPELINE_PROJECT_ROOT.
# The helper must NOT hard-fail and must leave PIPELINE_REPO unset so the
# caller's own `: "${PIPELINE_REPO:?}"` guard fires. Assert the subsequent
# `: "${PIPELINE_REPO:?}"` aborts (exit non-zero) — proving fail-closed.
set +e
env -i HOME="$HOME" PATH="$PATH" \
  bash -c "cd '$EMPTY'; set -u; source '$HELPER'; : \"\${PIPELINE_REPO:?must be set}\"" \
  >/dev/null 2>&1
rc=$?
set -e 2>/dev/null || true
if [ "$rc" -ne 0 ]; then
  pass_msg "no config: helper left PIPELINE_REPO unset; caller's :? guard still fires (rc=$rc)"
else
  fail_msg "fail-closed: expected non-zero from the caller's :? guard, got rc=$rc"
fi

# ============== Case 6: set -u-safe — sourcing under set -u does not abort =====
echo ""
echo "Case 6: helper is set -u-safe (sourcing under set -u does not trip -u)"
inc
F6="$ROOT/f6"; make_fixture "$F6"
set +e
OUT=$(env -i HOME="$HOME" PATH="$PATH" PIPELINE_PROJECT_ROOT="$F6" \
        bash -c "set -u; source '$HELPER'; echo \"OK \$PIPELINE_REPO\"" 2>&1)
rc=$?
set -e 2>/dev/null || true
if [ "$rc" -eq 0 ] && [ "$OUT" = "OK fix/repo" ]; then
  pass_msg "set -u host: sourced cleanly and resolved -> 'OK fix/repo'"
else
  fail_msg "set -u-safe: expected rc=0 + 'OK fix/repo', got rc=$rc out='$OUT'"
fi

# ============== Case 7: callers self-resolve — rewrite-eval-screenshot-urls ===
# Integration: the eval screenshot-rewrite step must proceed PAST its line-36
# `PIPELINE_REPO` unset-skip when PIPELINE_REPO is resolvable from config
# (no pre-export). With a `gh` PATH stub, reaching the `gh pr view` call proves
# the script self-resolved rather than fail-soft-skipping.
echo ""
echo "Case 7: rewrite-eval-screenshot-urls.sh self-resolves PIPELINE_REPO from config"
inc
F7="$ROOT/f7"; make_fixture "$F7"
STUB7="$ROOT/stub7"; mkdir -p "$STUB7"
# gh stub: record that `gh pr view` was reached, then emit empty headRefName so
# the script exits 0 at the next guard (we only need to prove it got past line 36).
cat > "$STUB7/gh" <<'GH'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "REACHED_GH_PR_VIEW" >> "$GH_MARKER"
fi
printf ''
exit 0
GH
chmod +x "$STUB7/gh"
MARKER7="$F7/gh-marker"; : > "$MARKER7"
env -i HOME="$HOME" PATH="$STUB7:$PATH" PIPELINE_PROJECT_ROOT="$F7" GH_MARKER="$MARKER7" \
  bash "$REPO_ROOT/scripts/rewrite-eval-screenshot-urls.sh" 42 deadbeef >/dev/null 2>&1
if grep -qF "REACHED_GH_PR_VIEW" "$MARKER7"; then
  pass_msg "rewrite-eval-screenshot-urls.sh resolved PIPELINE_REPO and reached gh pr view"
else
  fail_msg "rewrite-eval: skipped at line-36 unset guard — PIPELINE_REPO did not self-resolve"
fi

# ============== Case 8: callers self-resolve — finalize-issue-labels ==========
# finalize-issue-labels.sh must resolve REPO from config (not the `gh repo view`
# fallback) when PIPELINE_REPO is unset but resolvable. With a `gh` stub that
# records the `--repo` value passed to `gh issue edit`, assert the config repo
# (fix/repo) is threaded through — NOT a `gh repo view` fallback value.
echo ""
echo "Case 8: finalize-issue-labels.sh self-resolves PIPELINE_REPO from config"
inc
F8="$ROOT/f8"; make_fixture "$F8"
STUB8="$ROOT/stub8"; mkdir -p "$STUB8"
cat > "$STUB8/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
  "issue view") printf 'pr-open\n'; exit 0 ;;
  "issue edit") exit 0 ;;
  "repo view")  echo "fallback/repo"; exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$STUB8/gh"
LOG8="$F8/gh.log"; : > "$LOG8"
env -i HOME="$HOME" PATH="$STUB8:$PATH" PIPELINE_PROJECT_ROOT="$F8" GH_LOG="$LOG8" \
  bash "$REPO_ROOT/scripts/finalize-issue-labels.sh" 1022 >/dev/null 2>&1
if grep -qF -- '--repo fix/repo' "$LOG8" && ! grep -qF -- '--repo fallback/repo' "$LOG8"; then
  pass_msg "finalize-issue-labels.sh resolved repo from config (fix/repo), not the gh fallback"
else
  fail_msg "finalize-labels: did not thread config repo (fix/repo) into gh issue edit"
  sed 's/^/    /' "$LOG8"
fi

# ============== Case 9: walk-up rejects the plugin tree, picks consumer repo ===
# The walk-up must reject a pipeline.config that lacks a co-located .git and
# resolve the CONSUMER repo. Shape a worktree-style cwd: a nested dir whose
# NEAREST ancestor with pipeline.config also has .git is the consumer fixture.
# A bare pipeline.config WITHOUT .git deeper in the tree must be skipped.
echo ""
echo "Case 9: walk-up rejects a .git-less pipeline.config, resolves the consumer repo"
inc
F9="$ROOT/f9"; make_fixture "$F9"
# Plant a decoy pipeline.config (NO .git) in a subdir; cwd is below the decoy.
# The combined check must skip the decoy and keep walking up to the real fixture.
mkdir -p "$F9/decoy/inner"
cat > "$F9/decoy/pipeline.config" <<'CFG'
set -a
PIPELINE_REPO="decoy/should-not-win"
PIPELINE_BASE_BRANCH="decoy"
set +a
CFG
OUT=$(env -i HOME="$HOME" PATH="$PATH" \
        bash -c "cd '$F9/decoy/inner'; source '$HELPER'; echo \"\$PIPELINE_REPO\"" 2>&1)
if [ "$OUT" = "fix/repo" ]; then
  pass_msg "walk-up skipped the .git-less decoy and resolved the consumer repo -> 'fix/repo'"
else
  fail_msg "walk-up: decoy pipeline.config (no .git) won or resolution failed, got: '$OUT'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
