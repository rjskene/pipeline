#!/bin/bash
# Unit test: auto_merge_should_fire must emit `block-base-mismatch` when
# the PR's baseRefName diverges from $PIPELINE_BASE_BRANCH.
#
# The token order in the gate is:
#   verdict -> base-mismatch -> ci -> mergeable -> mergestate
# so this test verifies the new check fires AFTER verdict approval but
# BEFORE the statusCheckRollup check (a green-CI / green-mergeable PR
# pointed at the wrong base must still be rejected).
#
# Defense-in-depth context: see dev/audits/295-root-cause.md. The
# upstream enforce-base-branch hook bypassed in production when stale
# rendered spawn-claude.sh emitted an unnamespaced slash command; the
# eval-time baseRefName assertion is the load-bearing zero-data-loss
# gate that catches the divergent base before merge.

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
# Pass-through symlinks for utilities the helper itself uses.
for util in grep head awk jq; do
  if [ -x "/usr/bin/$util" ]; then
    ln -sf "/usr/bin/$util" "$TMP/bin/$util"
  elif [ -x "/bin/$util" ]; then
    ln -sf "/bin/$util" "$TMP/bin/$util"
  fi
done

# gh shim — baseRefName returns "main" while everything else is green.
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '\n'
    ;;
  *"pr view"*"--json baseRefName"*)
    printf 'main\n'
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
unset MANUAL_MERGE

# shellcheck disable=SC1090
source "$HARNESS"

STDOUT_FILE="$TMP/stdout"
STDERR_FILE="$TMP/stderr"

set +e
auto_merge_should_fire 100 200 > "$STDOUT_FILE" 2> "$STDERR_FILE"
rc=$?
set -e

STDOUT_CONTENT="$(cat "$STDOUT_FILE")"

FAILED=0

# Assertion 1: rc != 0
if [ "$rc" -ne 0 ]; then
  echo "  PASS: rc != 0 (got $rc)"
else
  echo "  FAIL: rc was 0 — base mismatch must block green"
  FAILED=$((FAILED+1))
fi

# Assertion 2: stdout contains exactly `block-base-mismatch`
if printf '%s' "$STDOUT_CONTENT" | grep -qx 'block-base-mismatch'; then
  echo "  PASS: stdout == block-base-mismatch"
else
  echo "  FAIL: stdout did not contain 'block-base-mismatch'"
  echo "    stdout: $STDOUT_CONTENT"
  FAILED=$((FAILED+1))
fi

# Assertion 3: stdout MUST NOT also contain block-ci/block-mergeable/block-mergestate/green
# (verifies ordering — base-mismatch fires before those checks run).
for tok in green block-ci block-mergeable block-mergestate; do
  if printf '%s' "$STDOUT_CONTENT" | grep -qx "$tok"; then
    echo "  FAIL: stdout leaked '$tok' — base-mismatch must short-circuit before this check"
    FAILED=$((FAILED+1))
  fi
done

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
