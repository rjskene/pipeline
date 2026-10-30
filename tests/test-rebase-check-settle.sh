#!/bin/bash
set -uo pipefail
#
# tests/test-rebase-check-settle.sh — scripts/evaluate-issue-pr-rebase-check.sh
# (#1545): settle an UNKNOWN mergeability by polling before deciding, and never
# rebase a MERGEABLE PR whose branch shares no file with the advanced base
# (any mergeStateStatus except DIRTY).
#
#   S1 UNKNOWN x2 then MERGEABLE/CLEAN, unrelated base file -> skip, 3 gh calls
#   S2 same stub, base touched a file the branch changed    -> needed
#   S3 UNKNOWN forever, POLL_MAX=2                           -> needed, 2 gh calls
#   S4 MERGEABLE/BLOCKED|BEHIND + no overlap -> skip; MERGEABLE/DIRTY -> needed;
#      CONFLICTING/DIRTY -> needed
#   S5 REBASE_CHECK_VIEW_JSON=UNKNOWN view -> zero gh calls, needed (no poll)
#   S6 static: poll query is mergeable,mergeStateStatus; never the rollup
#
# Fixture: bare origin + main checkout (git_init_sandbox) + feature worktree.
# `gh` is a PATH stub that logs one line per call to $TMP/calls.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/evaluate-issue-pr-rebase-check.sh"
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

# gh stub: UNKNOWN for the first $UNKNOWN_READS calls, then $SETTLED_VIEW.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >> "$CALLS"
n=$(wc -l < "$CALLS")
if [ "$n" -le "${UNKNOWN_READS:-0}" ]; then
  printf '%s\n' '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
else
  printf '%s\n' "${SETTLED_VIEW:-}"
fi
STUB
chmod +x "$TMP/bin/gh"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.t
export PIPELINE_BASE_BRANCH=main
export PIPELINE_REPO=fake/repo
export PIPELINE_MERGEABILITY_POLL_SECS=0
unset REBASE_CHECK_VIEW_JSON PIPELINE_MERGEABILITY_POLL_MAX

# make_fixture <name> <base-file>: feature edits a.txt; main then edits <base-file>.
make_fixture() {
  local name="$1" base_file="$2"
  local d="$TMP/$name"
  mkdir -p "$d/main"
  git init -q --bare "$d/origin.git"
  git_init_sandbox "$d/main"
  git -C "$d/main" checkout -q -b main
  printf 'a\n' > "$d/main/a.txt"; printf 'c\n' > "$d/main/c.txt"
  git -C "$d/main" add a.txt c.txt
  git -C "$d/main" commit -q -m base
  git -C "$d/main" remote add origin "$d/origin.git"
  git -C "$d/main" push -q origin main 2>/dev/null
  git -C "$d/main" worktree add -q -b feature/x "$d/wt" main 2>/dev/null
  printf 'feat\n' >> "$d/wt/a.txt"
  git -C "$d/wt" commit -q -am feature
  printf 'base\n' >> "$d/main/$base_file"
  git -C "$d/main" commit -q -am "base edit"
  git -C "$d/main" push -q origin main 2>/dev/null
}

# run <wt> [env...] -> $TMP/out, RC, $TMP/calls
run() {
  local wt="$1"; shift
  : > "$TMP/calls"
  RC=0
  ( cd "$wt" && env PATH="$TMP/bin:$PATH" CALLS="$TMP/calls" "$@" bash "$SCRIPT" 123 ) \
    > "$TMP/out" 2>&1 || RC=$?
}
out_has() { grep -qF -- "$1" "$TMP/out"; }
calls() { wc -l < "$TMP/calls" | tr -d ' '; }

make_fixture nooverlap c.txt
make_fixture overlap a.txt
CLEAN='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'

scenario "S1: UNKNOWN x2 then MERGEABLE/CLEAN, unrelated base file -> skip"
run "$TMP/nooverlap/wt" UNKNOWN_READS=2 SETTLED_VIEW="$CLEAN"
if out_has 'REBASE=skip' && out_has 'OVERLAP=none' && [ "$(calls)" = 3 ]; then
  pass_msg "settled after 3 reads -> REBASE=skip OVERLAP=none"
else
  fail_msg "S1 calls=$(calls) out=[$(tr '\n' ' ' < "$TMP/out")]"
fi

scenario "S2: same stub, base changed a branch file -> needed"
run "$TMP/overlap/wt" UNKNOWN_READS=2 SETTLED_VIEW="$CLEAN"
if out_has 'REBASE=needed' && out_has 'OVERLAP=a.txt'; then
  pass_msg "overlap on a.txt -> REBASE=needed"
else
  fail_msg "S2 out=[$(tr '\n' ' ' < "$TMP/out")]"
fi

scenario "S3: UNKNOWN forever, POLL_MAX=2 -> needed after 2 reads"
run "$TMP/nooverlap/wt" UNKNOWN_READS=99 SETTLED_VIEW="$CLEAN" PIPELINE_MERGEABILITY_POLL_MAX=2
if out_has 'REBASE=needed' && out_has 'MERGEABLE=UNKNOWN' && [ "$(calls)" = 2 ]; then
  pass_msg "never settled -> fail-safe REBASE=needed, 2 gh calls"
else
  fail_msg "S3 calls=$(calls) out=[$(tr '\n' ' ' < "$TMP/out")]"
fi

scenario "S4: decision table on settled views"
for st in BLOCKED BEHIND; do
  run "$TMP/nooverlap/wt" UNKNOWN_READS=0 SETTLED_VIEW="{\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"$st\"}"
  if out_has 'REBASE=skip' && [ "$(calls)" = 1 ]; then
    pass_msg "MERGEABLE/$st + no overlap -> skip (1 read, no poll)"
  else
    fail_msg "S4 $st calls=$(calls) out=[$(tr '\n' ' ' < "$TMP/out")]"
  fi
done
run "$TMP/nooverlap/wt" UNKNOWN_READS=0 SETTLED_VIEW='{"mergeable":"MERGEABLE","mergeStateStatus":"DIRTY"}'
if out_has 'REBASE=needed'; then
  pass_msg "MERGEABLE/DIRTY -> needed"
else
  fail_msg "S4 MERGEABLE/DIRTY out=[$(tr '\n' ' ' < "$TMP/out")]"
fi
run "$TMP/nooverlap/wt" UNKNOWN_READS=0 SETTLED_VIEW='{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}'
if out_has 'REBASE=needed' && [ "$(calls)" = 1 ]; then
  pass_msg "CONFLICTING/DIRTY -> needed (1 read, no poll)"
else
  fail_msg "S4 CONFLICTING calls=$(calls) out=[$(tr '\n' ' ' < "$TMP/out")]"
fi

scenario "S5: REBASE_CHECK_VIEW_JSON bypasses the poll"
run "$TMP/nooverlap/wt" UNKNOWN_READS=0 SETTLED_VIEW="$CLEAN" \
  REBASE_CHECK_VIEW_JSON='{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
if out_has 'REBASE=needed' && [ "$(calls)" = 0 ]; then
  pass_msg "override view -> zero gh calls, REBASE=needed"
else
  fail_msg "S5 calls=$(calls) out=[$(tr '\n' ' ' < "$TMP/out")]"
fi

scenario "S6: static — mergeability query only, never the rollup"
if grep -qF -- '--json mergeable,mergeStateStatus' "$SCRIPT" && ! grep -qF 'statusCheckRollup' "$SCRIPT"; then
  pass_msg "script queries mergeable,mergeStateStatus only"
else
  fail_msg "rebase-check script missing the query or reads the rollup"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
