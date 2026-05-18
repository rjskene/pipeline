#!/bin/bash
# Regression: when jq is missing from PATH, auto_merge_should_fire must
# fail loudly (non-zero rc + stderr diagnostic) and MUST NOT emit any
# block-* or green token on stdout — tooling-defect is not a runtime
# signal.
#
# Without this guard, the gate silently emitted "block-ci" because the
# `jq -e` invocation exited 127 (command not found) inside the rollup
# check, conflating environment defect with real CI failure (#270).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

# Symlink every standard util the helper itself uses (grep, head, awk),
# but NOT jq. The helper's subshell PATH will be exactly $TMP/bin so a
# system-installed jq cannot leak through.
for util in grep head awk; do
  if [ -x "/usr/bin/$util" ]; then
    ln -sf "/usr/bin/$util" "$TMP/bin/$util"
  elif [ -x "/bin/$util" ]; then
    ln -sf "/bin/$util" "$TMP/bin/$util"
  else
    echo "FAIL: prerequisite '$util' not found in /usr/bin or /bin"
    exit 1
  fi
done

# gh shim — answers issue/pr view JSON queries. Self-contained: no jq.
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    # No labels — manual-merge label absent.
    printf '\n'
    ;;
  *"pr view"*"--json comments"*)
    # Verdict Approved so execution proceeds to the jq-dependent rollup block.
    printf '%s' "## Evaluation

**Verdict:** Approved
"
    ;;
  *"pr view"*"--json statusCheckRollup"*)
    # Content irrelevant — the helper must detect missing jq BEFORE
    # attempting to parse this payload.
    printf '%s' '{"statusCheckRollup":[],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}'
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

export PIPELINE_REPO="test/repo"

# Capture stdout/stderr/rc in a subshell whose PATH excludes jq entirely.
STDOUT_FILE="$TMP/stdout"
STDERR_FILE="$TMP/stderr"

set +e
(
  export PATH="$TMP/bin"
  unset MANUAL_MERGE

  # Precondition: jq must NOT be findable in this subshell.
  if command -v jq >/dev/null 2>&1; then
    echo "[harness] precondition broken — jq still resolvable as $(command -v jq)" >&2
    exit 88
  fi

  # shellcheck disable=SC1090
  source "$HELPER"
  auto_merge_should_fire 100 200
) > "$STDOUT_FILE" 2> "$STDERR_FILE"
rc=$?
set -e

STDOUT_CONTENT="$(cat "$STDOUT_FILE")"
STDERR_CONTENT="$(cat "$STDERR_FILE")"

if [ "$rc" -eq 88 ]; then
  echo "FAIL: $STDERR_CONTENT"
  exit 1
fi

FAILED=0

# Assertion 1: non-zero rc.
if [ "$rc" -ne 0 ]; then
  echo "  PASS: rc != 0 (got $rc)"
else
  echo "  FAIL: rc was 0 — gate must not return green when jq is missing"
  FAILED=$((FAILED+1))
fi

# Assertion 2: stderr contains the loud diagnostic marker.
if printf '%s' "$STDERR_CONTENT" | grep -q "jq is required"; then
  echo "  PASS: stderr names 'jq is required'"
else
  echo "  FAIL: stderr missing 'jq is required' marker"
  echo "    stderr: $STDERR_CONTENT"
  FAILED=$((FAILED+1))
fi

# Assertion 3: stdout MUST NOT contain any reason token.
if printf '%s' "$STDOUT_CONTENT" | grep -qE '^(green|block-ci|block-mergeable|block-mergestate|block-verdict|block-label|block-flag)$'; then
  echo "  FAIL: stdout leaked a reason token — tooling-defect should not emit one"
  echo "    stdout: $STDOUT_CONTENT"
  FAILED=$((FAILED+1))
else
  echo "  PASS: stdout emits no reason token (clean tooling-defect contract)"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
