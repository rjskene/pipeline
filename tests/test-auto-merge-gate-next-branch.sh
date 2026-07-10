#!/bin/bash
# Unit test: auto_merge_should_fire must be next-branch aware (#1148).
#
# A next-routed issue (carries PIPELINE_NEXT_LABEL, default `next`, or the
# legacy `next-major-release` alias) whose PR targets $PIPELINE_NEXT_BRANCH
# must NOT block-base-mismatch — the base check must accept
# baseRefName == $PIPELINE_NEXT_BRANCH in addition to
# baseRefName == $PIPELINE_BASE_BRANCH when the issue is next-routed.
#
# A non-next issue whose PR targets $PIPELINE_NEXT_BRANCH must STILL
# block-base-mismatch (#295/#801 defense-in-depth is preserved).
#
# Companion to tests/test-auto-merge-gate-base-mismatch.sh (mismatch case)
# and tests/test-auto-merge-greenlight.sh (16-row truth matrix). Mirrors the
# gh-stub pattern from both.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"
HARNESS="${ROOT}/tests/_lib/auto-merge-gate-harness.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi
if [ ! -f "$HARNESS" ]; then
  echo "FAIL: ${HARNESS} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
for util in grep head awk jq; do
  if [ -x "/usr/bin/$util" ]; then
    ln -sf "/usr/bin/$util" "$TMP/bin/$util"
  elif [ -x "/bin/$util" ]; then
    ln -sf "/bin/$util" "$TMP/bin/$util"
  fi
done

# gh shim — baseRefName returns "next"; issue labels controlled by
# $GH_ISSUE_LABELS (JSON array string, e.g. '["next"]' or '[]').
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '%s\n' "${GH_ISSUE_LABELS:-[]}"
    ;;
  *"pr view"*"--json baseRefName"*)
    printf '%s\n' "${GH_BASE_REF:-next}"
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

export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="test/repo"
export PIPELINE_BASE_BRANCH="staging"
export PIPELINE_NEXT_BRANCH="next"
export PIPELINE_NEXT_LABEL="next"
unset MANUAL_MERGE

# shellcheck disable=SC1090
source "$HARNESS"

FAILED=0

run_gate() {
  auto_merge_should_fire 100 200 2>/dev/null
}

# --- Case 1: next-labelled issue, PR targets `next` -> must NOT block-base-mismatch ---
export GH_ISSUE_LABELS='["next"]'
export GH_BASE_REF="next"
actual="$(run_gate)"
if [ "$actual" = "block-base-mismatch" ]; then
  echo "  FAIL: next-labelled issue + PR base=next incorrectly blocked (got $actual)"
  FAILED=$((FAILED+1))
else
  echo "  PASS: next-labelled issue + PR base=next did not block-base-mismatch (got $actual)"
fi

# --- Case 1b: legacy alias label `next-major-release` also accepted ---
export GH_ISSUE_LABELS='["next-major-release"]'
export GH_BASE_REF="next"
actual="$(run_gate)"
if [ "$actual" = "block-base-mismatch" ]; then
  echo "  FAIL: next-major-release-labelled issue + PR base=next incorrectly blocked (got $actual)"
  FAILED=$((FAILED+1))
else
  echo "  PASS: next-major-release-labelled issue + PR base=next did not block-base-mismatch (got $actual)"
fi

# --- Case 2: non-next issue, PR targets `next` -> must STILL block-base-mismatch ---
export GH_ISSUE_LABELS='[]'
export GH_BASE_REF="next"
actual="$(run_gate)"
if [ "$actual" = "block-base-mismatch" ]; then
  echo "  PASS: non-next issue + PR base=next still block-base-mismatch"
else
  echo "  FAIL: non-next issue + PR base=next expected block-base-mismatch, got $actual"
  FAILED=$((FAILED+1))
fi

# --- Case 3: PR targets $PIPELINE_BASE_BRANCH -> unaffected, still passes base check ---
export GH_ISSUE_LABELS='[]'
export GH_BASE_REF="staging"
actual="$(run_gate)"
if [ "$actual" = "block-base-mismatch" ]; then
  echo "  FAIL: PR base=staging (== PIPELINE_BASE_BRANCH) incorrectly blocked"
  FAILED=$((FAILED+1))
else
  echo "  PASS: PR base=staging (== PIPELINE_BASE_BRANCH) did not block-base-mismatch (got $actual)"
fi

# --- Case 4: next-labelled issue, PR targets some OTHER branch -> still blocks ---
export GH_ISSUE_LABELS='["next"]'
export GH_BASE_REF="some-other-branch"
actual="$(run_gate)"
if [ "$actual" = "block-base-mismatch" ]; then
  echo "  PASS: next-labelled issue + PR base=some-other-branch still block-base-mismatch"
else
  echo "  FAIL: next-labelled issue + PR base=some-other-branch expected block-base-mismatch, got $actual"
  FAILED=$((FAILED+1))
fi

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
