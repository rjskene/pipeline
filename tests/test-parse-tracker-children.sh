#!/bin/bash
set -euo pipefail

# Tests for scripts/parse-tracker-children.sh — shared helper that extracts
# child issue numbers from a tracker body's `## Rollout sequence` checklist.
#
# Contract:
#   bash scripts/parse-tracker-children.sh <body-file>
#   bash scripts/parse-tracker-children.sh -          # read from stdin
# Prints one child issue number per line, in order of appearance, to stdout.
# Exits 0 always (including when no children found).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/parse-tracker-children.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# ---- Case A: body with ## Rollout sequence, mixed ASCII hyphen + en-dash ----
echo "Case A: rollout block with hyphen + en-dash"
inc
A="$TMP/body-a.md"
cat > "$A" <<'BODY'
## Context
Some prose.

## Rollout sequence

- [ ] **#101 - ascii hyphen task**
- [ ] **#102 - second task**
- [ ] **#103 — en-dash task**

## Notes
- [ ] **#999 — outside the rollout section, should be ignored**
BODY

out=$(bash "$HELPER" "$A" 2>"$TMP/err-a") || { fail_msg "Case A: exit non-zero"; cat "$TMP/err-a"; }
expected=$'101\n102\n103'
if [ "$out" = "$expected" ]; then
  pass_msg "Case A: three children parsed in order"
else
  fail_msg "Case A: expected '$expected' got '$out'"
fi

# ---- Case B: body with NO ## Rollout sequence section ----
echo "Case B: no rollout section"
inc
B="$TMP/body-b.md"
cat > "$B" <<'BODY'
## Context
- [ ] **#100 — looks like a child but not in rollout**

## Plan
some plan
BODY

if out=$(bash "$HELPER" "$B" 2>"$TMP/err-b"); then
  if [ -z "$out" ]; then
    pass_msg "Case B: empty output when no rollout section"
  else
    fail_msg "Case B: expected empty output, got '$out'"
  fi
else
  fail_msg "Case B: helper exited non-zero ($?), expected 0"
fi

# ---- Case C: rollout followed by another `## ` heading; children only from inside ----
echo "Case C: rollout terminated by next ## heading"
inc
C="$TMP/body-c.md"
cat > "$C" <<'BODY'
## Rollout sequence

- [ ] **#201 — inside**
- [ ] **#202 — inside two**

## After
- [ ] **#999 — after rollout, must NOT appear**

## Rollout sequence appendix (note: extra heading)
- [ ] **#998 — outside primary rollout**
BODY

out=$(bash "$HELPER" "$C")
expected=$'201\n202'
if [ "$out" = "$expected" ]; then
  pass_msg "Case C: only inside-rollout children parsed"
else
  fail_msg "Case C: expected '$expected' got '$out'"
fi

# ---- Case D: mixed [ ] and [x] checkbox states; both yield numbers ----
echo "Case D: mixed open and checked boxes"
inc
D="$TMP/body-d.md"
cat > "$D" <<'BODY'
## Rollout sequence

- [ ] **#301 — open**
- [x] **#302 — checked / closed already**
- [ ] **#303 — open**
BODY

out=$(bash "$HELPER" "$D")
expected=$'301\n302\n303'
if [ "$out" = "$expected" ]; then
  pass_msg "Case D: all children listed regardless of [ ] vs [x]"
else
  fail_msg "Case D: expected '$expected' got '$out'"
fi

# ---- Case E: stdin via `-` ----
echo "Case E: stdin input via -"
inc
out=$(printf '%s\n' \
  "## Rollout sequence" "" \
  "- [ ] **#401 — first**" \
  "- [ ] **#402 — second**" \
  "" "## End" | bash "$HELPER" -)
expected=$'401\n402'
if [ "$out" = "$expected" ]; then
  pass_msg "Case E: stdin parsing works"
else
  fail_msg "Case E: expected '$expected' got '$out'"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
