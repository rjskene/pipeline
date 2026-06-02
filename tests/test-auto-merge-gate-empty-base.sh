#!/bin/bash
# Unit test (issue #801): auto_merge_should_fire must NOT masquerade an empty
# $PIPELINE_BASE_BRANCH as a real base divergence (block-base-mismatch).
#
# Root cause: callers source pipeline.config in one bash step and run the gate
# in a separate subshell. A non-exported PIPELINE_BASE_BRANCH is then empty in
# the gate's process, and the base check (`[ "$base" != "$PIPELINE_BASE_BRANCH" ]`)
# fired a spurious block-base-mismatch.
#
# Fix (1 + 3): the gate self-sources pipeline.config when the base is empty
# (recovery), and returns 2 with a diagnostic if it is STILL empty afterward
# (fail-safe — a hard config error, not a base decision token).
#
# Case A — hard config error: empty base + no discoverable config => rc 2,
#   stderr names PIPELINE_BASE_BRANCH, stdout NOT block-base-mismatch.
# Case B — self-source recovery: empty base + discoverable config (with
#   PIPELINE_BASE_BRANCH=staging matching the shim's baseRefName) => rc 0,
#   stdout == green.

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

# gh shim — baseRefName returns "staging"; verdict Approved; CI/mergeable/state green.
# So once the gate has a recovered base of "staging" it reaches green.
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

export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1090
source "$HARNESS"

FAILED=0

# ---------------------------------------------------------------------------
# Case A — hard config error: empty base, no discoverable pipeline.config.
# Run from a cwd that is a fresh git toplevel with NO pipeline.config so the
# recovery (pwd / git toplevel) finds nothing and the fail-safe returns 2.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/noconfig"
( cd "$TMP/noconfig" && git init -q . )

A_STDOUT="$TMP/a_stdout"
A_STDERR="$TMP/a_stderr"

set +e
(
  cd "$TMP/noconfig"
  export PIPELINE_REPO="test/repo"
  unset PIPELINE_BASE_BRANCH
  unset PIPELINE_PROJECT_ROOT
  unset MANUAL_MERGE
  auto_merge_should_fire 100 200
) > "$A_STDOUT" 2> "$A_STDERR"
A_RC=$?
set -e

A_OUT="$(cat "$A_STDOUT")"
A_ERR="$(cat "$A_STDERR")"

echo "Case A — empty base + no config (expect rc 2, no block-base-mismatch):"
if [ "$A_RC" -eq 2 ]; then
  echo "  PASS: rc == 2 (got $A_RC)"
else
  echo "  FAIL: rc != 2 (got $A_RC)"
  FAILED=$((FAILED+1))
fi
if printf '%s' "$A_OUT" | grep -qx 'block-base-mismatch'; then
  echo "  FAIL: stdout emitted block-base-mismatch (must not masquerade empty base as divergence)"
  echo "    stdout: $A_OUT"
  FAILED=$((FAILED+1))
else
  echo "  PASS: stdout did NOT emit block-base-mismatch"
fi
if printf '%s' "$A_ERR" | grep -q 'PIPELINE_BASE_BRANCH'; then
  echo "  PASS: stderr names PIPELINE_BASE_BRANCH"
else
  echo "  FAIL: stderr missing PIPELINE_BASE_BRANCH diagnostic"
  echo "    stderr: $A_ERR"
  FAILED=$((FAILED+1))
fi

# ---------------------------------------------------------------------------
# Case B — self-source recovery: empty base in env, but a discoverable
# pipeline.config under PIPELINE_PROJECT_ROOT supplies PIPELINE_BASE_BRANCH.
# The gate self-sources it, recovers "staging", and reaches green.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/proj"
cat > "$TMP/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="test/repo"
PIPELINE_BASE_BRANCH="staging"
CFG

B_STDOUT="$TMP/b_stdout"
B_STDERR="$TMP/b_stderr"

set +e
(
  export PIPELINE_REPO="test/repo"
  export PIPELINE_PROJECT_ROOT="$TMP/proj"
  unset PIPELINE_BASE_BRANCH
  unset MANUAL_MERGE
  auto_merge_should_fire 100 200
) > "$B_STDOUT" 2> "$B_STDERR"
B_RC=$?
set -e

B_OUT="$(cat "$B_STDOUT")"

echo "Case B — empty base + discoverable config (expect rc 0, green):"
if [ "$B_RC" -eq 0 ]; then
  echo "  PASS: rc == 0 (got $B_RC)"
else
  echo "  FAIL: rc != 0 (got $B_RC)"
  echo "    stderr: $(cat "$B_STDERR")"
  FAILED=$((FAILED+1))
fi
if printf '%s' "$B_OUT" | grep -qx 'green'; then
  echo "  PASS: stdout == green (self-sourced + recovered staging)"
else
  echo "  FAIL: stdout != green"
  echo "    stdout: $B_OUT"
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
