#!/bin/bash
set -u

# Tests for scripts/classification-freshness.sh — the batched freshness
# helper introduced by issue #342. The helper replaces the per-issue
# `gh issue view` loop in skills/run/SKILL.md (step 1) with a single
# `gh issue list --json number,updatedAt,comments` round-trip whose
# output is filtered down to the supplied issue numbers and labelled
# `fresh|stale` based on the `## Classification` comment's createdAt
# vs. the issue's updatedAt.
#
# The gh CLI is replaced by a PATH-resident shim that returns a fixture
# JSON payload describing four open issues:
#   #10 → Classification createdAt newer than updatedAt   → fresh
#   #11 → Classification createdAt older than updatedAt   → stale
#   #12 → no Classification comment at all                → stale
#   #99 → fresh-classified but NOT in the requested set   → filtered out

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/classification-freshness.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Shim: only the single `gh issue list --json number,updatedAt,comments`
# call is supported. Any other invocation prints an error and exits 99.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${SHIM_LOG:-/dev/null}"
# Strip --jq <expr> if present (the helper does jq client-side).
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"
case "${1:-} ${2:-}" in
  "issue list")
    cat "${FIXTURE_FILE:-/dev/null}"
    ;;
  *)
    echo "shim: unhandled gh invocation: $*" >&2
    exit 99
    ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"
export SHIM_LOG="$TMP/gh.log"

# Fixture: four issues with curated timestamps. updatedAt is ISO-8601 UTC.
FIXTURE="$TMP/issues.json"
cat > "$FIXTURE" <<'JSON'
[
  {
    "number": 10,
    "updatedAt": "2026-05-20T10:00:00Z",
    "comments": [
      {"body": "random chatter", "createdAt": "2026-05-20T10:05:00Z"},
      {"body": "## Classification\n\nrecommended_path: B", "createdAt": "2026-05-20T11:00:00Z"}
    ]
  },
  {
    "number": 11,
    "updatedAt": "2026-05-20T15:00:00Z",
    "comments": [
      {"body": "## Classification\n\nrecommended_path: A", "createdAt": "2026-05-19T09:00:00Z"}
    ]
  },
  {
    "number": 12,
    "updatedAt": "2026-05-21T08:00:00Z",
    "comments": [
      {"body": "no classification here", "createdAt": "2026-05-21T08:30:00Z"}
    ]
  },
  {
    "number": 99,
    "updatedAt": "2026-05-19T09:00:00Z",
    "comments": [
      {"body": "## Classification\n\nrecommended_path: C", "createdAt": "2026-05-19T10:00:00Z"}
    ]
  }
]
JSON
export FIXTURE_FILE="$FIXTURE"

if [ ! -x "$HELPER" ]; then
  fail_msg "helper script $HELPER does not exist or is not executable"
  inc
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

# --- Test 1: happy path emits exactly three TSV lines for {10,11,12}.
inc
OUT=$(bash "$HELPER" 10 11 12 2>"$TMP/stderr") || {
  fail_msg "happy-path exit non-zero (stderr: $(cat "$TMP/stderr"))"
  OUT=""
}
LINE_COUNT=$(printf '%s\n' "$OUT" | grep -c '^[0-9]')
if [ "$LINE_COUNT" -eq 3 ]; then
  pass_msg "happy path emits exactly 3 lines"
else
  fail_msg "happy path emits $LINE_COUNT lines (want 3); got:\n$OUT"
fi

# --- Test 2: issue #10 is fresh.
inc
ROW10=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="10"')
VERDICT10=$(printf '%s\n' "$ROW10" | awk -F'\t' '{print $4}')
if [ "$VERDICT10" = "fresh" ]; then
  pass_msg "issue #10 is fresh"
else
  fail_msg "issue #10 verdict='$VERDICT10' (want fresh); row=$ROW10"
fi

# --- Test 3: issue #11 is stale (Classification older than updatedAt).
inc
ROW11=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="11"')
VERDICT11=$(printf '%s\n' "$ROW11" | awk -F'\t' '{print $4}')
if [ "$VERDICT11" = "stale" ]; then
  pass_msg "issue #11 is stale"
else
  fail_msg "issue #11 verdict='$VERDICT11' (want stale); row=$ROW11"
fi

# --- Test 4: issue #12 is stale (no Classification comment).
inc
ROW12=$(printf '%s\n' "$OUT" | awk -F'\t' '$1=="12"')
VERDICT12=$(printf '%s\n' "$ROW12" | awk -F'\t' '{print $4}')
if [ "$VERDICT12" = "stale" ]; then
  pass_msg "issue #12 is stale (no Classification comment)"
else
  fail_msg "issue #12 verdict='$VERDICT12' (want stale); row=$ROW12"
fi

# --- Test 5: issue #99 (not in filter set) is NOT emitted.
inc
if printf '%s\n' "$OUT" | awk -F'\t' '$1=="99"' | grep -q .; then
  fail_msg "issue #99 emitted but not in filter set"
else
  pass_msg "issue #99 (not in filter set) is filtered out"
fi

# --- Test 6: zero-arg invocation exits 0 with empty stdout.
inc
EMPTY_OUT=$(bash "$HELPER" 2>"$TMP/stderr-empty")
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$EMPTY_OUT" ]; then
  pass_msg "zero-arg invocation exits 0 with empty stdout"
else
  fail_msg "zero-arg invocation rc=$RC out='$EMPTY_OUT' stderr='$(cat "$TMP/stderr-empty")'"
fi

# --- Test 7: missing PIPELINE_REPO is a hard error (non-zero exit).
inc
( unset PIPELINE_REPO; bash "$HELPER" 10 >"$TMP/out-no-repo" 2>"$TMP/err-no-repo" )
RC_NO_REPO=$?
if [ "$RC_NO_REPO" -ne 0 ]; then
  pass_msg "missing PIPELINE_REPO exits non-zero"
else
  fail_msg "missing PIPELINE_REPO did not exit non-zero (rc=$RC_NO_REPO)"
fi

# --- Test 8: gh failure surfaces as non-zero exit.
inc
(
  cat > "$TMP/bin/gh" <<'GHFAIL'
#!/bin/bash
echo "boom: simulated gh failure" >&2
exit 1
GHFAIL
  chmod +x "$TMP/bin/gh"
  bash "$HELPER" 10 >"$TMP/out-ghfail" 2>"$TMP/err-ghfail"
)
RC_FAIL=$?
if [ "$RC_FAIL" -ne 0 ]; then
  pass_msg "gh failure propagates non-zero exit"
else
  fail_msg "gh failure did NOT propagate; rc=$RC_FAIL"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
