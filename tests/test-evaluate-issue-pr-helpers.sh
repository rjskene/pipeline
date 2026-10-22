#!/bin/bash
set -uo pipefail
#
# tests/test-evaluate-issue-pr-helpers.sh — the scripts/evaluate-issue-pr-*.sh
# helpers that carry evaluate-issue-pr's multi-command shell behind one call.
#
#   H0  every helper answers --help with rc 0
#   C*  checks helper: a green preflight line (bare `PREFLIGHT=ok ...` or the
#       fullsend `PREFLIGHT issue=#N PREFLIGHT=ok ...` shape) skips the suite;
#       every other line (or CI checks disabled) runs tests locally, scoped to
#       touched tests
#   D*  diff helper: PR_NUM=<n> then the diff; no PR -> STOP line, rc 1
#   R*  rebase-check helper: REBASE=skip only on MERGEABLE + CLEAN|UNSTABLE
#       with no file changed on both sides since the merge-base
#
# `gh` is a PATH stub; fixtures live under one mktemp -d.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj/tests"

# gh stub: `pr diff <n> --name-only` prints $STUB_NAMES; `pr diff <n>` prints
# a canned diff; `pr list` prints $STUB_PR; `pr view` prints $STUB_VIEW.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "pr diff")
    case " $* " in
      *" --name-only "*) [ -n "${STUB_NAMES:-}" ] && printf '%s\n' "$STUB_NAMES"; exit 0 ;;
      *) echo "diff --git a/x b/x STUB-DIFF"; exit 0 ;;
    esac ;;
  "pr list") printf '%s\n' "${STUB_PR:-}"; exit 0 ;;
  "pr view") printf '%s\n' "${STUB_VIEW:-}"; exit 0 ;;
esac
echo "gh stub: unrecognized call: $*" >&2
exit 2
STUB
chmod +x "$TMP/bin/gh"

printf '%s\n' '#!/bin/bash' 'echo TOUCHED-RAN' > "$TMP/proj/tests/test-touched.sh"

HELPERS="fetch-plan checks diff rebase-check interdiff"

scenario "H0: --help"
for h in $HELPERS; do
  f="$ROOT/scripts/evaluate-issue-pr-$h.sh"
  if [ -f "$f" ] && bash "$f" --help >/dev/null 2>&1; then
    pass_msg "evaluate-issue-pr-$h.sh --help rc 0"
  else
    fail_msg "evaluate-issue-pr-$h.sh missing or --help rc != 0"
  fi
done

# run_checks <preflight-line> [env...] — runs the checks helper from the
# fixture project; stdout+stderr land in $TMP/out.
run_checks() {
  local line="$1"; shift
  ( cd "$TMP/proj" && env PATH="$TMP/bin:$PATH" PIPELINE_REPO=fake/repo PIPELINE_BASE_BRANCH=main \
      PIPELINE_TEST_CMD='echo SUITE-RAN' "$@" \
      bash "$ROOT/scripts/evaluate-issue-pr-checks.sh" 123 --preflight "$line" ) > "$TMP/out" 2>&1
}
out_has() { grep -qF -- "$1" "$TMP/out"; }

scenario "C1: green preflight line skips the local suite"
run_checks 'PREFLIGHT=ok REASON=none' STUB_NAMES='tests/test-touched.sh'
if out_has 'CI: green rollup' && ! out_has 'TOUCHED-RAN' && ! out_has 'SUITE-RAN'; then
  pass_msg "REASON=none -> green-rollup skip line, no test run"
else
  fail_msg "REASON=none did not skip: $(tr '\n' ' ' < "$TMP/out")"
fi
if out_has 'typecheck: skipped (PIPELINE_TYPECHECK_CMD unset)'; then
  pass_msg "typecheck skipped when PIPELINE_TYPECHECK_CMD unset"
else
  fail_msg "typecheck skip line missing"
fi

