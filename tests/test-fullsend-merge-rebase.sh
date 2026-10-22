#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-merge-rebase.sh — scripts/fullsend-merge-rebase.sh (#1536):
# the deterministic merge-time rebase. One stdout line REBASE=skip|done|conflict|dirty|error
# [FILES=<csv> HEAD=<pre-rebase-sha>], exit 0 on every decision; refuses the
# main checkout (exit 2).
#
#   S1 no overlap + MERGEABLE/CLEAN        -> REBASE=skip, HEAD unchanged
#   S2 different hunks of f.txt both sides -> REBASE=done, pushed, base ancestor
#   S3 same line both sides                -> REBASE=conflict FILES=f.txt HEAD=<H0>, clean abort
#   S4 worktree-dir is the main checkout   -> exit 2, no mutation
#   S5 --help exit 0; no args exit 2
#   S5b --no-gh default view is MERGEABLE/CLEAN
#   S7 two-commit branch conflicting in f.txt AND g.txt -> FILES=f.txt,g.txt HEAD=<H0>
#      (the rebase stops on commit 1; merge-tree surfaces the second path)
#   S8 rebase needed + modified tracked file -> REBASE=dirty FILES=pipeline.config
#      HEAD=<H0>; HEAD, remote tip and the unstaged edit untouched (no stash)
#   S9 rebase needed + only an untracked file -> REBASE=done (untracked ignored)
#   S10 git refuses the rebase (git shim, no rebase in progress)
#      -> REBASE=error REASON=<first stderr line>; no rebase --abort
#
# Fixtures: a bare origin, a main checkout (git_init_sandbox) and a feature
# checkout via `git worktree add`. Runs with --no-gh + REBASE_CHECK_VIEW_JSON; a
# failing `gh` stub proves no network call is made.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/fullsend-merge-rebase.sh"
# shellcheck source=tests/_lib/git-sandbox.sh
source "$ROOT/tests/_lib/git-sandbox.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh stub: unexpected call: $*" >&2
touch "${GH_CALLED_MARK:-/dev/null}"
exit 99
STUB
chmod +x "$TMP/bin/gh"

# Identity for the script's own rebase (committer) as well as fixture commits.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export PIPELINE_BASE_BRANCH=main
export PIPELINE_REPO=fake/repo
export GH_CALLED_MARK="$TMP/gh-called"
export REBASE_CHECK_VIEW_JSON='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'

# make_fixture <name> <base-edit> <feature-edit>
#   f.txt has 10 lines; <base-edit>/<feature-edit> are sed scripts applied on
#   main (pushed after the feature branch is cut) and on the feature branch.
#   Empty <base-edit> edits g.txt on main instead (no overlap).
make_fixture() {
  local name="$1" base_edit="$2" feat_edit="$3"
  local d="$TMP/$name"
  mkdir -p "$d/main"
  git init -q --bare "$d/origin.git"
  git_init_sandbox "$d/main"
  git -C "$d/main" checkout -q -b main
  seq 1 10 > "$d/main/f.txt"; printf 'g\n' > "$d/main/g.txt"
  git -C "$d/main" add f.txt g.txt
  git -C "$d/main" commit -q -m base
  git -C "$d/main" remote add origin "$d/origin.git"
  git -C "$d/main" push -q origin main 2>/dev/null
  git -C "$d/main" worktree add -q -b feature/x "$d/wt" main 2>/dev/null
  sed -i "$feat_edit" "$d/wt/f.txt"
  git -C "$d/wt" commit -q -am feature
  git -C "$d/wt" push -q -u origin feature/x 2>/dev/null
  if [ -n "$base_edit" ]; then
    sed -i "$base_edit" "$d/main/f.txt"
  else
    printf 'g2\n' >> "$d/main/g.txt"
  fi
  git -C "$d/main" commit -q -am "base edit"
  git -C "$d/main" push -q origin main 2>/dev/null
}

run() { # <args...> -> $TMP/out (stdout), $TMP/err (stderr), RC
  RC=0
  env PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$@" > "$TMP/out" 2> "$TMP/err" || RC=$?
}

scenario "S1: no overlap + MERGEABLE/CLEAN -> REBASE=skip"
make_fixture s1 "" 's/^2$/two/'
H0=$(git -C "$TMP/s1/wt" rev-parse HEAD)
run --no-gh "$TMP/s1/wt" 101
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=skip" ] \
   && [ "$(git -C "$TMP/s1/wt" rev-parse HEAD)" = "$H0" ]; then
  pass_msg "stdout exactly REBASE=skip, HEAD unchanged"
