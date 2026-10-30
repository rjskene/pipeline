#!/bin/bash
set -uo pipefail
#
# Unit tests for issue_unexpected() in scripts/calibration-run.sh (#1523).
#
# The unexpected-files metric must count only files from the merged PR that
# CLOSES the issue (closing keyword), falling back to a head-branch match only
# when no merged PR closes it. A bare `#N` mention must not select a PR.
#
# HERMETIC: only the single function is extracted and evaluated; it reads
# $MERGED_JSON, the slate dir and (#1604) a local temp git repo as $SANDBOX.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

eval "$(sed -n '/^issue_unexpected() {/,/^}/p' "$ROOT/scripts/calibration-run.sh")"
if declare -f issue_unexpected >/dev/null 2>&1; then
  pass_msg "issue_unexpected extracted from calibration-run.sh"
else
  fail_msg "issue_unexpected could not be extracted (empty sed range)"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

mkdir -p "$TMP/slate"
printf 'a.sh\nb.sh\n' > "$TMP/slate/expected-files.txt"

check() {
  local label="$1" want="$2" got
  got="$(issue_unexpected 420 "$TMP/slate")"
  if [ "$got" = "$want" ]; then
    pass_msg "$label (=$got)"
  else
    fail_msg "$label: want $want, got '$got'"
  fi
}

MENTION='{"number":2,"body":"Builds on #420, see #422. Fixes #429","headRefName":"feature/y","files":[{"path":"c.sh"},{"path":"d.sh"}]}'

# (a) closing PR on-list; a mentioning PR's files must not count.
MERGED_JSON="[{\"number\":1,\"body\":\"Closes #420\",\"headRefName\":\"feature/x\",\"files\":[{\"path\":\"a.sh\"},{\"path\":\"b.sh\"}]},$MENTION]"
check "(a) mentioning PR ignored when a closing PR exists" 0

# (b) closing PR with one extra file.
MERGED_JSON="[{\"number\":1,\"body\":\"Closes #420\",\"headRefName\":\"feature/x\",\"files\":[{\"path\":\"a.sh\"},{\"path\":\"b.sh\"},{\"path\":\"z.sh\"}]},$MENTION]"
check "(b) closing PR extra file counted, mention ignored" 1

# (c) case-insensitive keyword variants.
MERGED_JSON='[{"number":1,"body":"fixes #420","headRefName":"feature/x","files":[{"path":"a.sh"},{"path":"z.sh"}]}]'
check "(c) 'fixes #420' selects" 1
MERGED_JSON='[{"number":1,"body":"RESOLVED #420","headRefName":"feature/x","files":[{"path":"a.sh"},{"path":"z.sh"}]}]'
check "(c) 'RESOLVED #420' selects" 1

# (d) branch fallback when no PR carries a closing keyword.
MERGED_JSON='[{"number":3,"body":"see #420","headRefName":"feature/420-slug","files":[{"path":"a.sh"},{"path":"b.sh"},{"path":"z.sh"}]}]'
check "(d) head-branch fallback selects" 1

# (e) bare mention only, branch not named for the issue.
MERGED_JSON='[{"number":4,"body":"see #420","headRefName":"feature/y","files":[{"path":"c.sh"}]}]'
check "(e) bare mention does not select" 0

# (f) digit boundary (regression guard): #4201 / feature/4201-x must not select 420.
MERGED_JSON='[{"number":5,"body":"Closes #4201","headRefName":"feature/4201-x","files":[{"path":"c.sh"}]}]'
check "(f) #4201 does not select issue 420" 0

# --- merge-commit source (#1604) -------------------------------------------
# Since #1602 stacks overlapping PRs, GitHub's PR file list carries the
# stacked predecessor's files. The count must come from the merge commit's
# first-parent diff in the sandbox clone instead.
source "$ROOT/tests/_lib/git-sandbox.sh"
REPO="$TMP/repo"
mkdir -p "$REPO"
git_init_sandbox "$REPO"
git -C "$REPO" checkout -q -b main
echo base > "$REPO/base.txt"
git -C "$REPO" add base.txt && git -C "$REPO" commit -q -m base
git -C "$REPO" checkout -q -b pred
echo p > "$REPO/p.sh"
git -C "$REPO" add p.sh && git -C "$REPO" commit -q -m pred
git -C "$REPO" checkout -q main && git -C "$REPO" merge -q --no-ff -m "merge pred" pred
git -C "$REPO" checkout -q -b succ pred
echo a > "$REPO/a.sh"
git -C "$REPO" add a.sh && git -C "$REPO" commit -q -m succ
git -C "$REPO" checkout -q main && git -C "$REPO" merge -q --no-ff -m "merge succ" succ
M="$(git -C "$REPO" rev-parse HEAD)"
SANDBOX="$REPO"

# (i) GitHub-style stacked list (a.sh + predecessor's p.sh); merge diff = a.sh.
MERGED_JSON="[{\"number\":6,\"body\":\"Closes #420\",\"headRefName\":\"feature/succ\",\"mergeCommit\":{\"oid\":\"$M\"},\"files\":[{\"path\":\"a.sh\"},{\"path\":\"p.sh\"}]}]"
check "(i) stacked predecessor file excluded via merge-commit diff" 0

# (ii) unreachable oid falls back to the GitHub list, with a stderr note.
MERGED_JSON="[{\"number\":6,\"body\":\"Closes #420\",\"headRefName\":\"feature/succ\",\"mergeCommit\":{\"oid\":\"0000000000000000000000000000000000000000\"},\"files\":[{\"path\":\"a.sh\"},{\"path\":\"p.sh\"}]}]"
check "(ii) unreachable merge commit falls back to GitHub file list" 1
issue_unexpected 420 "$TMP/slate" >/dev/null 2>"$TMP/err"
if grep -qF "calib: unexpected-files for #420 from GitHub file list" "$TMP/err"; then
  pass_msg "(ii) fallback prints stderr note"
else
  fail_msg "(ii) fallback stderr note missing: '$(cat "$TMP/err")'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
