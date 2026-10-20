#!/bin/bash
set -uo pipefail
#
# tests/test-evaluate-issue-pr-interdiff.sh — scripts/evaluate-issue-pr-interdiff.sh:
# the pre- vs post-rebase net-change interdiff behind the REEVAL=rebase-fix
# delta-scoped re-evaluation. First stdout line is exactly one of
# INTERDIFF=none | INTERDIFF=files=<csv> | INTERDIFF=unknown reason=<r>.
#
#   (a) base inserts a line at the TOP of f.txt, feature edits lower down,
#       clean rebase                              -> INTERDIFF=none
#       (pins the hunk-header line-number normalization; the inserted line is
#       `0` so git's funcname heuristic leaves the hunk context unchanged)
#   (b) same-line conflict resolved to a third value -> INTERDIFF=files=f.txt,
#       the resolved line in the following stdout
#   (c) as (b) plus an edit to unrelated h.txt during resolution
#                                                  -> INTERDIFF=files=f.txt,h.txt
#   (d) OLD = all-zero sha                         -> INTERDIFF=unknown reason=old-head-unreachable
#   (e) --help rc 0; no args rc 2
#
# Fixtures: a bare origin, a main checkout (git_init_sandbox) and a feature
# checkout via `git worktree add`; the script runs from the feature worktree.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/evaluate-issue-pr-interdiff.sh"
# shellcheck source=tests/_lib/git-sandbox.sh
source "$ROOT/tests/_lib/git-sandbox.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export GIT_EDITOR=true
export PIPELINE_BASE_BRANCH=main
export PIPELINE_REPO=fake/repo

# make_fixture <name> <base-edit> <feature-edit> — f.txt holds `seq 1 10`,
# h.txt holds `h`; the sed scripts run on main (pushed after the feature branch
# is cut) and on the feature branch.
make_fixture() {
  local name="$1" base_edit="$2" feat_edit="$3"
  local d="$TMP/$name"
  mkdir -p "$d/main"
  git init -q --bare "$d/origin.git"
  git_init_sandbox "$d/main"
  git -C "$d/main" checkout -q -b main
  seq 1 10 > "$d/main/f.txt"; printf 'h\n' > "$d/main/h.txt"
  git -C "$d/main" add f.txt h.txt
  git -C "$d/main" commit -q -m base
  git -C "$d/main" remote add origin "$d/origin.git"
  git -C "$d/main" push -q origin main 2>/dev/null
  git -C "$d/main" worktree add -q -b feature/x "$d/wt" main 2>/dev/null
  sed -i "$feat_edit" "$d/wt/f.txt"
  git -C "$d/wt" commit -q -am feature
  sed -i "$base_edit" "$d/main/f.txt"
  git -C "$d/main" commit -q -am "base edit"
  git -C "$d/main" push -q origin main 2>/dev/null
  git -C "$d/wt" log --oneline -1 >/dev/null && echo "  fixture $name: feature log ok"
}

run() { # <wt> <old-sha> -> $TMP/out, $TMP/err, RC
  RC=0
  ( cd "$1" && bash "$SCRIPT" "$2" ) > "$TMP/out" 2> "$TMP/err" || RC=$?
}
first_line() { head -1 "$TMP/out"; }

scenario "(a) line shift only -> INTERDIFF=none"
make_fixture a '1i 0' 's/^8$/feat-eight/'
OLD=$(git -C "$TMP/a/wt" rev-parse HEAD)
git -C "$TMP/a/wt" rebase -q origin/main >/dev/null 2>&1
run "$TMP/a/wt" "$OLD"
if [ "$RC" -eq 0 ] && [ "$(first_line)" = "INTERDIFF=none" ]; then
  pass_msg "first line exactly INTERDIFF=none"
else
  fail_msg "(a) rc=$RC out=[$(tr '\n' ' ' < "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

# resolve_conflict <wt> [extra] — rebase onto origin/main, resolve f.txt line 5
# to `resolved-five`; with `extra`, also edit h.txt during the resolution.
resolve_conflict() {
  local wt="$1" extra="${2:-}"
  git -C "$wt" rebase origin/main >/dev/null 2>&1
  seq 1 10 | sed 's/^5$/resolved-five/' > "$wt/f.txt"
  git -C "$wt" add f.txt
  if [ -n "$extra" ]; then
    printf 'h-amended\n' > "$wt/h.txt"
    git -C "$wt" add h.txt
  fi
  git -C "$wt" rebase --continue >/dev/null 2>&1
}

scenario "(b) conflict resolved to a third value -> INTERDIFF=files=f.txt"
make_fixture b 's/^5$/base-five/' 's/^5$/feat-five/'
OLD=$(git -C "$TMP/b/wt" rev-parse HEAD)
resolve_conflict "$TMP/b/wt"
run "$TMP/b/wt" "$OLD"
if [ "$RC" -eq 0 ] && [ "$(first_line)" = "INTERDIFF=files=f.txt" ] \
   && tail -n +2 "$TMP/out" | grep -qF 'resolved-five'; then
  pass_msg "INTERDIFF=files=f.txt, resolved line in the interdiff"
else
  fail_msg "(b) rc=$RC out=[$(tr '\n' ' ' < "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "(c) resolution also edits h.txt -> INTERDIFF=files=f.txt,h.txt"
make_fixture c 's/^5$/base-five/' 's/^5$/feat-five/'
OLD=$(git -C "$TMP/c/wt" rev-parse HEAD)
resolve_conflict "$TMP/c/wt" extra
run "$TMP/c/wt" "$OLD"
if [ "$RC" -eq 0 ] && [ "$(first_line)" = "INTERDIFF=files=f.txt,h.txt" ]; then
  pass_msg "INTERDIFF=files=f.txt,h.txt"
else
  fail_msg "(c) rc=$RC out=[$(tr '\n' ' ' < "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "(d) unreachable old head -> INTERDIFF=unknown reason=old-head-unreachable"
run "$TMP/a/wt" 0000000000000000000000000000000000000000
if [ "$RC" -eq 0 ] && [ "$(first_line)" = "INTERDIFF=unknown reason=old-head-unreachable" ]; then
  pass_msg "unknown reason=old-head-unreachable, rc 0"
else
  fail_msg "(d) rc=$RC out=[$(tr '\n' ' ' < "$TMP/out")] err=[$(tr '\n' ' ' < "$TMP/err")]"
fi

scenario "(e) --help rc 0; no args rc 2"
RC=0; bash "$SCRIPT" --help >/dev/null 2>&1 || RC=$?; H_RC=$RC
RC=0; ( cd "$TMP/a/wt" && bash "$SCRIPT" ) >/dev/null 2>&1 || RC=$?; N_RC=$RC
if [ "$H_RC" -eq 0 ] && [ "$N_RC" -eq 2 ]; then
  pass_msg "--help rc 0, no args rc 2"
else
  fail_msg "(e) help rc=$H_RC noargs rc=$N_RC"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
