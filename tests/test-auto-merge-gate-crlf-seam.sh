#!/bin/bash
# Issue #1158 — CRLF-jq seam over auto-merge-gate.sh.
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. The gate
# reads `mergeable=$(echo "$rollup" | jq -r '.mergeable')` (L135) and
# `mergestate=$(echo "$rollup" | jq -r '.mergeStateStatus')` (L140) and compares
# them against the CR-free literals MERGEABLE / CLEAN. Under CRLF jq
# `mergeable="MERGEABLE\r"`, so `[ "$mergeable" != "MERGEABLE" ]` is TRUE and the
# gate returns `block-mergeable` for EVERY green PR — auto-merge is dead on a
# Windows host (fails safe, but never fires).
#
# Model: tests/test-auto-merge-gate-empty-base.sh (gh stub: MERGEABLE/CLEAN,
# Approved verdict, baseRefName=staging). The shared fake-jq seam is LAYERED on
# top of the gh stub so both the gh-embedded gojq (CR-free) and the external jq
# (CR-appending) are exercised the way a Windows host sees them.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"
HARNESS="${ROOT}/tests/_lib/auto-merge-gate-harness.sh"
SEAM_LIB="${ROOT}/tests/_lib/crlf-jq-seam.sh"

for f in "$HELPER" "$HARNESS" "$SEAM_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file missing: $f"
    exit 1
  fi
done

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SEAM_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh shim — green on every axis: labels empty, verdict Approved, base=staging,
# CI SUCCESS, mergeable MERGEABLE, mergeStateStatus CLEAN.
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
  *"pr view"*"--json statusCheckRollup"*)
    printf '%s' '{"statusCheckRollup":[{"name":"x","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

# Layer the fake CRLF jq into the SAME bin dir (resolves real jq now, before we
# prepend $TMP/bin to PATH, then shadows it for the gate run).
if ! make_crlf_jq_bin "$TMP/bin"; then
  echo "FAIL: CRLF-seam fake-jq setup failed (non-vacuity guard)"
  exit 1
fi

export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
source "$HARNESS"

FAILED=0

STDOUT="$TMP/stdout"
STDERR="$TMP/stderr"

set +e
(
  export PIPELINE_REPO="test/repo"
  export PIPELINE_BASE_BRANCH="staging"
  unset MANUAL_MERGE
  unset NO_VERDICT
  auto_merge_should_fire 100 200
) > "$STDOUT" 2> "$STDERR"
RC=$?
set -e 2>/dev/null || true

OUT="$(cat "$STDOUT")"

echo "CRLF-seam — green PR under Windows CRLF jq (expect stdout=green, rc 0):"

if printf '%s' "$OUT" | grep -qx 'green'; then
  echo "  PASS: gate stdout == green (mergeable/mergeStateStatus survive CRLF jq)"
else
  echo "  FAIL: gate stdout != green (got '$OUT'; rc=$RC) — CRLF poisoned MERGEABLE/CLEAN compare"
  echo "    stderr: $(cat "$STDERR")"
  FAILED=$((FAILED+1))
fi

if printf '%s' "$OUT" | grep -qE 'block-mergeable|block-mergestate'; then
  echo "  FAIL: gate emitted a block-mergeable/block-mergestate token under CRLF jq"
  FAILED=$((FAILED+1))
else
  echo "  PASS: gate did NOT emit block-mergeable/block-mergestate"
fi

if [ "$RC" -eq 0 ]; then
  echo "  PASS: gate rc == 0"
else
  echo "  FAIL: gate rc != 0 (got $RC)"
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
