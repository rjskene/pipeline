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

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
