#!/bin/bash
set -euo pipefail

# Tests for scripts/finish-manual-merge.sh — the operator helper that replays
# the auto-merge gate's post-merge bookkeeping (flip pr-open→merged, drop
# manual-merge, close the issue with a `Merged via PR #<PR>` note) for the
# hand-merge recovery path. See #655: `Closes #N` in the PR body is defeated by
# the `staging` base branch, so a hand `gh pr merge` leaves the issue open and
# the labels wedged at `pr-open[,manual-merge]`. The helper is idempotent so a
# re-run on already-corrected state is a no-op.
#
# The gh CLI is replaced by a PATH-resident shim (modeled on
# tests/test-auto-close-trackers.sh) that records every invocation to
# $SHIM_LOG and simulates the two failure modes the helper must absorb with
# `|| true`:
#   - `gh issue edit --remove-label X` exits non-zero when X is absent from
#     $LABELS (real gh returns a 422 on absent-label removal).
#   - `gh issue close` exits non-zero when $STATE is already CLOSED.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/finish-manual-merge.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Shim:
# - gh issue edit <N> [--add-label A] [--remove-label B]...
#     -> record full invocation; for each --remove-label X not present in
#        $LABELS (comma-separated), exit 1 (simulate gh's absent-label 422).
# - gh issue close <N> --comment <body>
#     -> record; if $STATE == CLOSED, exit 1 (simulate already-closed).
# - anything else -> record, exit 0.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_LOG"

sub1="${1:-}"; sub2="${2:-}"
case "$sub1 $sub2" in
  "issue edit")
    # Collect --remove-label targets and check against $LABELS.
    have=",${LABELS:-},"
    rc=0
    while [ $# -gt 0 ]; do
      if [ "$1" = "--remove-label" ]; then
        tgt="$2"
        case "$have" in
          *",$tgt,"*) : ;;          # present → ok
          *) rc=1 ;;                # absent → simulate 422
        esac
        shift 2; continue
      fi
      shift
    done
    exit "$rc"
    ;;
  "issue close")
    if [ "${STATE:-OPEN}" = "CLOSED" ]; then exit 1; fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

reset_case() {
  local case_dir="$1"
  rm -rf "$case_dir"; mkdir -p "$case_dir"
  export SHIM_LOG="$case_dir/calls.log"
  : > "$SHIM_LOG"
}

# ---- Case A: usage / arg guard ----
echo "Case A: arg guard"
inc
A="$TMP/case-a"; reset_case "$A"
if bash "$HELPER" 655 >"$A/stdout" 2>"$A/stderr"; then
  fail_msg "arg guard: helper exited 0 with only one arg; expected non-zero"
else
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qi 'usage' "$A/stderr"; then
    pass_msg "arg guard: missing PR arg exits $rc with a usage line on stderr"
  else
    fail_msg "arg guard: exit=$rc but stderr lacks a usage line"
    sed 's/^/    /' "$A/stderr"
  fi
fi

# ---- Case B: wedged (pr-open,manual-merge / OPEN) → corrected + closed ----
echo "Case B: wedged → corrected"
inc
B="$TMP/case-b"; reset_case "$B"
# Full pipeline label set present so the helper's combined flip strips them all
# without tripping the absent-label 422 fallback.
export LABELS="pr-open,manual-merge,plan-approved,in-progress,priority/P1"
export STATE="OPEN"
if bash "$HELPER" 655 4242 >"$B/stdout" 2>"$B/stderr"; then
  ok=1
  grep -qF -- '--add-label merged' "$SHIM_LOG"            || { ok=0; fail_msg "wedged: no --add-label merged recorded"; }
  grep -qF -- '--remove-label pr-open' "$SHIM_LOG"        || { ok=0; fail_msg "wedged: no --remove-label pr-open recorded"; }
  grep -qF -- '--remove-label manual-merge' "$SHIM_LOG"   || { ok=0; fail_msg "wedged: no --remove-label manual-merge recorded"; }
  # Helper-backed full strip-set (issue #866): wider labels are now stripped too.
  grep -qF -- '--remove-label plan-approved' "$SHIM_LOG"  || { ok=0; fail_msg "wedged: no --remove-label plan-approved recorded (helper full strip-set)"; }
  grep -qF -- '--remove-label priority/P1' "$SHIM_LOG"    || { ok=0; fail_msg "wedged: no --remove-label priority/P1 recorded (helper full strip-set)"; }
  grep -qE 'issue close 655' "$SHIM_LOG"                  || { ok=0; fail_msg "wedged: no issue close 655 recorded"; }
  grep -qF 'Merged via PR #4242' "$SHIM_LOG"              || { ok=0; fail_msg "wedged: close comment lacks 'Merged via PR #4242'"; }
  [ "$ok" = "1" ] && pass_msg "wedged: full strip-set (incl. plan-approved/priority/P1) + close with 'Merged via PR #4242'"
  [ "$ok" = "1" ] || sed 's/^/    /' "$SHIM_LOG"
else
  rc=$?
  fail_msg "wedged: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$B/stderr"
fi

# ---- Case C: idempotency — labels already correct (merged / CLOSED) ----
echo "Case C: idempotent on already-correct labels"
inc
C="$TMP/case-c"; reset_case "$C"
export LABELS="merged"     # pr-open / manual-merge absent → remove-label 422s
export STATE="CLOSED"      # close also 422s
if bash "$HELPER" 655 4242 >"$C/stdout" 2>"$C/stderr"; then
  pass_msg "idempotent labels: re-run on merged/CLOSED exits 0 (absent-label removals absorbed)"
else
  rc=$?
  fail_msg "idempotent labels: helper exited $rc; expected 0 (|| true must absorb 422s)"
  echo "    stderr:"; sed 's/^/      /' "$C/stderr"
fi

# ---- Case D: idempotency — issue already closed ----
echo "Case D: idempotent on already-closed issue"
inc
D="$TMP/case-d"; reset_case "$D"
export LABELS="pr-open,manual-merge"   # labels present so only close 422s
export STATE="CLOSED"
if bash "$HELPER" 655 4242 >"$D/stdout" 2>"$D/stderr"; then
  pass_msg "idempotent close: re-close of an already-closed issue exits 0"
else
  rc=$?
  fail_msg "idempotent close: helper exited $rc; expected 0 (|| true must absorb already-closed)"
  echo "    stderr:"; sed 's/^/      /' "$D/stderr"
fi

# ---- Case E: missing PIPELINE_REPO and no --repo → documented error ----
echo "Case E: missing PIPELINE_REPO → required-error"
inc
E="$TMP/case-e"; reset_case "$E"
if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" SHIM_LOG="$E/calls.log" \
     LABELS="pr-open,manual-merge" STATE="OPEN" \
     bash "$HELPER" 655 4242 >"$E/stdout" 2>"$E/stderr"; then
  fail_msg "missing PIPELINE_REPO: helper exited 0 — expected non-zero"
  echo "    stderr:"; sed 's/^/      /' "$E/stderr"
else
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qiF 'PIPELINE_REPO' "$E/stderr"; then
    pass_msg "missing PIPELINE_REPO: helper exited $rc with a documented error"
  else
    fail_msg "missing PIPELINE_REPO: exit=$rc but stderr lacks the documented error"
    echo "    stderr:"; sed 's/^/      /' "$E/stderr"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