else
  fail_msg "S1 rc=$RC out=[$(cat "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S2: different hunks of f.txt -> REBASE=done"
make_fixture s2 's/^9$/nine/' 's/^2$/two/'
run --no-gh "$TMP/s2/wt" 102
LOCAL=$(git -C "$TMP/s2/wt" rev-parse HEAD)
REMOTE=$(git -C "$TMP/s2/wt" ls-remote origin refs/heads/feature/x | cut -f1)
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=done" ] \
   && [ "$LOCAL" = "$REMOTE" ] \
   && git -C "$TMP/s2/wt" merge-base --is-ancestor origin/main HEAD; then
  pass_msg "rebased onto origin/main and pushed (origin feature == HEAD)"
else
  fail_msg "S2 rc=$RC out=[$(cat "$TMP/out")] local=$LOCAL remote=$REMOTE err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S3: same line both sides -> REBASE=conflict FILES=f.txt"
make_fixture s3 's/^5$/base-five/' 's/^5$/feat-five/'
H0=$(git -C "$TMP/s3/wt" rev-parse HEAD)
run --no-gh "$TMP/s3/wt" 103
GD=$(git -C "$TMP/s3/wt" rev-parse --absolute-git-dir)
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=conflict FILES=f.txt HEAD=$H0" ] \
   && [ "$(git -C "$TMP/s3/wt" rev-parse HEAD)" = "$H0" ] \
   && [ -z "$(git -C "$TMP/s3/wt" status --porcelain)" ] \
   && [ ! -d "$GD/rebase-merge" ] && [ ! -d "$GD/rebase-apply" ]; then
  pass_msg "conflict reported, rebase aborted, worktree clean"
else
  fail_msg "S3 rc=$RC out=[$(cat "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S4: main checkout refused (exit 2, no mutation)"
H0=$(git -C "$TMP/s3/main" rev-parse HEAD)
run --no-gh "$TMP/s3/main" 104
if [ "$RC" -eq 2 ] && grep -qF 'refusing' "$TMP/err" \
   && [ "$(git -C "$TMP/s3/main" rev-parse HEAD)" = "$H0" ] \
   && [ -z "$(git -C "$TMP/s3/main" status --porcelain)" ]; then
  pass_msg "main checkout -> exit 2 'refusing', untouched"
else
  fail_msg "S4 rc=$RC err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S5: --help exit 0; no args exit 2"
run --help; H_RC=$RC
run; N_RC=$RC
if [ "$H_RC" -eq 0 ] && [ "$N_RC" -eq 2 ]; then
  pass_msg "--help rc 0, no args rc 2"
else
  fail_msg "S5 help rc=$H_RC noargs rc=$N_RC"
fi

scenario "S5b: --no-gh with REBASE_CHECK_VIEW_JSON unset defaults to MERGEABLE/CLEAN"
RC=0
env -u REBASE_CHECK_VIEW_JSON PATH="$TMP/bin:$PATH" bash "$SCRIPT" --no-gh "$TMP/s1/wt" 101 > "$TMP/out" 2> "$TMP/err" || RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=skip" ] && grep -qF 'MERGE_STATE=CLEAN' "$TMP/err"; then
  pass_msg "default view is MERGEABLE/CLEAN"
else
  fail_msg "S5b rc=$RC out=[$(cat "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S6: --no-gh made no gh call"
if [ ! -e "$GH_CALLED_MARK" ]; then
  pass_msg "gh never invoked"
else
  fail_msg "gh stub was invoked under --no-gh"
fi

scenario "S7: two commits conflicting in two files -> FILES=f.txt,g.txt"
d="$TMP/s7"
mkdir -p "$d/main"
git init -q --bare "$d/origin.git"
git_init_sandbox "$d/main"
git -C "$d/main" checkout -q -b main
seq 1 10 > "$d/main/f.txt"; printf 'g\n' > "$d/main/g.txt"
git -C "$d/main" add f.txt g.txt
git -C "$d/main" commit -q -m base
git -C "$d/main" remote add origin "$d/origin.git"
git -C "$d/main" push -q origin main 2>/dev/null
git -C "$d/main" worktree add -q -b feature/x "$d/wt" main 2>/dev/null
sed -i 's/^5$/feat-five/' "$d/wt/f.txt"
git -C "$d/wt" commit -q -am "feature f"
sed -i '1s/.*/feat-g/' "$d/wt/g.txt"
git -C "$d/wt" commit -q -am "feature g"
git -C "$d/wt" push -q -u origin feature/x 2>/dev/null
sed -i 's/^5$/base-five/' "$d/main/f.txt"
sed -i '1s/.*/base-g/' "$d/main/g.txt"
git -C "$d/main" commit -q -am "base edit"
git -C "$d/main" push -q origin main 2>/dev/null
H0=$(git -C "$d/wt" rev-parse HEAD)
run --no-gh "$d/wt" 107
GD=$(git -C "$d/wt" rev-parse --absolute-git-dir)
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=conflict FILES=f.txt,g.txt HEAD=$H0" ] \
   && [ "$(git -C "$d/wt" rev-parse HEAD)" = "$H0" ] \
   && [ -z "$(git -C "$d/wt" status --porcelain)" ] \
   && [ ! -d "$GD/rebase-merge" ] && [ ! -d "$GD/rebase-apply" ]; then
  pass_msg "both conflicting paths listed, rebase aborted, worktree clean"
