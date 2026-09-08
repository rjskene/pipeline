#!/bin/bash
set -euo pipefail

# Unit tests for scripts/select-plan-comment.sh — the heading-anchored
# plan-comment selector (#1240).
#
# THE DEFECT: scripts/plan-waves.sh selected an issue's implementation plan
# with `[.comments[] | select(.body | contains("## Implementation Plan"))]
# | last`. `evaluate-issue-plan` routinely QUOTES that heading inside its own
# `## Plan Evaluation` comment — inline (`` `## Implementation Plan` ``), inside
# a fenced block, or inside a blockquote — and being the LATER comment it won
# the selection. Observed live on #1224 / #1225 (inline code) and #1230
# (`## Evaluation` from evaluate-issue-pr). The wave planner then derived
# file-conflict edges from the reviewer's prose instead of the plan.
#
# CONTRACT UNDER TEST:
#   stdin  = the `gh issue view --json comments` JSON document
#   stdout = the body of the LAST comment whose FIRST ATX heading IS the plan
#            heading `## Implementation Plan` (trailing decoration such as
#            `(round 2)` tolerated), emitted verbatim; nothing when no comment
#            qualifies
#   exit   = 0 ALWAYS. plan-waves.sh runs under `set -euo pipefail`, so the
#            selector must fail OPEN (empty stdout -> caller's pre-existing
#            body-extraction fallback) and must never abort a wave-planning run.
#
# Every case asserts exit status 0 alongside its stdout property, because
# "never aborts the caller" is half the contract.
#
# No `gh` shim is needed — the helper reads its JSON on stdin.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/select-plan-comment.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "  (helper does not exist yet at $HELPER — every case will FAIL by design until implementation)"
fi

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# mk_json <body>... — compose `{"comments":[{"body":...},...]}` from N comment
# bodies in order. jq-composed so bodies survive quoting byte-for-byte.
mk_json() {
  jq -n --args \
    '{comments: [$ARGS.positional[] | {body: ., createdAt: "2026-05-22T00:00:00Z"}]}' \
    "$@"
}

OUT=""
RC=0

# select_from <json> — feed JSON on stdin; capture stdout into OUT and the
# exit status into RC (never let a non-zero status trip `set -e`).
select_from() {
  OUT=""
  RC=0
  OUT=$(printf '%s' "$1" | bash "$HELPER" 2>"$TMP/stderr") || RC=$?
}

first_line() { printf '%s\n' "$OUT" | head -n 1; }

check() {
  local label="$1" ok="$2"
  if [ "$ok" = "1" ]; then
    pass_msg "$label"
  else
    fail_msg "$label"
    echo "    rc=$RC"
    echo "    stdout:"; printf '%s\n' "$OUT" | sed 's/^/      /'
    if [ -s "$TMP/stderr" ]; then
      echo "    stderr:"; sed 's/^/      /' "$TMP/stderr"
    fi
  fi
}

# ---- Shared fixtures ----

PLAN_ALPHA=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — the real target

**Estimated effort:** 1 hour
EOF
)

# The dominant real shape (#1224 / #1225): the heading quoted in an INLINE
# CODE SPAN inside the evaluator's own comment.
EVAL_INLINE=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

Round-2 re-evaluation of the latest `## Implementation Plan` on #1240.
EOF
)

