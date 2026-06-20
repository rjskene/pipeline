#!/bin/bash
set -uo pipefail

# Regression guard for #1093: fullsend Step 6's inline PATH B execute prose must
# DRIVE the two-phase split-role dispatch (Opus red-author -> green-implementer)
# that produces the `[split-role-red]` anchor the eval-time gate
# (scripts/split-role-gate.sh via evaluate-issue-pr Step 11.2b) scans for.
#
# Root cause (the bug): the resolver (scripts/resolve-execute-dispatch.sh) emits
# SPLIT_ROLE=true / ROLES=red:opus,green:<model> by DEFAULT (#1057), and the
# fullsend resolver section (the "Per-path execute MODEL routing" block, ~L475)
# ALREADY specifies the two-sequential-agent split-role contract. But the lagging
# surfaces — fullsend Step 6's "Split dispatch" prose (~L295) and the "Dispatch
# routing by path tier (reference)" PATH B EXECUTE block (~L455) — still describe
# PATH B as a LONE `general-purpose` Agent whose only discipline is the plan's
# "Task 0 TDD bookend", with NO SPLIT_ROLE branch. A single combined-red->green
# agent never emits a `[split-role-red]` commit, so the gate hard-blocks
# `no-red-sha` on every default-config PATH B PR.
#
# This guard asserts the LAGGING surfaces are reconciled to the two-phase
# contract. It is SCOPED to the Step 6 Split-dispatch region and the routing-
# reference PATH B EXECUTE block ONLY — it deliberately EXCLUDES the resolver
# section (~L467-475), whose correct two-phase prose already exists and would
# otherwise mask the lagging-prose defect. A single-agent reconciliation
# ("one Agent drives both phases") MUST fail this guard.
#
# Static-grep/awk over skills/fullsend/SKILL.md ONLY (no live dispatch) — mirrors
# tests/test-path-b-default-split-role.sh and
# tests/test-execute-dispatch-prompt-hardening.sh. Per CLAUDE.md release-hygiene
# the named-file scan never compares version literals and never whole-repo greps,
# so no CHANGELOG/.git/.claude exclusion is needed.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$FULLSEND" ]; then echo "ERROR: $FULLSEND not found" >&2; exit 1; fi

echo "== test-fullsend-split-role-dispatch (issue #1093) =="

# --- region extractors -------------------------------------------------------
#
# (A) Step 6 "Split dispatch" region: from the "Split dispatch for PATH D ..."
#     marker up to (but not including) the next "   **" bold sub-heading at the
#     Step-6 indent (the "D is NOT exempt ..." paragraph). This is the paragraph
#     that today asserts: PATH B uses `Agent(subagent_type='general-purpose',...)`
#     whose discipline "comes from the plan's Task 0 ... bookend".
split_dispatch_region() {
  awk '
    /\*\*Split dispatch for PATH D/ { inblock = 1; print; next }
    inblock && /^   \*\*/ { inblock = 0 }
    inblock { print }
  ' "$FULLSEND"
}
split_dispatch_flat() { split_dispatch_region | tr "\n" " "; }

# (B) Routing-reference PATH B EXECUTE block: the "- **PATH B** (standard):
#     dispatch inline" item under "## Dispatch routing by path tier (reference)"
#     whose body wires the EXECUTE dispatch (contains `execute-issue-plan`), NOT
#     the PR-eval PATH B item (~L438, body contains `evaluate-issue-pr`) and NOT
#     the resolver section (~L467+). Each `- **PATH B**` item is bounded by the
#     next `   - **PATH <X>**` item; we collect every such block and emit only the
#     one carrying `execute-issue-plan`. Anchoring on the item HEADER (not the
#     discipline tail) keeps this stable across the reconciliation, which deletes
#     that tail.
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

# Guard: both regions must be non-empty (the anchors still match). If an extractor
# returns nothing the SKILL was restructured out from under this guard — fail loud.
inc
if [ -n "$(split_dispatch_region)" ]; then
  pass_msg "anchor: Step 6 'Split dispatch' region extracted"
else
  fail_msg "anchor: Step 6 'Split dispatch' region is EMPTY (SKILL restructured?)"
fi
inc
if [ -n "$(routing_pathb_execute_block)" ]; then
  pass_msg "anchor: routing-reference PATH B execute block extracted"
else
  fail_msg "anchor: routing-reference PATH B execute block is EMPTY (SKILL restructured?)"
fi

