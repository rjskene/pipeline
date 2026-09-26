#!/bin/bash
set -uo pipefail

# Regression guard for #1095, re-pinned by #1420 (split-role lane removed).
#
# skills/fullsend/SKILL.md restates the PATH B execute dispatch shape in THREE
# prose homes:
#
#   (A) Step 6 "Split dispatch" region
#   (B) Routing-reference PATH B EXECUTE block
#   (C) Resolver section ("Per-path execute MODEL routing — SINGLE-SOURCE resolver")
#
# Before #1420 those three homes had to AGREE on the two-phase split-role token
# set (red:opus / green: / [split-role-red] / "two sequential"). #1420 collapses
# PATH B execute to ONE agent, so the agreement contract inverts: every home must
# carry the SINGLE-shape tokens (a resolved `model=` plus the canonical
# `execute-issue-plan #<N>` attribution description) and NONE may carry any
# surviving split-role token. Cross-section agreement is still the point — two
# regions must not silently contradict each other, one describing a single agent
# while another still describes a red/green pair.
#
# Static-grep/awk over skills/fullsend/SKILL.md ONLY (no live dispatch). Never
# compares version literals and never whole-repo greps (per CLAUDE.md
# release-hygiene).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FULLSEND" ]; then echo "ERROR: $FULLSEND not found" >&2; exit 1; fi

echo "== test-fullsend-dispatch-prose-consistency (issue #1095) =="

# --- region extractors -------------------------------------------------------
#
# (A) Step 6 "Split dispatch" region — mirrors the extractor in
#     test-fullsend-split-role-dispatch.sh (same anchor, same terminator).
split_dispatch_region() {
  awk '
    /\*\*Split dispatch for PATH D/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$FULLSEND"
}
split_dispatch_flat() { split_dispatch_region | tr "\n" " "; }

# (B) Routing-reference PATH B EXECUTE block — mirrors the extractor in
#     test-fullsend-split-role-dispatch.sh. Collects every PATH B item and
#     emits only the one carrying "execute-issue-plan".
routing_pathb_execute_block() {
  awk '
    /^   - \*\*PATH B\*\* \(standard\): dispatch inline/ { inblock = 1; buf = $0 ORS; next }
    inblock && /^   - \*\*PATH [ACD]\*\*/ {
      if (buf ~ /execute-issue-plan/) printf "%s", buf
      inblock = 0; buf = ""
    }
    inblock { buf = buf $0 ORS }
    END { if (inblock && buf ~ /execute-issue-plan/) printf "%s", buf }
  ' "$FULLSEND"
}
routing_pathb_execute_flat() { routing_pathb_execute_block | tr "\n" " "; }

# (C) Resolver section — from the "Per-path execute MODEL routing" bullet to
#     the next top-level section header ("## ...").  Terminate on "^##" only:
#     the section has deep sub-bullets whose own "**..." patterns are NOT valid
#     terminators (they are nested inside the same list item).
resolver_section() {
  awk '
    /^\s+- \*\*Per-path execute MODEL routing/ { inblock = 1; print; next }
    inblock && /^##/ { inblock = 0 }
    inblock { print }
  ' "$FULLSEND"
}
resolver_flat() { resolver_section | tr "\n" " "; }

# Guard: all three regions must be non-empty (anchors still match). If an
# extractor returns nothing the SKILL was restructured — fail loud.
inc
if [ -n "$(split_dispatch_region)" ]; then
  pass_msg "anchor-A: Step 6 'Split dispatch' region extracted"
else
  fail_msg "anchor-A: Step 6 'Split dispatch' region is EMPTY (SKILL restructured?)"
fi
inc
if [ -n "$(routing_pathb_execute_block)" ]; then
  pass_msg "anchor-B: routing-reference PATH B execute block extracted"
else
  fail_msg "anchor-B: routing-reference PATH B execute block is EMPTY (SKILL restructured?)"
fi
inc
if [ -n "$(resolver_section)" ]; then
  pass_msg "anchor-C: resolver section extracted"
else
  fail_msg "anchor-C: resolver section is EMPTY (SKILL restructured?)"
fi

# === Assertion (3): every prose home encodes the SINGLE-agent dispatch shape.
#     Required, per region:
#       (3a) a resolved model pin — `model='<resolved-model>'` or `model=$MODEL`
#       (3b) the canonical attribution description `execute-issue-plan #<N>`
REQUIRED_DESC='execute-issue-plan #<N>'

assert_model_pin() {
  local label="$1" flat="$2"
  inc
  if printf '%s' "$flat" | grep -Fq "model='<resolved-model>'" \
     || printf '%s' "$flat" | grep -Fq 'model=$MODEL'; then
    pass_msg "$label: names a resolved model pin (model='<resolved-model>' or model=\$MODEL)"
  else
    fail_msg "$label: no resolved model pin — an unpinned dispatch inherits the session model"
  fi
}

assert_desc() {
  local label="$1" flat="$2"
  inc
  if printf '%s' "$flat" | grep -Fq "$REQUIRED_DESC"; then
    pass_msg "$label: names the canonical '$REQUIRED_DESC' dispatch description"
  else
    fail_msg "$label: missing the canonical '$REQUIRED_DESC' dispatch description (cost attribution key)"
  fi
}

A_FLAT="$(split_dispatch_flat)"
B_FLAT="$(routing_pathb_execute_flat)"
C_FLAT="$(resolver_flat)"

assert_model_pin "(3a) region-A Step 6 split dispatch" "$A_FLAT"
assert_desc      "(3b) region-A Step 6 split dispatch" "$A_FLAT"
assert_model_pin "(3a) region-B routing PATH B execute" "$B_FLAT"
assert_desc      "(3b) region-B routing PATH B execute" "$B_FLAT"
assert_model_pin "(3a) region-C resolver section" "$C_FLAT"
assert_desc      "(3b) region-C resolver section" "$C_FLAT"

# === Assertion (4): CROSS-SECTION AGREEMENT on the single shape (#1420) — NO
#     region may carry a surviving split-role token. Per-region presence of the
#     single-shape tokens (assertion 3) does not prove the regions agree: one
#     region could name the single agent while another still prescribes the
#     retired red/green pair, which is exactly the contradiction this asserts
#     away.
BANNED=(
  'red:opus'
  'green:'
  '[split-role-red]'
  'SPLIT_ROLE'
  'two sequential'
)

assert_no_banned() {
  local label="$1" flat="$2" needle
  for needle in "${BANNED[@]}"; do
    inc
    if printf '%s' "$flat" | grep -Fiq -- "$needle"; then
      fail_msg "$label: still carries the retired split-role token '$needle' (#1420 collapsed PATH B to one execute agent)"
    else
      pass_msg "$label: free of the retired split-role token '$needle'"
    fi
  done
}

assert_no_banned "(4) region-A Step 6 split dispatch" "$A_FLAT"
assert_no_banned "(4) region-B routing PATH B execute" "$B_FLAT"
assert_no_banned "(4) region-C resolver section" "$C_FLAT"

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