# ---- Case A: lone plan comment ----
echo "Case A: a lone plan comment is selected"
inc
select_from "$(mk_json "$PLAN_ALPHA")"
ok=0
if [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan" ] \
   && printf '%s\n' "$OUT" | grep -qF 'scripts/alpha.sh'; then ok=1; fi
check "Case A: lone plan comment selected, body emitted" "$ok"

# ---- Case B: inline-code quote (the observed defect, #1224/#1225) ----
echo "Case B: a LATER eval comment quoting the heading INLINE must not win"
inc
select_from "$(mk_json "$PLAN_ALPHA" "$EVAL_INLINE")"
ok=0
if [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan" ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'Plan Evaluation'; then ok=1; fi
check "Case B: inline-code quote suppressed; plan comment selected" "$ok"

# ---- Case C: fenced-code quote ----
echo "Case C: a LATER eval comment quoting the heading in a FENCED block must not win"
inc
EVAL_FENCED=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

The plan under review reads:

```markdown
## Implementation Plan

**Files to change:**
- `scripts/ghost.sh` — quoted from the plan, not authored here
```

Quoted for reference only.
EOF
)
select_from "$(mk_json "$PLAN_ALPHA" "$EVAL_FENCED")"
ok=0
if [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan" ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'ghost.sh'; then ok=1; fi
check "Case C: fenced-code quote suppressed; plan comment selected" "$ok"

# ---- Case D: blockquote quote ----
echo "Case D: a LATER eval comment BLOCKQUOTING the heading must not win"
inc
EVAL_BLOCKQUOTE=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

Quoting the plan under review:

> ## Implementation Plan
>
> **Files to change:**
> - `scripts/ghost.sh` — quoted from the plan, not authored here

Quoted for reference only.
EOF
)
select_from "$(mk_json "$PLAN_ALPHA" "$EVAL_BLOCKQUOTE")"
ok=0
if [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan" ] \
   && ! printf '%s\n' "$OUT" | grep -qF 'ghost.sh'; then ok=1; fi
check "Case D: blockquote quote suppressed; plan comment selected" "$ok"

# ---- Case E: `## Evaluation` (evaluate-issue-pr) quoting the heading ----
echo "Case E: an evaluate-issue-pr '## Evaluation' comment quoting the heading must not win"
inc
EVAL_PR=$(cat <<'EOF'
## Evaluation

**Verdict:** Greenlit

Confirmed the `contains("## Implementation Plan")` selector was left untouched.
EOF
)
select_from "$(mk_json "$PLAN_ALPHA" "$EVAL_PR")"
ok=0
if [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan" ]; then ok=1; fi
check "Case E: '## Evaluation' comment rejected; plan comment selected" "$ok"

# ---- Case F: re-plan — the LATEST PLAN wins, not the trailing eval ----
echo "Case F: with two plan rounds plus a trailing eval, the latest PLAN wins"
inc
PLAN_ONE=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/one.sh` — round 1 target
EOF
)
PLAN_TWO=$(cat <<'EOF'
## Implementation Plan

Changes from previous plan: retargeted after review.

**Files to change:**
- `scripts/two.sh` — round 2 target
EOF
)
select_from "$(mk_json "$PLAN_ONE" "$PLAN_TWO" "$EVAL_INLINE")"
ok=0
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -qF 'scripts/two.sh' \
   && ! printf '%s\n' "$OUT" | grep -qF 'scripts/one.sh'; then ok=1; fi
check "Case F: latest-plan-wins preserved across a re-plan" "$ok"

# ---- Case G: no comments ----
echo "Case G: an empty comments array yields empty stdout and exit 0"
inc
select_from '{"comments":[]}'
ok=0
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok=1; fi
check "Case G: no comments -> empty stdout, exit 0" "$ok"

# ---- Case H: eval comment only, no plan ----
echo "Case H: an eval comment quoting the heading, with NO plan, selects nothing"
inc
select_from "$(mk_json "$EVAL_INLINE")"
ok=0
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok=1; fi
check "Case H: eval-only slate -> empty stdout, exit 0 (fails open)" "$ok"

# ---- Case I: unanchored mid-line mention ----
echo "Case I: an unanchored mid-line mention of the heading is not a heading"
inc
select_from "$(mk_json 'Please see the ## Implementation Plan above for details.')"
ok=0
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok=1; fi
check "Case I: mid-line '## Implementation Plan' mention rejected" "$ok"

# ---- Case J: wrong heading level ----
echo "Case J: a '#### Implementation Plan' heading is the wrong level"
inc
J_BODY=$(cat <<'EOF'
#### Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — wrong heading level
EOF
)
select_from "$(mk_json "$J_BODY")"
ok=0
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok=1; fi
check "Case J: '#### Implementation Plan' rejected (h2 only)" "$ok"

# ---- Case K: heading-prefix discrimination ----
echo "Case K: '## Implementation Planning' rejected; '## Implementation Plan (round 2)' accepted"
inc
K_PLANNING=$(cat <<'EOF'
## Implementation Planning

**Files to change:**
- `scripts/alpha.sh` — a different document
EOF
)
K_DECORATED=$(cat <<'EOF'
## Implementation Plan (round 2)

**Files to change:**
- `scripts/alpha.sh` — decorated heading
EOF
)
ok=0
select_from "$(mk_json "$K_PLANNING")"
k_i_rc="$RC"; k_i_out="$OUT"
select_from "$(mk_json "$K_DECORATED")"
if [ "$k_i_rc" -eq 0 ] && [ -z "$k_i_out" ] \
   && [ "$RC" -eq 0 ] \
   && [ "$(first_line)" = "## Implementation Plan (round 2)" ]; then ok=1; fi
check "Case K: 'Planning' rejected (i) and '(round 2)' decoration accepted (ii)" "$ok"

# ---- Case L: leading blank lines tolerated ----
echo "Case L: leading blank lines before the heading are tolerated"
inc
L_BODY=$(cat <<'EOF'


## Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — preceded by blank lines
EOF
)
select_from "$(mk_json "$L_BODY")"
ok=0
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -qF 'scripts/alpha.sh'; then ok=1; fi
check "Case L: leading blank lines do not defeat the heading anchor" "$ok"

# ---- Case M: body emitted verbatim, no shell expansion ----
echo "Case M: the selected body is emitted verbatim (no shell expansion)"
inc
M_BODY=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — verbatim emission

The selector must not expand $(date) or ${HOME}, and must keep a "double quote".

```bash
echo "SENTINEL_INNER_LINE"
```
EOF
)
select_from "$(mk_json "$M_BODY")"
ok=0
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -qF '$(date)' \
   && printf '%s\n' "$OUT" | grep -qF '${HOME}' \
   && printf '%s\n' "$OUT" | grep -qF '"double quote"' \
   && printf '%s\n' "$OUT" | grep -qF 'SENTINEL_INNER_LINE'; then ok=1; fi
check "Case M: body emitted byte-verbatim; \$(date) / \${HOME} unexpanded" "$ok"

# ---- Case N: malformed stdin ----
echo "Case N: malformed (non-JSON) stdin degrades gracefully"
inc
select_from 'not json at all'
ok=0
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok=1; fi
check "Case N: non-JSON stdin -> empty stdout, exit 0 (no pipefail abort)" "$ok"

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
