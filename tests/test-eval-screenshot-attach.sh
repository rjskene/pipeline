#!/bin/bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0; FAIL=0
pass_msg(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
fail_msg(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
assert(){ if eval "$2"; then pass_msg "$1"; else fail_msg "$1"; fi; }

HELPER="$REPO_ROOT/mock-web-eval/scripts/eval-screenshot-attach.sh"

assert "eval-screenshot-attach.sh exists"      "[ -f '$HELPER' ]"
assert "eval-screenshot-attach.sh executable"  "[ -x '$HELPER' ]"

# In-branch commit mechanism contract (issue #271, #337).
assert "uses git add .eval-screenshots"        "grep -q 'git add .*\\.eval-screenshots' '$HELPER'"
assert "uses git commit"                       "grep -q 'git commit' '$HELPER'"
assert "uses git push"                         "grep -q 'git push' '$HELPER'"

# Negative: must NOT use the legacy release-asset flow.
assert "does NOT use gh release"               "! grep -q 'gh release' '$HELPER'"

# Branch-pinned URL shape (issue #337) — literal or interpolated form of
# https://raw.githubusercontent.com/<owner>/<repo>/<branch>/.eval-screenshots/<name>.png
assert "emits branch-pinned raw URL" \
  "grep -qE 'raw\\.githubusercontent\\.com/.*\\.eval-screenshots' '$HELPER'"

# Usage check: with no args, must exit non-zero AND print a 'usage:' line.
if [ -x "$HELPER" ]; then
  OUT="$(bash "$HELPER" </dev/null 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && echo "$OUT" | grep -q 'usage:'; then
    pass_msg "no-args invocation prints usage and exits non-zero"
  else
    fail_msg "no-args invocation prints usage and exits non-zero (rc=$rc, out=$OUT)"
  fi
else
  fail_msg "no-args invocation prints usage and exits non-zero (helper not executable)"
fi

# -----------------------------------------------------------------------------
# Sealed end-to-end test: real git, local bare remote.
# Verifies that running the helper:
#   (a) prints a branch-pinned raw.githubusercontent.com/.../<branch>/.eval-screenshots/<name>.png URL
#   (b) creates a commit on the local branch
#   (c) pushes that commit to the bare remote so its HEAD's tree contains
#       .eval-screenshots/<name>.png
# -----------------------------------------------------------------------------
sealed_e2e() {
  local TMP
  TMP="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMP'" RETURN

  # Bare remote + working clone. `-b main` pins the bare repo's symbolic
  # HEAD to `refs/heads/main` so the later `git ls-tree -r HEAD` resolves
  # against the branch the helper pushes to. Without it, CI runners whose
  # git defaults `HEAD` to `master` see an empty tree.
  git init --bare -q -b main "$TMP/remote.git"
  git -c init.defaultBranch=main init -q "$TMP/work"
  (
    cd "$TMP/work" || exit 99
    git config user.email "eval@test.local"
    git config user.name  "eval test"
    git remote add origin "$TMP/remote.git"
    # Seed an initial commit so HEAD exists.
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m "seed"
    git push -q -u origin HEAD:main
  )

  # PNG to attach. Tiny content; we only check tree membership.
  local PNG="$TMP/probe.png"
  printf '\x89PNG\r\n\x1a\n' > "$PNG"   # PNG magic only; not a valid image but fine for the test

  # Run the helper from the working clone.
  local URL_OUT RC
  URL_OUT="$(cd "$TMP/work" && PIPELINE_REPO="test/repo" bash "$HELPER" 271 "$PNG" 2>/dev/null)"
  RC=$?

  if [ "$RC" -ne 0 ]; then
    fail_msg "sealed e2e: helper exited 0 (rc=$RC, out=$URL_OUT)"
    return
  fi

  # (a) URL shape: raw.githubusercontent.com/test/repo/<branch>/.eval-screenshots/probe.png
  if echo "$URL_OUT" | grep -qE 'https://raw\.githubusercontent\.com/test/repo/[^/]+/\.eval-screenshots/probe\.png'; then
    pass_msg "sealed e2e: helper printed branch-pinned raw URL"
  else
    fail_msg "sealed e2e: helper printed branch-pinned raw URL (got: $URL_OUT)"
  fi

  # (b) A commit exists locally with .eval-screenshots/probe.png in HEAD's tree.
  if (cd "$TMP/work" && git ls-tree -r HEAD --name-only) | grep -q '^\.eval-screenshots/probe\.png$'; then
    pass_msg "sealed e2e: local HEAD tree contains .eval-screenshots/probe.png"
  else
    fail_msg "sealed e2e: local HEAD tree contains .eval-screenshots/probe.png"
  fi

  # (c) The bare remote received the push — its HEAD tree contains the file.
  if (cd "$TMP/remote.git" && git ls-tree -r HEAD --name-only 2>/dev/null) | grep -q '^\.eval-screenshots/probe\.png$'; then
    pass_msg "sealed e2e: bare remote received the screenshot commit"
  else
    fail_msg "sealed e2e: bare remote received the screenshot commit"
  fi
}

if [ -x "$HELPER" ]; then
  sealed_e2e
else
  fail_msg "sealed e2e: helper not executable"
fi

# -----------------------------------------------------------------------------
# Fail-soft test: broken remote. Helper must NOT exit non-zero even when
# `git push` fails. It must print a warning to stderr and continue.
# -----------------------------------------------------------------------------
fail_soft() {
  local TMP
  TMP="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMP'" RETURN

  git -c init.defaultBranch=main init -q "$TMP/work"
  (
    cd "$TMP/work" || exit 99
    git config user.email "eval@test.local"
    git config user.name  "eval test"
    # Origin points at a path that does not exist — `git push` will fail.
    git remote add origin "$TMP/nonexistent.git"
    echo seed > seed.txt
    git add seed.txt
    git commit -q -m "seed"
  )

  local PNG="$TMP/probe.png"
  printf '\x89PNG\r\n\x1a\n' > "$PNG"

  local OUT RC ERR
  ERR="$(cd "$TMP/work" && PIPELINE_REPO="test/repo" bash "$HELPER" 271 "$PNG" 2>&1 >/dev/null)"
  OUT="$(cd "$TMP/work" && PIPELINE_REPO="test/repo" bash "$HELPER" 271 "$PNG" 2>/dev/null)"
  RC=$?

  if [ "$RC" -eq 0 ]; then
    pass_msg "fail-soft: helper exits 0 on push failure"
  else
    fail_msg "fail-soft: helper exits 0 on push failure (rc=$RC)"
  fi

  if echo "$ERR" | grep -qi 'push'; then
    pass_msg "fail-soft: helper prints a push-failure warning to stderr"
  else
    fail_msg "fail-soft: helper prints a push-failure warning to stderr (stderr=$ERR)"
  fi
}

if [ -x "$HELPER" ]; then
  fail_soft
else
  fail_msg "fail-soft: helper not executable"
fi

# -----------------------------------------------------------------------------
# Private-repo test (issue #551): when `gh repo view ... isPrivate` reports
# `true`, the helper must emit a github.com/<repo>/blob/<branch>/.eval-screenshots/
# URL (the raw.githubusercontent.com host 404s anonymously on private repos and
# GitHub's camo image proxy can't authenticate). A `gh` shim is prepended to
# PATH so the script's visibility probe sees isPrivate=true. The gh-free sealed
# e2e above continues to assert the raw URL via the fail-soft default.
# -----------------------------------------------------------------------------
private_repo_emits_blob() {
  local TMP; TMP="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMP'" RETURN
  git init --bare -q -b main "$TMP/remote.git"
  git -c init.defaultBranch=main init -q "$TMP/work"
  (
    cd "$TMP/work" || exit 99
    git config user.email e@t.l; git config user.name t
    git remote add origin "$TMP/remote.git"; echo seed > seed.txt
    git add seed.txt; git commit -q -m seed; git push -q -u origin HEAD:main
  )
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
case "$*" in *"repo view"*"isPrivate"*) echo "true" ;; *) exit 0 ;; esac
SHIM
  chmod +x "$TMP/bin/gh"
  local PNG="$TMP/probe.png"; printf '\x89PNG\r\n\x1a\n' > "$PNG"
  local URL_OUT; URL_OUT="$(cd "$TMP/work" && PATH="$TMP/bin:$PATH" PIPELINE_REPO="test/repo" bash "$HELPER" 271 "$PNG" 2>/dev/null)"
  if echo "$URL_OUT" | grep -qE 'https://github\.com/test/repo/blob/[^/]+/\.eval-screenshots/probe\.png'; then
    pass_msg "private: helper printed blob URL"
  else
    fail_msg "private: helper printed blob URL (got: $URL_OUT)"
  fi
}

if [ -x "$HELPER" ]; then
  private_repo_emits_blob
else
  fail_msg "private: helper not executable"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
