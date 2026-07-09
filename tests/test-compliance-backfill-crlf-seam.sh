#!/bin/bash
# Issue #1162 — CRLF-jq seam over compliance-backfill.sh (non-dry-run live-gh read).
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. In the
# NON-dry-run per-PR loop the script reads
#   pr_num=$(printf '%s' "$pr" | jq -r '.number')          (L259)
# and feeds it to load_pr_commits "$pr_num" / load_pr_files "$pr_num" (fixtures:
# commits-<N>.json / files-<N>.json). Under CRLF jq pr_num="101\r", so those
# loaders look for `commits-101\r.json` / `files-101\r.json`, miss them, and
# skip EVERY eligible PR — `--emit-rows-json` collapses to an empty array
# (0 rows). Same class as #1158.
#
# The fixture WARN (`fixture commits-<N>.json missing`) is emitted on the
# loader's stderr but SUPPRESSED by the `2>/dev/null` on the caller (L272-273),
# so it never reaches this test's captured stderr. The observable, non-vacuous
# signal is therefore the ROW COUNT, isolated against a real-jq BASELINE run
# that proves the fixture + --emit-rows-json harness is sound (i.e. 0 rows under
# the seam is the CR bug, not a setup error).
#
# Model: tests/test-auto-merge-gate-crlf-seam.sh (shared fake-jq seam) +
# tests/test-compliance-backfill.sh (fixture / --emit-rows-json harness).
#
# EXPECTED (before the fix): seam row count == 0  -> this test FAILS.
# EXPECTED (after  the fix): L259 gains `| tr -d '\r'`, seam row count == 8.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/compliance-backfill.sh"
FIXTURE="${ROOT}/tests/fixtures/compliance-backfill"
SEAM_LIB="${ROOT}/tests/_lib/crlf-jq-seam.sh"

for f in "$HELPER" "$SEAM_LIB" "$FIXTURE/prs.json"; do
  if [ ! -e "$f" ]; then
    echo "FAIL: required path missing: $f"
    exit 1
  fi
done

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SEAM_LIB"

# Resolve the REAL jq NOW, before the fake CRLF jq shadows PATH.
REAL_JQ="$(command -v jq)"
if [ -z "$REAL_JQ" ]; then
  echo "FAIL: real jq not found on PATH"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

if ! make_crlf_jq_bin "$TMP/bin"; then
  echo "FAIL: CRLF-seam fake-jq setup failed (non-vacuity guard)"
  exit 1
fi

FAILED=0

# --- baseline: real jq, NO seam — proves the harness is sound -------------
BASELINE_ROWS="$(bash "$HELPER" --fixture "$FIXTURE" --emit-rows-json 2>/dev/null | "$REAL_JQ" 'length' 2>/dev/null || echo -1)"

echo "CRLF-seam — compliance-backfill non-dry-run pr_num read under Windows CRLF jq:"

if [ "$BASELINE_ROWS" -ge 1 ] 2>/dev/null; then
  echo "  PASS: baseline (real jq) emits $BASELINE_ROWS rows — fixture/harness sound"
else
  echo "  FAIL: baseline (real jq) emitted $BASELINE_ROWS rows — setup error, not the CR bug"
  FAILED=$((FAILED+1))
fi

# --- seam run: fake CRLF jq shadows the script's internal jq --------------
SEAM_OUT="$(PATH="$TMP/bin:$PATH" bash "$HELPER" --fixture "$FIXTURE" --emit-rows-json 2>/dev/null)"
SEAM_ROWS="$(printf '%s' "$SEAM_OUT" | "$REAL_JQ" 'length' 2>/dev/null || echo -1)"

# THE regression assertion: a CR-poisoned pr_num makes load_pr_commits /
# load_pr_files miss every fixture, so the seam run collapses to 0 rows.
# Fails NOW; passes once L259 strips the trailing CR.
if [ "$SEAM_ROWS" -ge 1 ] 2>/dev/null; then
  echo "  PASS: seam (CRLF jq) emits $SEAM_ROWS rows — pr_num survives CRLF jq"
else
  echo "  FAIL: seam (CRLF jq) emitted $SEAM_ROWS rows (expected >= 1) — CR-poisoned pr_num missed every commits-<N>.json/files-<N>.json fixture"
  FAILED=$((FAILED+1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