scenario "C2: negative control — ci-pending runs the touched test"
run_checks 'PREFLIGHT=ok REASON=ci-pending' STUB_NAMES='tests/test-touched.sh'
if ! out_has 'CI: green rollup' && out_has 'TOUCHED-RAN' && ! out_has 'SUITE-RAN'; then
  pass_msg "REASON=ci-pending -> touched test ran, suite not"
else
  fail_msg "REASON=ci-pending fallback wrong: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "C3: CI checks disabled falls back even on a green line"
run_checks 'PREFLIGHT=ok REASON=mergeable' STUB_NAMES='tests/test-touched.sh' PIPELINE_CI_CHECK_ENABLED=false
if ! out_has 'CI: green rollup' && out_has 'TOUCHED-RAN'; then
  pass_msg "PIPELINE_CI_CHECK_ENABLED=false -> local touched-test run"
else
  fail_msg "CI-disabled fallback wrong: $(tr '\n' ' ' < "$TMP/out")"
fi

for c in 'C1b|none' 'C1c|mergeable'; do
  id=${c%%|*}; reason=${c##*|}
  scenario "$id: fullsend-prefixed REASON=$reason line skips the local suite"
  run_checks "PREFLIGHT issue=#12 PREFLIGHT=ok REASON=$reason PR=123 FIXED=none" STUB_NAMES='tests/test-touched.sh'
  if out_has 'CI: green rollup' && ! out_has 'TOUCHED-RAN' && ! out_has 'SUITE-RAN'; then
    pass_msg "prefixed REASON=$reason -> green-rollup skip line, no test run"
  else
    fail_msg "prefixed REASON=$reason did not skip: $(tr '\n' ' ' < "$TMP/out")"
  fi
done

for c in 'C2b|ok REASON=ci-pending' 'C2c|block REASON=none'; do
  id=${c%%|*}; rest=${c#*|}
  scenario "$id: negative control — prefixed PREFLIGHT=$rest falls through"
  run_checks "PREFLIGHT issue=#12 PREFLIGHT=$rest PR=123 FIXED=none" STUB_NAMES='tests/test-touched.sh'
  if ! out_has 'CI: green rollup' && out_has 'TOUCHED-RAN'; then
    pass_msg "prefixed PREFLIGHT=$rest -> touched test ran"
  else
    fail_msg "prefixed PREFLIGHT=$rest fallback wrong: $(tr '\n' ' ' < "$TMP/out")"
  fi
done

scenario "C4: no touched tests -> full PIPELINE_TEST_CMD"
run_checks 'PREFLIGHT=ok REASON=no-ci' STUB_NAMES='scripts/x.sh'
if out_has 'SUITE-RAN' && ! out_has 'TOUCHED-RAN'; then
  pass_msg "no touched tests -> PIPELINE_TEST_CMD ran"
else
  fail_msg "no-touched fallback wrong: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "C5: typecheck runs when PIPELINE_TYPECHECK_CMD is set"
run_checks 'PREFLIGHT=ok REASON=none' PIPELINE_TYPECHECK_CMD='echo TYPECHECK-RAN'
if out_has 'TYPECHECK-RAN'; then pass_msg "typecheck command ran"; else fail_msg "typecheck command did not run"; fi

scenario "C6: the checks helper never reads the rollup"
if grep -vE '^[[:space:]]*#' "$ROOT/scripts/evaluate-issue-pr-checks.sh" 2>/dev/null | grep -qF 'statusCheckRollup'; then
  fail_msg "checks helper queries statusCheckRollup (the CI-wait hook would wedge)"
else
  pass_msg "checks helper issues no statusCheckRollup query"
fi

# ---------------------------------------------------------------------------
# Git fixture: a bare origin, a work clone on a feature branch that edits
# a.txt, and a second clone that advances the base.
G() { git -c user.email=t@example.com -c user.name=t "$@"; }
git init -q --bare "$TMP/origin.git"
G clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
G -C "$TMP/work" checkout -q -b main
printf 'a\n' > "$TMP/work/a.txt"; printf 'b\n' > "$TMP/work/b.txt"; printf 'c\n' > "$TMP/work/c.txt"
G -C "$TMP/work" add a.txt b.txt c.txt
G -C "$TMP/work" commit -q -m base
G -C "$TMP/work" push -q origin main 2>/dev/null
G -C "$TMP/work" checkout -q -b feature/x
printf 'a2\n' > "$TMP/work/a.txt"
G -C "$TMP/work" commit -q -am feature
G clone -q -b main "$TMP/origin.git" "$TMP/other" 2>/dev/null
advance_base() { # <file>
  printf 'changed\n' >> "$TMP/other/$1"
  G -C "$TMP/other" commit -q -am "base edits $1"
  G -C "$TMP/other" push -q origin main 2>/dev/null
}

run_in_work() { # <script> [args...] — env via the caller's exports
  local script="$1"; shift
  ( cd "$TMP/work" && env PATH="$TMP/bin:$PATH" PIPELINE_REPO=fake/repo PIPELINE_BASE_BRANCH=main \
      bash "$ROOT/scripts/evaluate-issue-pr-$script.sh" "$@" ) > "$TMP/out" 2>&1
}

scenario "D1: diff helper prints PR_NUM then the diff"
D_RC=0; STUB_PR=77 run_in_work diff || D_RC=$?
if [ "$D_RC" -eq 0 ] && [ "$(head -1 "$TMP/out")" = "PR_NUM=77" ] && out_has 'STUB-DIFF'; then
  pass_msg "PR_NUM=77 + diff"
else
  fail_msg "diff helper output wrong (rc=$D_RC): $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "D2: no open PR -> STOP line, rc 1"
D_RC=0; STUB_PR='' run_in_work diff || D_RC=$?
if [ "$D_RC" -eq 1 ] && out_has 'No open PR found for branch feature/x.' && ! out_has 'STUB-DIFF'; then
  pass_msg "no PR -> 'No open PR found for branch feature/x.' rc 1"
else
  fail_msg "no-PR path wrong (rc=$D_RC): $(tr '\n' ' ' < "$TMP/out")"
fi

CLEAN_VIEW='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'

scenario "R1: MERGEABLE/CLEAN, base advanced on an unrelated file -> skip"
advance_base c.txt
STUB_VIEW="$CLEAN_VIEW" run_in_work rebase-check 123
if out_has 'REBASE=skip' && out_has 'OVERLAP=none'; then
  pass_msg "advanced base alone is not a reason to rebase"
else
  fail_msg "expected REBASE=skip OVERLAP=none: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "R2: negative control — CONFLICTING -> needed"
STUB_VIEW='{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY"}' run_in_work rebase-check 123
if out_has 'REBASE=needed' && out_has 'MERGEABLE=CONFLICTING'; then
  pass_msg "CONFLICTING -> REBASE=needed"
else
  fail_msg "expected REBASE=needed on CONFLICTING: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "R3: negative control — MERGEABLE/CLEAN + a file changed on both sides -> needed"
advance_base a.txt
STUB_VIEW="$CLEAN_VIEW" run_in_work rebase-check 123
if out_has 'REBASE=needed' && out_has 'OVERLAP=a.txt'; then
  pass_msg "base overlap on a.txt -> REBASE=needed"
else
  fail_msg "expected REBASE=needed OVERLAP=a.txt: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "R4: the rebase-check helper reads mergeability, never the rollup"
RB="$ROOT/scripts/evaluate-issue-pr-rebase-check.sh"
if [ -f "$RB" ] && grep -qF -- '--json mergeable,mergeStateStatus' "$RB" && ! grep -qF 'statusCheckRollup' "$RB"; then
  pass_msg "rebase-check queries mergeable,mergeStateStatus only"
else
  fail_msg "rebase-check helper missing the mergeability query or reads the rollup"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
