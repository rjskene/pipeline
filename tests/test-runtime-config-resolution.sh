#!/bin/bash
set -euo pipefail

# Asserts the shell mechanism the Boot section relies on:
# sourcing a project's pipeline.config from CWD resolves PIPELINE_*
# variables to the project-specified values, using both source forms
# the Boot one-liner supports.

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cat > "$TMP/pipeline.config" <<'EOF'
PIPELINE_REPO="acme/widget"
PIPELINE_BASE_BRANCH="foo"
PIPELINE_TEST_CMD="make test"
EOF

PASS=0
FAIL=0
FAIL_LINES=()

# Form 1: source "$(pwd)/pipeline.config" — primary form from the Boot one-liner.
out=$(cd "$TMP" && bash -c '
  source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
  echo "REPO=$PIPELINE_REPO"
  echo "BASE=$PIPELINE_BASE_BRANCH"
  echo "TEST=$PIPELINE_TEST_CMD"
')
for kv in "REPO=acme/widget" "BASE=foo" "TEST=make test"; do
  if printf '%s\n' "$out" | grep -qxF "$kv"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: form-1 missing '$kv' (got: $(printf '%s' "$out" | tr '\n' '|'))")
  fi
done

# Form 2: bare `source ./pipeline.config` — fallback form from the Boot one-liner.
out=$(cd "$TMP" && bash -c '
  source ./pipeline.config
  echo "REPO=$PIPELINE_REPO"
  echo "BASE=$PIPELINE_BASE_BRANCH"
')
for kv in "REPO=acme/widget" "BASE=foo"; do
  if printf '%s\n' "$out" | grep -qxF "$kv"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: form-2 missing '$kv' (got: $(printf '%s' "$out" | tr '\n' '|'))")
  fi
done

if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "${FAIL_LINES[@]}"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

echo "RESULT: $PASS passed, $FAIL failed"
