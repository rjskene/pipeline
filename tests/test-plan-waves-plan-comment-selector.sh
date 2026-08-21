#!/bin/bash
set -euo pipefail

# End-to-end regression guard for the plan-comment SELECTOR inside
# scripts/plan-waves.sh (#1240).
#
# #1230 fixed HOW file paths are extracted. This guards WHAT TEXT they are
# extracted from. plan-waves.sh chose the plan comment with
# `contains("## Implementation Plan") | last`, so a later `## Plan Evaluation`
# comment that merely QUOTES the heading (inline code / fenced block /
# blockquote) won — and the wave planner derived its file-conflict edges from
# the reviewer's prose instead of the plan. Symptom: issues that should have
# been serialized run in parallel.
#
# Assertions are on `--emit-edges` output, the crispest observable: one exact
# line per input issue, `EDGE #<N> blockers=<csv-or-"-"> files=<csv-or-"-">`.
#
# `gh` is replaced by a PATH-resident shim that reads canned JSON from
# $GH_ISSUE_DIR/<N>.json, and $GH_ISSUE_DIR/<N>.comments.json when the argv
# carries a bare `comments` token — mirroring tests/test-plan-waves.sh.
#
# FIXTURE PATH CONTRACT: every path below (scripts/alpha.sh, scripts/beta.sh,
# scripts/ghost.sh, scripts/one.sh, scripts/two.sh) is absent from
# `git ls-files` AND has no unique repo suffix match, so the #1230
# normalization step is a no-op and the tokens survive verbatim. Same
# convention as tests/test-plan-waves.sh Case G.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/plan-waves.sh"

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
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
# Args look like: issue view 42 --repo owner/repo --json number,title,body,labels
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
  for a in "$@"; do
    if [ "$a" = "comments" ]; then
      f="$GH_ISSUE_DIR/$n.comments.json"
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
      echo '{"comments":[]}'; exit 0
    fi
  done
  f="$GH_ISSUE_DIR/$n.json"
  if [ -f "$f" ]; then
    cat "$f"
    exit 0
  fi
  echo "shim: no canned JSON for issue $n" >&2
  exit 1
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

# Helper: write a canned issue JSON. Args: dir, number, priority_label, body
write_issue() {
  local dir="$1" num="$2" prio="$3" body="$4"
  local labels='[]'
  if [ -n "$prio" ]; then
    labels=$(printf '[{"name":"%s"}]' "$prio")
  fi
  jq -n \
    --arg num "$num" \
    --arg body "$body" \
    --argjson labels "$labels" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: $labels}' \
    > "$dir/$num.json"
}

# Helper: write a canned comments JSON carrying N comment bodies IN ORDER
# (ordering is load-bearing here — the defect is "the later comment wins").
# Args: dir, number, body...
write_comments() {
  local dir="$1" num="$2"; shift 2
  jq -n --args \
    '{comments: [$ARGS.positional[] | {body: ., createdAt: "2026-05-22T00:00:00Z"}]}' \
    "$@" > "$dir/$num.comments.json"
}

run_helper() {
  bash "$HELPER" "$@"
}

# ---- Shared fixtures ----

# The issue BODY decoy: backticks a path the plan does NOT touch. If the
# selector picks a comment with no line-anchored `**Files to change:**`,
# plan-waves.sh falls back to body extraction and harvests this decoy.
BODY_DECOY='Rework of `scripts/beta.sh` call sites.'

PLAN_ALPHA=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — the real target

**Estimated effort:** 1 hour
EOF
)

# Evaluator comment quoting the heading in an INLINE CODE SPAN, with NO
# line-anchored `**Files to change:**` block of its own (#1224 / #1225 shape).
EVAL_INLINE=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

Round-2 re-evaluation of the latest `## Implementation Plan` on #1240.
EOF
)

assert_edge() {
  # assert_edge <label> <dir> <expected-exact-EDGE-line>
  local label="$1" dir="$2" want="$3" out rc
  rc=0
  out=$(run_helper --emit-edges 1 2>"$dir/stderr") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail_msg "$label (helper exited $rc)"
    echo "    stderr:"; sed 's/^/      /' "$dir/stderr"
    return 0
  fi
  if printf '%s\n' "$out" | grep -qx -- "$want"; then
    pass_msg "$label"
  else
    fail_msg "$label"
    echo "    want: $want"
    echo "    got:"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

# ---- Case A: inline-code quote (headline regression) ----
echo "Case A: eval comment quoting the heading INLINE must not displace the plan"
inc
A="$TMP/case-a"; mkdir -p "$A"; export GH_ISSUE_DIR="$A"
write_issue "$A" 1 "priority/P2" "$BODY_DECOY"
write_comments "$A" 1 "$PLAN_ALPHA" "$EVAL_INLINE"
assert_edge "Case A: edges derived from the plan (scripts/alpha.sh), not the eval prose" \
  "$A" 'EDGE #1 blockers=- files=scripts/alpha.sh'

# ---- Case B: fenced-code quote harvests a ghost path ----
echo "Case B: eval comment FENCE-quoting a plan template must not leak its ghost path"
inc
B="$TMP/case-b"; mkdir -p "$B"; export GH_ISSUE_DIR="$B"
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
write_issue "$B" 1 "priority/P2" "$BODY_DECOY"
write_comments "$B" 1 "$PLAN_ALPHA" "$EVAL_FENCED"
assert_edge "Case B: fenced ghost path not harvested; plan path wins" \
  "$B" 'EDGE #1 blockers=- files=scripts/alpha.sh'

# ---- Case C: blockquote quote ----
echo "Case C: eval comment BLOCKQUOTING the heading must not displace the plan"
inc
C="$TMP/case-c"; mkdir -p "$C"; export GH_ISSUE_DIR="$C"
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
write_issue "$C" 1 "priority/P2" "$BODY_DECOY"
write_comments "$C" 1 "$PLAN_ALPHA" "$EVAL_BLOCKQUOTE"
assert_edge "Case C: blockquoted heading rejected; plan path wins" \
  "$C" 'EDGE #1 blockers=- files=scripts/alpha.sh'

# ---- Case D: re-plan — latest PLAN wins, not the trailing eval ----
echo "Case D: two plan rounds plus a trailing eval → the latest PLAN wins"
inc
D="$TMP/case-d"; mkdir -p "$D"; export GH_ISSUE_DIR="$D"
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
write_issue "$D" 1 "priority/P2" "$BODY_DECOY"
write_comments "$D" 1 "$PLAN_ONE" "$PLAN_TWO" "$EVAL_INLINE"
assert_edge "Case D: latest-plan-wins preserved (scripts/two.sh)" \
  "$D" 'EDGE #1 blockers=- files=scripts/two.sh'

# ---- Case E: CONTROL — no plan comment ⇒ body fallback preserved ----
# This row is green on BOTH sides of the fix BY CONSTRUCTION. It exists to
# prove the selector degrades to body extraction, never to reviewer prose.
# Do NOT "make it red" — bending it destroys the control.
echo "Case E: CONTROL — with no plan comment at all, body extraction still wins"
inc
E="$TMP/case-e"; mkdir -p "$E"; export GH_ISSUE_DIR="$E"
write_issue "$E" 1 "priority/P2" "$BODY_DECOY"
write_comments "$E" 1 "$EVAL_INLINE"
assert_edge "Case E: no plan comment -> body fallback (scripts/beta.sh), not eval prose" \
  "$E" 'EDGE #1 blockers=- files=scripts/beta.sh'

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
