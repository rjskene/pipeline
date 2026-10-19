#!/bin/bash
# Issue #1545 — auto-merge-gate.sh settles an UNKNOWN mergeable before deciding.
#
# GitHub computes mergeability lazily; the read right after the base advances
# answers UNKNOWN, which used to become an immediate block-mergeable. The gate
# now re-reads `--json mergeable,mergeStateStatus` (never the rollup) up to
# PIPELINE_MERGEABILITY_POLL_MAX total reads, the rollup read counting as #1.
#
#   G1 UNKNOWN on the rollup read, settles on poll 1 -> green, rc 0
#   G2 never settles, POLL_MAX=2                      -> block-mergeable, rc 1, 1 poll
#   G3 settles to MERGEABLE/BLOCKED                   -> block-mergestate
#   G4 static: the poll query is mergeable,mergeStateStatus (no rollup field)
#
# Model: tests/test-auto-merge-gate-crlf-seam.sh (gh shim green on every axis).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"
HARNESS="${ROOT}/tests/_lib/auto-merge-gate-harness.sh"

for f in "$HELPER" "$HARNESS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file missing: $f"
    exit 1
  fi
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh shim — green on every axis except mergeability: the rollup read answers
# SUCCESS + UNKNOWN/UNKNOWN; the poll arm (matched BEFORE the rollup arm) logs
# each call to $CALLS and answers UNKNOWN for the first $UNKNOWN_READS calls,
# then $SETTLED_VIEW.
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '\n'
    ;;
  *"pr view"*"--json baseRefName"*)
    printf 'staging\n'
    ;;
  *"pr view"*"--json comments"*)
    printf '%s' "## Evaluation

**Verdict:** Approved
"
    ;;
  *"pr view"*"--json mergeable,mergeStateStatus"*)
    echo "$ALL_ARGS" >> "$CALLS"
    n=$(wc -l < "$CALLS")
    if [ "$n" -le "${UNKNOWN_READS:-0}" ]; then
      printf '%s' '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
    else
      sv="${SETTLED_VIEW:-}"
      [ -n "$sv" ] || sv='{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
      printf '%s' "$sv"
    fi
    ;;
  *"pr view"*"--json statusCheckRollup"*)
    printf '%s' '{"statusCheckRollup":[{"name":"x","conclusion":"SUCCESS"}],"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN"}'
    ;;
  *"pulls/"*"/files"*)
    printf '%s\n' "modified:scripts/auto-merge-gate.sh:"
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

export PATH="$TMP/bin:$PATH"
export CALLS="$TMP/calls"

# shellcheck disable=SC1090
source "$HARNESS"

FAILED=0

# gate <env...> -> OUT, RC, POLLS
gate() {
  : > "$CALLS"
  set +e
  OUT=$(
    export PIPELINE_REPO="test/repo"
    export PIPELINE_BASE_BRANCH="staging"
    export PIPELINE_MERGEABILITY_POLL_SECS=0
    unset MANUAL_MERGE NO_VERDICT PIPELINE_MERGEABILITY_POLL_MAX
    for kv in "$@"; do export "${kv?}"; done
    auto_merge_should_fire 100 200 2>"$TMP/stderr"
  )
  RC=$?
  set -e 2>/dev/null || true
  set +e
  POLLS=$(wc -l < "$CALLS" | tr -d ' ')
}

check() { # <label> <cond-result 0|1> <detail>
  if [ "$2" -eq 0 ]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1 ($3)"
    FAILED=$((FAILED+1))
  fi
}

echo "G1 — UNKNOWN on the rollup read, settles on poll 1 -> green:"
gate UNKNOWN_READS=0
[ "$OUT" = green ] && [ "$RC" -eq 0 ]; check "stdout green, rc 0" $? "out='$OUT' rc=$RC polls=$POLLS"

echo "G2 — never settles, POLL_MAX=2 -> block-mergeable after 1 poll:"
gate UNKNOWN_READS=99 PIPELINE_MERGEABILITY_POLL_MAX=2
[ "$OUT" = block-mergeable ] && [ "$RC" -eq 1 ] && [ "$POLLS" = 1 ]; check "block-mergeable, rc 1, polls 1" $? "out='$OUT' rc=$RC polls=$POLLS"

echo "G3 — settles to MERGEABLE/BLOCKED -> block-mergestate:"
gate UNKNOWN_READS=0 'SETTLED_VIEW={"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}'
[ "$OUT" = block-mergestate ] && [ "$RC" -eq 1 ]; check "block-mergestate, rc 1" $? "out='$OUT' rc=$RC polls=$POLLS"

echo "G4 — static: poll query reads mergeability only:"
grep -qE -- '--json mergeable,mergeStateStatus( |$)' "$HELPER"; check "gate polls --json mergeable,mergeStateStatus" $? "query not found in $HELPER"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