# === Assertion (1): the PATH B Step 6 dispatch prose is SPLIT_ROLE-aware AND
#     encodes the TWO-SEQUENTIAL-DISPATCH shape. Require co-occurrence, in the
#     Step 6 Split-dispatch region, of:
#       (a) the role tokens: `red:opus` AND `green:`,
#       (b) the literal `[split-role-red]` anchor,
#       (c) two-sequential-dispatch wording (`two sequential`).
#     A single-agent reading ("one Agent drives both phases") lacks all three and
#     MUST fail this. The resolver section is OUT OF SCOPE here, so the correct
#     prose already living there cannot satisfy this assertion.
inc
if split_dispatch_flat | grep -Fq 'red:opus' \
   && split_dispatch_flat | grep -Fq 'green:'; then
  pass_msg "(1a) Step 6 split-dispatch names red:opus + green: role tokens"
else
  fail_msg "(1a) Step 6 split-dispatch missing red:opus / green: role tokens (single-agent prose)"
fi
inc
if split_dispatch_flat | grep -Fq '[split-role-red]'; then
  pass_msg "(1b) Step 6 split-dispatch names the [split-role-red] anchor literal"
else
  fail_msg "(1b) Step 6 split-dispatch missing the [split-role-red] anchor literal"
fi
inc
if split_dispatch_flat | grep -Eiq 'two sequential'; then
  pass_msg "(1c) Step 6 split-dispatch uses two-sequential-dispatch wording"
else
  fail_msg "(1c) Step 6 split-dispatch missing two-sequential-dispatch wording (single-agent prose)"
fi

# === Assertion (2): NO unconditional single-`general-purpose`-agent claim
#     survives in the lagging surfaces UNGATED. The single-agent shape MUST be
#     explicitly gated to `SPLIT_ROLE=false` / `ROLES=single`. We assert this on
#     BOTH lagging surfaces:
#
#   (2a) Step 6 Split-dispatch region: the old unconditional claim
#        "PATH B uses `Agent(subagent_type='general-purpose', ...)` (its red->green
#        discipline comes from the plan's Task 0 ... bookend ...)" is GONE — i.e.
#        any `general-purpose` mention for PATH B here must co-occur with the
#        SPLIT_ROLE=false / ROLES=single gate.
inc
if split_dispatch_flat | grep -Fq 'general-purpose'; then
  # general-purpose is mentioned for PATH B in this region -> it MUST be gated.
  if split_dispatch_flat | grep -Eq 'SPLIT_ROLE=false|ROLES=single'; then
    pass_msg "(2a) Step 6 single-agent general-purpose shape is gated to SPLIT_ROLE=false/ROLES=single"
  else
    fail_msg "(2a) Step 6 still asserts UNGATED single general-purpose PATH B agent (no SPLIT_ROLE=false/ROLES=single gate)"
  fi
else
  pass_msg "(2a) Step 6 split-dispatch makes no bare single general-purpose PATH B claim"
fi
#   (2b) the stale unconditional discipline phrasing — PATH B's discipline
#        "comes from the plan's Task 0 ... bookend" as the SOLE discipline with no
#        split-role branch — is GONE from the Step 6 region. (Catches a
#        reconciliation that adds split-role prose but leaves the contradicting
#        single-agent claim sitting right beside it.)
inc
if ! split_dispatch_flat | grep -Eq "PATH B uses .Agent\(subagent_type='general-purpose'"; then
  pass_msg "(2b) Step 6 stale unconditional \"PATH B uses Agent(general-purpose)\" claim is gone"
else
  fail_msg "(2b) Step 6 stale unconditional \"PATH B uses Agent(general-purpose)\" claim remains"
fi
#   (2c) routing-reference PATH B EXECUTE block: the bare
#        "B's red->green discipline comes from the plan's Task 0 ... bookend"
#        single-agent claim must be reconciled — either the SPLIT_ROLE=true
#        two-sequential-dispatch shape is named here, or the single-agent shape is
#        explicitly gated to SPLIT_ROLE=false / ROLES=single.
inc
if routing_pathb_execute_flat | grep -Eq 'SPLIT_ROLE=(true|false)|ROLES=(single|red:opus)|two sequential|split-role-red'; then
  pass_msg "(2c) routing-reference PATH B execute block is split-role-aware (gated/two-phase)"
else
  fail_msg "(2c) routing-reference PATH B execute block still asserts the UNGATED single general-purpose shape"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
