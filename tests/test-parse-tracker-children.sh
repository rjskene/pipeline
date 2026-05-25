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

# ============================================================================
# --fallback-mentions mode (#491): scan the WHOLE body for `#NNN` mentions,
# ignoring `## Rollout sequence` bounds, deduping, preserving first-appearance
# order, and suppressing fenced code blocks and inline code spans.
# ============================================================================

# ---- Case F: --fallback-mentions ignores rollout bounds, emits ALL mentions ----
echo "Case F: --fallback-mentions ignores rollout section bounds"
inc
F="$TMP/body-f.md"
cat > "$F" <<'BODY'
## Rollout sequence

- [ ] **#101 — first**
- [ ] **#102 — second**

## Notes
Depends on #103 and references #104.
BODY

out=$(bash "$HELPER" "$F" --fallback-mentions 2>"$TMP/err-f") \
  || { fail_msg "Case F: exit non-zero"; cat "$TMP/err-f"; }
expected=$'101\n102\n103\n104'
if [ "$out" = "$expected" ]; then
  pass_msg "Case F: all mentions emitted regardless of section"
else
  fail_msg "Case F: expected '$expected' got '$out'"
fi

# ---- Case G: dedup — a repeated mention is emitted once ----
echo "Case G: --fallback-mentions dedups repeated mentions"
inc
G="$TMP/body-g.md"
cat > "$G" <<'BODY'
References #101 twice: #101 again, plus #102.
BODY

out=$(bash "$HELPER" "$G" --fallback-mentions)
expected=$'101\n102'
if [ "$out" = "$expected" ]; then
  pass_msg "Case G: #101 deduped to a single line"
else
  fail_msg "Case G: expected '$expected' got '$out'"
fi

# ---- Case H: ordering — emitted in order of first appearance ----
echo "Case H: --fallback-mentions preserves first-appearance order"
inc
H="$TMP/body-h.md"
cat > "$H" <<'BODY'
First #303, then #301, then #302.
BODY

out=$(bash "$HELPER" "$H" --fallback-mentions)
expected=$'303\n301\n302'
if [ "$out" = "$expected" ]; then
  pass_msg "Case H: order of first appearance preserved"
else
  fail_msg "Case H: expected '$expected' got '$out'"
fi

# ---- Case I: fenced code blocks and inline code spans suppressed ----
echo "Case I: --fallback-mentions suppresses code fences + inline code"
inc
I="$TMP/body-i.md"
cat > "$I" <<'BODY'
Real child #501 in prose.

Inline `#999` must be ignored.

```
#998 inside a fenced block must be ignored
```

Another real child #502.
BODY

out=$(bash "$HELPER" "$I" --fallback-mentions)
expected=$'501\n502'
if [ "$out" = "$expected" ]; then
  pass_msg "Case I: code-fenced and inline-code mentions suppressed"
else
  fail_msg "Case I: expected '$expected' got '$out'"
fi

# ---- Case J: no rollout AND no mentions → empty output, exit 0 ----
echo "Case J: --fallback-mentions with no mentions → empty, exit 0"
inc
J="$TMP/body-j.md"
cat > "$J" <<'BODY'
## Context
Just prose, no issue mentions at all.

## Plan
Some plan text.
BODY

if out=$(bash "$HELPER" "$J" --fallback-mentions 2>"$TMP/err-j"); then
  if [ -z "$out" ]; then
    pass_msg "Case J: empty output when no mentions"
  else
    fail_msg "Case J: expected empty output, got '$out'"
  fi
else
  fail_msg "Case J: helper exited non-zero ($?), expected 0"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
