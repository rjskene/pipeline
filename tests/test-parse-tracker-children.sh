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

# ---- Case M: decorated heading with parenthetical suffix → children extracted (#1157) ----
# Operators decorate the heading naturally (ship-order notes, spec links). The old
# exact-match anchor `^## Rollout sequence[[:space:]]*$` rejected these and returned
# ZERO children for a tracker with a full open checklist.
echo "Case M: decorated '## Rollout sequence (…)' heading parses children"
inc
M="$TMP/body-m.md"
cat > "$M" <<'BODY'
## Context
Some prose.

## Rollout sequence (design approved 2026-07-06 — spec: docs/foo.md)

- [ ] **#942 — first decorated child**
- [ ] **#943 — second decorated child**

## Notes
- [ ] **#999 — outside the rollout section, should be ignored**
BODY

out=$(bash "$HELPER" "$M" 2>"$TMP/err-m") || { fail_msg "Case M: exit non-zero"; cat "$TMP/err-m"; }
expected=$'942\n943'
if [ "$out" = "$expected" ]; then
  pass_msg "Case M: decorated-heading children parsed in order"
else
  fail_msg "Case M: expected '$expected' got '$out'"
fi

# ---- Case N: a continuation-word heading is NOT the rollout section (#1157 guard) ----
# The loosened anchor must accept a parenthetical/plain decoration but must NOT treat
# `## Rollout sequence appendix` (a different section whose title merely starts with
# the same words) as the rollout section — this is what keeps Case C green and rules
# out an over-broad `\b`-style loosening.
echo "Case N: '## Rollout sequence appendix' continuation heading yields no children"
inc
N="$TMP/body-n.md"
cat > "$N" <<'BODY'
## Rollout sequence appendix (note: different section)

- [ ] **#801 — must NOT be treated as a rollout child**
BODY

if out=$(bash "$HELPER" "$N" 2>"$TMP/err-n"); then
  if [ -z "$out" ]; then
    pass_msg "Case N: continuation-word heading yields no children"
  else
    fail_msg "Case N: expected empty output, got '$out'"
  fi
else
  fail_msg "Case N: helper exited non-zero ($?), expected 0"
fi

# ---- Case N1: hyphen-decorated heading → children extracted (#1164) ----
# Non-paren trailing decoration (dash) must open the rollout section just like a
# parenthetical does. The old `(\(|$)` anchor rejected these, dropping children.
echo "Case N1: '## Rollout sequence - …' (hyphen) heading parses children"
inc
N1="$TMP/body-n1.md"
cat > "$N1" <<'BODY'
## Rollout sequence - design approved

- [ ] **#511 — first child**
- [ ] **#512 — second child**
BODY

out=$(bash "$HELPER" "$N1" 2>"$TMP/err-n1") || { fail_msg "Case N1: exit non-zero"; cat "$TMP/err-n1"; }
expected=$'511\n512'
if [ "$out" = "$expected" ]; then
  pass_msg "Case N1: hyphen-decorated heading children parsed"
else
  fail_msg "Case N1: expected '$expected' got '$out'"
fi

# ---- Case N2: em-dash + colon decorated heading → children extracted (#1164) ----
echo "Case N2: '## Rollout sequence — spec: …' (em-dash) heading parses children"
inc
N2="$TMP/body-n2.md"
cat > "$N2" <<'BODY'
## Rollout sequence — spec: docs/x.md

- [ ] **#521 — first child**
- [ ] **#522 — second child**
BODY

out=$(bash "$HELPER" "$N2" 2>"$TMP/err-n2") || { fail_msg "Case N2: exit non-zero"; cat "$TMP/err-n2"; }
expected=$'521\n522'
if [ "$out" = "$expected" ]; then
  pass_msg "Case N2: em-dash-decorated heading children parsed"
else
  fail_msg "Case N2: expected '$expected' got '$out'"
fi

# ---- Case N3: colon-decorated heading (no space) → children extracted (#1164) ----
echo "Case N3: '## Rollout sequence: notes' (colon) heading parses children"
inc
N3="$TMP/body-n3.md"
cat > "$N3" <<'BODY'
## Rollout sequence: notes

