#!/bin/bash
# Test the auto-merge greenlight gate helper:
#   - 16-row truth matrix over (verdict, ci, mergeable, mergeStateStatus)
#   - 2 opt-out cases (MANUAL_MERGE env + manual-merge label)
#   - 3 argv-ordering cases for the loop-based --manual-merge parser
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- gh shim ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
# Args are scanned to pick which fixture env var to emit.
ALL_ARGS="$*"
echo "gh $ALL_ARGS" >> "${CALL_LOG:-/dev/null}"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '%s\n' ${GH_LABELS:-}
    ;;
  *"pr view"*"--json baseRefName"*)
    printf '%s\n' "${GH_BASE_REF:-staging}"
    ;;
  *"pr view"*"--json comments"*"Evaluation"*)
    printf '%s' "${GH_EVAL_BODY:-}"
    ;;
  *"pr view"*"--json statusCheckRollup,mergeable,mergeStateStatus"*)
    printf '%s' "${GH_ROLLUP:-}"
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CALL_LOG="$TMP/calls.log"
export PIPELINE_REPO="test/repo"
export PIPELINE_BASE_BRANCH="staging"

# shellcheck disable=SC1090
source "$HELPER"

FAILED=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name -> $actual"
  else
    echo "  FAIL: $name expected=$expected actual=$actual"
    FAILED=$((FAILED+1))
  fi
}

run_gate() {
  # Captures helper output (the gate-reason token).
  auto_merge_should_fire 1 1 2>/dev/null
}

make_rollup() {
  local ci="$1" mergeable="$2" mergestate="$3"
  local checks="[]"
  case "$ci" in
    success) checks='[{"name":"x","conclusion":"SUCCESS"}]' ;;
    failure) checks='[{"name":"x","conclusion":"FAILURE"}]' ;;
  esac
  printf '{"statusCheckRollup":%s,"mergeable":"%s","mergeStateStatus":"%s"}' \
    "$checks" "$mergeable" "$mergestate"
}

make_eval() {
  local verdict="$1"
  printf '## Evaluation\n\n**Verdict:** %s\n' "$verdict"
}

echo "=== 16-row greenlight matrix ==="
for verdict in Approved Flagged; do
  for ci in success failure; do
    for mergeable in MERGEABLE CONFLICTING; do
      for mergestate in CLEAN BLOCKED; do
        unset MANUAL_MERGE
        export GH_LABELS=""
        export GH_EVAL_BODY="$(make_eval "$verdict")"
        export GH_ROLLUP="$(make_rollup "$ci" "$mergeable" "$mergestate")"
        actual="$(run_gate)"

        if [ "$verdict" = "Approved" ] && [ "$ci" = "success" ] \
           && [ "$mergeable" = "MERGEABLE" ] && [ "$mergestate" = "CLEAN" ]; then
          expected="green"
        elif [ "$verdict" != "Approved" ]; then
          expected="block-verdict"
        elif [ "$ci" != "success" ]; then
          expected="block-ci"
        elif [ "$mergeable" != "MERGEABLE" ]; then
          expected="block-mergeable"
        else
          expected="block-mergestate"
        fi
        check "$verdict/$ci/$mergeable/$mergestate" "$expected" "$actual"
      done
    done
  done
done

echo "=== Opt-out: MANUAL_MERGE env ==="
export GH_LABELS=""
export GH_EVAL_BODY="$(make_eval Approved)"
export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
export MANUAL_MERGE=1
check "MANUAL_MERGE=1 short-circuits" "block-flag" "$(run_gate)"
unset MANUAL_MERGE

echo "=== Opt-out: manual-merge label ==="
export GH_LABELS="manual-merge"
check "manual-merge label short-circuits" "block-label" "$(run_gate)"
export GH_LABELS=""

echo "=== argv ordering: --manual-merge consumed from any position ==="
# parse_manual_merge_argv args... -> sets MANUAL_MERGE=1 and prints remaining
# args (one per line) to stdout.
for argv in "--manual-merge 122 123" "122 123 --manual-merge" "122 --manual-merge 123"; do
  unset MANUAL_MERGE
  REMAINING_FILE="$TMP/remaining.txt"
  # Run in current shell (no subshell) so MANUAL_MERGE assignment persists.
  # shellcheck disable=SC2086
  parse_manual_merge_argv $argv > "$REMAINING_FILE"
  REMAINING=$(cat "$REMAINING_FILE")
  check "parser MANUAL_MERGE for [$argv]" "1" "${MANUAL_MERGE:-0}"
  check "parser remaining for [$argv]" "122
123" "$REMAINING"
done

echo "=== NO_VERDICT mode (hotfix --auto-merge: CI-only, verdict skipped) ==="
# (a) NO_VERDICT=1 + Flagged verdict + green rollup => green (verdict ignored).
unset MANUAL_MERGE
export GH_LABELS=""
export GH_BASE_REF="staging"
export GH_EVAL_BODY="$(make_eval Flagged)"
export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
export NO_VERDICT=1
check "NO_VERDICT skips Flagged verdict" "green" "$(run_gate)"

# (b) NO_VERDICT=1 + no eval comment at all + green => green.
export GH_EVAL_BODY=""
check "NO_VERDICT skips missing eval comment" "green" "$(run_gate)"

# (c) NO_VERDICT=1 + CI failure => block-ci (CI still enforced).
export GH_EVAL_BODY="$(make_eval Flagged)"
export GH_ROLLUP="$(make_rollup failure MERGEABLE CLEAN)"
check "NO_VERDICT still enforces CI" "block-ci" "$(run_gate)"

# (d) NO_VERDICT=1 + CONFLICTING => block-mergeable.
export GH_ROLLUP="$(make_rollup success CONFLICTING CLEAN)"
check "NO_VERDICT still enforces mergeable" "block-mergeable" "$(run_gate)"

# (e) NO_VERDICT=1 + BLOCKED mergestate => block-mergestate.
export GH_ROLLUP="$(make_rollup success MERGEABLE BLOCKED)"
check "NO_VERDICT still enforces mergeStateStatus" "block-mergestate" "$(run_gate)"

# (f) NO_VERDICT=1 + base mismatch => block-base-mismatch.
export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
export GH_BASE_REF="main"
check "NO_VERDICT still enforces base" "block-base-mismatch" "$(run_gate)"
export GH_BASE_REF="staging"

# (g) NO_VERDICT=1 + manual-merge label => block-label.
export GH_LABELS="manual-merge"
check "NO_VERDICT still honors manual-merge label" "block-label" "$(run_gate)"
export GH_LABELS=""

# (h) MANUAL_MERGE=1 NO_VERDICT=1 => block-flag (env opt-out precedes).
export MANUAL_MERGE=1
check "NO_VERDICT still honors MANUAL_MERGE env" "block-flag" "$(run_gate)"
unset MANUAL_MERGE
unset NO_VERDICT

# (i) Regression: default mode (NO_VERDICT unset) + Flagged => block-verdict.
export GH_EVAL_BODY="$(make_eval Flagged)"
export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
check "default mode still blocks on Flagged verdict" "block-verdict" "$(run_gate)"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
