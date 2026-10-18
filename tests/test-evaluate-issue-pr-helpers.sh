#!/bin/bash
set -uo pipefail
#
# tests/test-evaluate-issue-pr-helpers.sh — the scripts/evaluate-issue-pr-*.sh
# helpers that carry evaluate-issue-pr's multi-command shell behind one call.
#
#   H0  every helper answers --help with rc 0
#   C*  checks helper: a green preflight line skips the suite; every other
#       line (or CI checks disabled) runs tests locally, scoped to touched tests
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

HELPERS="fetch-plan checks"

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

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
