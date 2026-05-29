#!/bin/bash
set -euo pipefail

# Regression-guard: every script introduced for the dogfood local marketplace
# (issue #611) must be (a) executable and (b) start with a recognised bash
# shebang. Would have failed if Tasks 1/2 forgot `chmod +x` or shipped a script
# without a `#!/usr/bin/env bash` (or `#!/bin/bash`) shebang.
#
# Coverage (4 paths x 2 assertions = 8 assertions):
#   - scripts/setup-dogfood-local.sh
#   - scripts/dogfood-mode.sh
#   - scripts/consumer-mode.sh
#   - dev/hooks/dogfood-refresh.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PATHS=(
  "scripts/setup-dogfood-local.sh"
  "scripts/dogfood-mode.sh"
  "scripts/consumer-mode.sh"
  "dev/hooks/dogfood-refresh.sh"
)

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SHEBANG_RE='^#!(/usr/bin/env bash|/bin/bash)$'

for rel in "${PATHS[@]}"; do
  abs="$REPO_ROOT/$rel"

  if [ ! -f "$abs" ]; then
    fail_msg "$rel exists"
    fail_msg "$rel has recognised bash shebang"
    continue
  fi

  # 1. Executable bit set.
  if [ -x "$abs" ]; then
    pass_msg "$rel is executable"
  else
    fail_msg "$rel is executable"
  fi

  # 2. First line matches a recognised bash shebang.
  first_line="$(head -n 1 "$abs")"
  if [[ "$first_line" =~ $SHEBANG_RE ]]; then
    pass_msg "$rel has recognised bash shebang ($first_line)"
  else
    fail_msg "$rel has recognised bash shebang (got: $first_line)"
  fi
done

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
