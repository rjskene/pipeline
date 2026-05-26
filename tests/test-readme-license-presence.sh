#!/bin/bash
set -uo pipefail

# Verifies the README professionalization deliverables for #502:
#   (a) LICENSE exists at repo root with MIT text and the locked copyright line.
#   (b) README.md opens with the new title block (# Pipeline) and the three-badge row
#       (MIT license, CI workflow status, plugin pill).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LICENSE_FILE="$REPO_ROOT/LICENSE"
README_FILE="$REPO_ROOT/README.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# --- (a) LICENSE presence + content ----------------------------------------

if [ -f "$LICENSE_FILE" ]; then
  pass_msg "LICENSE exists at repo root"
else
  fail_msg "LICENSE exists at repo root"
fi

if [ -f "$LICENSE_FILE" ] && grep -q "MIT License" "$LICENSE_FILE"; then
  pass_msg "LICENSE contains 'MIT License'"
else
  fail_msg "LICENSE contains 'MIT License'"
fi

if [ -f "$LICENSE_FILE" ] && grep -q "2026 Ryan John Skene" "$LICENSE_FILE"; then
  pass_msg "LICENSE contains '2026 Ryan John Skene'"
else
  fail_msg "LICENSE contains '2026 Ryan John Skene'"
fi

# --- (b) README title block + badges ---------------------------------------

if [ ! -f "$README_FILE" ]; then
  fail_msg "README.md exists"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

first_non_empty="$(awk 'NF{print; exit}' "$README_FILE")"
if [ "$first_non_empty" = "# Pipeline" ]; then
  pass_msg "README first non-empty line is '# Pipeline'"
else
  fail_msg "README first non-empty line is '# Pipeline' (got: $first_non_empty)"
fi

if grep -q "License: MIT" "$README_FILE"; then
  pass_msg "README contains MIT license badge text"
else
  fail_msg "README contains MIT license badge text"
fi

if grep -q "actions/workflows/ci.yml/badge.svg" "$README_FILE"; then
  pass_msg "README contains CI workflow badge URL"
else
  fail_msg "README contains CI workflow badge URL"
fi

if grep -q "plugin-claude--pipeline" "$README_FILE"; then
  pass_msg "README contains plugin badge pill"
else
  fail_msg "README contains plugin badge pill"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