- [ ] **#531 — first child**
- [ ] **#532 — second child**
BODY

out=$(bash "$HELPER" "$N3" 2>"$TMP/err-n3") || { fail_msg "Case N3: exit non-zero"; cat "$TMP/err-n3"; }
expected=$'531\n532'
if [ "$out" = "$expected" ]; then
  pass_msg "Case N3: colon-decorated heading children parsed"
else
  fail_msg "Case N3: expected '$expected' got '$out'"
fi

# ---- Case N4: '## Rollout sequence appendix' continuation heading → no children (#1164 exclusion) ----
# The loosened anchor must accept punctuation decoration but must NOT treat a
# following alnum word (`appendix`) as the rollout section — keeps Case C green.
echo "Case N4: '## Rollout sequence appendix' yields no children"
inc
N4="$TMP/body-n4.md"
cat > "$N4" <<'BODY'
## Rollout sequence appendix

- [ ] **#541 — must NOT be treated as a rollout child**
BODY

if out=$(bash "$HELPER" "$N4" 2>"$TMP/err-n4"); then
  if [ -z "$out" ]; then
    pass_msg "Case N4: appendix continuation heading yields no children"
  else
    fail_msg "Case N4: expected empty output, got '$out'"
  fi
else
  fail_msg "Case N4: helper exited non-zero ($?), expected 0"
fi

# ---- Case N5: '## Rollout sequencer' word-continuation heading → no children (#1164 exclusion) ----
# No separator at all (bare word continuation) must also stay excluded.
echo "Case N5: '## Rollout sequencer' yields no children"
inc
N5="$TMP/body-n5.md"
cat > "$N5" <<'BODY'
## Rollout sequencer

- [ ] **#551 — must NOT be treated as a rollout child**
BODY

if out=$(bash "$HELPER" "$N5" 2>"$TMP/err-n5"); then
  if [ -z "$out" ]; then
    pass_msg "Case N5: sequencer word-continuation heading yields no children"
  else
    fail_msg "Case N5: expected empty output, got '$out'"
  fi
else
  fail_msg "Case N5: helper exited non-zero ($?), expected 0"
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

# ============================================================================
# POSIX / mawk portability (#800): the embedded awk programs must NOT depend on
# the gawk-only 3-arg match(str, regex, arr) extension. On mawk (the Debian/
# Ubuntu default awk) the 3-arg form is a hard parse error, so auto-close
# silently no-ops. Run the helper with a PATH shim that forces `awk` -> mawk.
# ============================================================================

if command -v mawk >/dev/null 2>&1; then
  SHIM="$TMP/awkshim"
  mkdir -p "$SHIM"
  ln -sf "$(command -v mawk)" "$SHIM/awk"

  # ---- Case K: default mode parses under mawk ----
  echo "Case K: default mode works when awk is mawk"
  inc
  out=$(PATH="$SHIM:$PATH" bash "$HELPER" "$A" 2>"$TMP/err-k") \
    || { fail_msg "Case K: exit non-zero"; cat "$TMP/err-k"; }
  expected=$'101\n102\n103'
  if [ "$out" = "$expected" ] && [ ! -s "$TMP/err-k" ]; then
    pass_msg "Case K: default-mode children parsed under mawk, no awk errors"
  else
    fail_msg "Case K: expected '$expected' got '$out' (stderr: $(cat "$TMP/err-k"))"
  fi

  # ---- Case L: --fallback-mentions mode parses under mawk ----
  echo "Case L: --fallback-mentions works when awk is mawk"
  inc
  out=$(PATH="$SHIM:$PATH" bash "$HELPER" "$F" --fallback-mentions 2>"$TMP/err-l") \
    || { fail_msg "Case L: exit non-zero"; cat "$TMP/err-l"; }
  expected=$'101\n102\n103\n104'
  if [ "$out" = "$expected" ] && [ ! -s "$TMP/err-l" ]; then
    pass_msg "Case L: fallback-mode mentions parsed under mawk, no awk errors"
  else
    fail_msg "Case L: expected '$expected' got '$out' (stderr: $(cat "$TMP/err-l"))"
  fi
else
  echo "Case K/L: mawk not installed — skipping POSIX-portability checks"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
