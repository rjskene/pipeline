#!/bin/bash
set -uo pipefail
# Per #492: pins the "Granularity scope decision" subsection in
# docs/release-cadence.md. Asserts the section exists, names the three rejected
# architectural alternatives in literal form, and carries the exact verdict line.
#
# The verdict-line assertion is a DELIBERATE brittle literal: any paraphrase of
# `per-PR granularity is the contract; sub-commit granularity is **out of scope**`
# breaks this test on purpose — that sentence IS the scope decision.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOC="$REPO_ROOT/docs/release-cadence.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$DOC" ]; then
  fail_msg "docs/release-cadence.md exists"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# (i) the section heading
if grep -qF '### Granularity scope decision' "$DOC"; then
  pass_msg "contains '### Granularity scope decision' heading"
else
  fail_msg "contains '### Granularity scope decision' heading"
fi

# (ii) the three rejected alternatives, each named in literal form
for alt in 'manifest mode' 'custom walker' 'richer commit-message walker'; do
  if grep -qF "$alt" "$DOC"; then
    pass_msg "names rejected alternative '$alt'"
  else
    fail_msg "names rejected alternative '$alt'"
  fi
done

# (iii) the exact pinned verdict line
if grep -qF 'per-PR granularity is the contract; sub-commit granularity is **out of scope**' "$DOC"; then
  pass_msg "contains the exact pinned verdict line"
else
  fail_msg "contains the exact pinned verdict line"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