else
  fail_msg "S7 rc=$RC out=[$(cat "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi


scenario "S8: rebase needed + modified tracked file -> REBASE=dirty, untouched"
make_fixture s8 's/^9$/nine/' 's/^2$/two/'
d="$TMP/s8"
printf 'X=1\n' > "$d/wt/pipeline.config"
git -C "$d/wt" add pipeline.config
git -C "$d/wt" commit -q -m "tracked config"
git -C "$d/wt" push -q origin feature/x 2>/dev/null
H0=$(git -C "$d/wt" rev-parse HEAD)
R0=$(git -C "$d/wt" ls-remote origin refs/heads/feature/x | cut -f1)
printf 'Y=2\n' >> "$d/wt/pipeline.config"
run --no-gh "$d/wt" 108
R1=$(git -C "$d/wt" ls-remote origin refs/heads/feature/x | cut -f1)
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=dirty FILES=pipeline.config HEAD=$H0" ] \
   && [ "$(git -C "$d/wt" rev-parse HEAD)" = "$H0" ] \
   && [ "$R1" = "$R0" ] \
   && [ "$(git -C "$d/wt" status --porcelain)" = " M pipeline.config" ]; then
  pass_msg "dirty reported, HEAD/remote unchanged, edit not stashed"
else
  fail_msg "S8 rc=$RC out=[$(cat "$TMP/out")] status=[$(git -C "$d/wt" status --porcelain)] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S9: rebase needed + only an untracked file -> REBASE=done"
make_fixture s9 's/^9$/nine/' 's/^2$/two/'
printf 'tmp\n' > "$TMP/s9/wt/scratch.tmp"
run --no-gh "$TMP/s9/wt" 109
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=done" ]; then
  pass_msg "untracked files do not block the rebase"
else
  fail_msg "S9 rc=$RC out=[$(cat "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "S10: git refuses the rebase (no rebase in progress) -> REBASE=error"
make_fixture s10 's/^9$/nine/' 's/^2$/two/'
d="$TMP/s10"
REAL_GIT=$(command -v git)
mkdir -p "$TMP/shim"
cat > "$TMP/shim/git" <<SHIM
#!/bin/bash
printf '%s\n' "\$*" >> "$TMP/shim.log"
is_rebase=0
for w in "\$@"; do
  [ "\$w" = rebase ] && is_rebase=1
  [ "\$w" = --abort ] && is_rebase=0 && break
done
if [ "\$is_rebase" = 1 ]; then
  echo "fatal: simulated refusal" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP/shim/git"
H0=$(git -C "$d/wt" rev-parse HEAD)
R0=$(git -C "$d/wt" ls-remote origin refs/heads/feature/x | cut -f1)
RC=0
env PATH="$TMP/shim:$TMP/bin:$PATH" bash "$SCRIPT" --no-gh "$d/wt" 110 > "$TMP/out" 2> "$TMP/err" || RC=$?
R1=$(git -C "$d/wt" ls-remote origin refs/heads/feature/x | cut -f1)
if [ "$RC" -eq 0 ] && [ "$(cat "$TMP/out")" = "REBASE=error REASON=fatal: simulated refusal" ] \
   && ! grep -qF -- '--abort' "$TMP/shim.log" \
   && [ "$(git -C "$d/wt" rev-parse HEAD)" = "$H0" ] \
   && [ "$R1" = "$R0" ]; then
  pass_msg "refused rebase reported as error, no abort, branch untouched"
else
  fail_msg "S10 rc=$RC out=[$(cat "$TMP/out")] log=[$(tr '\n' ' ' < "$TMP/shim.log")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi
echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
