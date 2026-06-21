#!/bin/bash
set -uo pipefail

# Regression guard for #1095: extend the split-role dispatch prose guard to
# cover the resolver section of skills/fullsend/SKILL.md (the
# "Per-path execute MODEL routing — SINGLE-SOURCE resolver" block, ~L474-492)
# AND assert CROSS-SECTION AGREEMENT among all three prose homes:
#
#   (A) Step 6 "Split dispatch" region (~L295)
#   (B) Routing-reference PATH B EXECUTE block (~L455)
#   (C) Resolver section (~L474)
#
# The existing tests/test-fullsend-split-role-dispatch.sh (issue #1093) asserts
# regions A and B INDEPENDENTLY. This guard adds:
#   - resolver-section (C) anchor + per-token assertions
#   - cross-section agreement: all three homes carry the SAME required token set
#     (red:opus, green:, [split-role-red], two-sequential wording) so two
#     regions cannot silently contradict each other.
#
# Static-grep/awk over skills/fullsend/SKILL.md ONLY (no live dispatch) —
# mirrors tests/test-fullsend-split-role-dispatch.sh. Never compares version
# literals and never whole-repo greps (per CLAUDE.md release-hygiene).

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

# === Assertion (3): the resolver section encodes the two-phase split-role
#     dispatch shape. Require co-occurrence, in the resolver section, of:
#       (3a) role tokens: red:opus AND green:
#       (3b) the [split-role-red] literal
#       (3c) two-sequential-dispatch wording (two sequential)
#       (3d) SPLIT_ROLE=true default
inc
if resolver_flat | grep -Fq 'red:opus' \
   && resolver_flat | grep -Fq 'green:'; then
  pass_msg "(3a) resolver section names red:opus + green: role tokens"
else
  fail_msg "(3a) resolver section missing red:opus / green: role tokens"
fi
inc
if resolver_flat | grep -Fq '[split-role-red]'; then
  pass_msg "(3b) resolver section names the [split-role-red] anchor literal"
else
  fail_msg "(3b) resolver section missing the [split-role-red] anchor literal"
fi
inc
if resolver_flat | grep -Eiq 'two sequential'; then
  pass_msg "(3c) resolver section uses two-sequential-dispatch wording"
else
  fail_msg "(3c) resolver section missing two-sequential-dispatch wording"
fi
inc
if resolver_flat | grep -Fq 'SPLIT_ROLE=true'; then
  pass_msg "(3d) resolver section asserts SPLIT_ROLE=true default"
else
  fail_msg "(3d) resolver section missing SPLIT_ROLE=true default assertion"
fi

# === Assertion (4): CROSS-SECTION AGREEMENT — every prose home that restates
#     the split-role two-phase contract carries the SAME required token set.
#     Per-region presence (assertions 1/2 in test-fullsend-split-role-dispatch.sh
#     and assertions 3 above) does NOT prove the regions agree — two regions
#     could each carry one half of the token set while describing different
#     models/shapes, slipping through per-region checks. These assertions verify
#     the token SET is present in EVERY region simultaneously.
#
#   Required tokens for cross-section agreement:
#     T1 = red:opus
#     T2 = green:
#     T3 = [split-role-red]
#     T4 = two-sequential wording (two sequential)
#
#   Each assertion fails if ANY of the three regions is missing the token.

# T1 — red:opus in ALL three regions
inc
if split_dispatch_flat | grep -Fq 'red:opus' \
   && routing_pathb_execute_flat | grep -Fq 'red:opus' \
   && resolver_flat | grep -Fq 'red:opus'; then
  pass_msg "(4a) cross-section: red:opus present in all three prose homes"
else
  fail_msg "(4a) cross-section: red:opus MISSING from at least one prose home"
fi

# T2 — green: in ALL three regions
inc
if split_dispatch_flat | grep -Fq 'green:' \
   && routing_pathb_execute_flat | grep -Fq 'green:' \
   && resolver_flat | grep -Fq 'green:'; then
  pass_msg "(4b) cross-section: green: present in all three prose homes"
else
  fail_msg "(4b) cross-section: green: MISSING from at least one prose home"
fi

# T3 — [split-role-red] in ALL three regions
inc
if split_dispatch_flat | grep -Fq '[split-role-red]' \
   && routing_pathb_execute_flat | grep -Fq '[split-role-red]' \
   && resolver_flat | grep -Fq '[split-role-red]'; then
  pass_msg "(4c) cross-section: [split-role-red] present in all three prose homes"
else
  fail_msg "(4c) cross-section: [split-role-red] MISSING from at least one prose home"
fi

# T4 — two-sequential wording in ALL three regions
inc
if split_dispatch_flat | grep -Eiq 'two sequential' \
   && routing_pathb_execute_flat | grep -Eiq 'two sequential' \
   && resolver_flat | grep -Eiq 'two sequential'; then
  pass_msg "(4d) cross-section: two-sequential wording present in all three prose homes"
else
  fail_msg "(4d) cross-section: two-sequential wording MISSING from at least one prose home"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
