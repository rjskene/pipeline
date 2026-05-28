#!/bin/bash
set -uo pipefail

# Regression guard for issue #579: consume the check-config-drift.sh punch-list
# by documenting genuinely-undocumented PIPELINE_* vars in pipeline.config.example
# and peeling their corresponding allowlist entries.
#
# Three assertions:
#   1. `bash scripts/check-config-drift.sh` exits 0 against the post-PR tree
#      (defense against a future regression silently reintroducing UNDOCUMENTED
#      entries that the allowlist no longer suppresses).
#   2. Each DECLARED_VAR appears in pipeline.config.example as `^\s*#?\s*VAR=`
#      (live or commented-template — both count as documentation per the lint).
#   3. Each DECLARED_VAR is NOT present as a non-comment exact-match line in
#      tests/config-drift-allowlist.txt (the whole point of #579: declared vars
#      get peeled from the allowlist so the allowlist contains only permanent
#      false-positive entries — concat-prefixes, per-spawn injected vars,
#      internal-state markers, test fixtures).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
ALLOWLIST="$ROOT/tests/config-drift-allowlist.txt"
LINT="$ROOT/scripts/check-config-drift.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXAMPLE" "$ALLOWLIST" "$LINT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: required file not found: $f" >&2
    exit 1
  fi
done

# Vars #579 documents in pipeline.config.example and peels from the allowlist.
DECLARED_VARS=(
  PIPELINE_ANALYZE_MIN_AGE_HOURS
  PIPELINE_CI_FIX_CONTEXT
  PIPELINE_QUEUE_DRY_RUN
  PIPELINE_REPO_CONSUMERS
)

# --- Assertion 1: lint is green ---
inc
if bash "$LINT" >/dev/null 2>&1; then
  pass_msg "check-config-drift.sh exits 0"
else
  fail_msg "check-config-drift.sh exits non-zero — see \`bash $LINT\` for details"
fi

# --- Assertion 2: each declared var appears in pipeline.config.example ---
for var in "${DECLARED_VARS[@]}"; do
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$EXAMPLE"; then
    pass_msg "example: $var declared in pipeline.config.example"
  else
    fail_msg "example: $var missing from pipeline.config.example"
  fi
done

# --- Assertion 3: each declared var is peeled from the allowlist ---
#
# The allowlist parser strips `#`-comments and leading/trailing whitespace, then
# treats anything ending in `_` as a concat-prefix wildcard and anything else as
# an exact-match token. Mirror that here: capture the bare-entry list into a
# variable (avoids SIGPIPE under `set -o pipefail` when grep -q exits early),
# then grep for a bare-line exact match against each DECLARED_VAR.
ENTRIES="$(
  while IFS= read -r raw; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    printf '%s\n' "$line"
  done < "$ALLOWLIST"
)"

for var in "${DECLARED_VARS[@]}"; do
  inc
  if printf '%s\n' "$ENTRIES" | grep -qxF "$var"; then
    fail_msg "allowlist: $var still present in tests/config-drift-allowlist.txt — peel it"
  else
    pass_msg "allowlist: $var peeled from tests/config-drift-allowlist.txt"
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
