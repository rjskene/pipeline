#!/bin/bash
set -euo pipefail

# Regression guard for issue #1263: Step 11.2b's `**Shared tests (split-role):**`
# carve-out must resolve against the ANCHORED plan-comment selection (Step 1,
# #1240/#1251) — not a `contains("## Implementation Plan")` match that can pick
# the `## Plan Evaluation` comment posted AFTER the plan.
#
# THE SCENARIO: a `## Plan Evaluation` comment routinely quotes the plan
# heading in backticks while explaining what it reviewed. If Step 11.2b
# resolved $PLAN with a `contains` match instead of the anchored selector,
# `| last` would select the evaluation comment (which has no
# **Shared tests (split-role):** section), yielding an EMPTY carve-out and a
# false SPLIT_ROLE=block REASON=locked-test-modified on a correct PR.
#
# This test exercises the REAL composed pipeline exactly as Step 1 + Step
# 11.2b run it: trust filter (filter-trusted-comments.sh) -> anchored
# selection (select-plan-comment.sh) -> the Step 11.2b awk parser (extracted
# live from SKILL.md) -> (Case C only) the real split-role-gate.sh consuming
# the resulting PIPELINE_SPLIT_ROLE_SHARED_TESTS export. Local JSON/git
# fixtures only — no gh/network calls.

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

SKILL="skills/evaluate-issue-pr/SKILL.md"
SELECTOR="$REPO_ROOT/scripts/select-plan-comment.sh"
TRUST_HELPER="$REPO_ROOT/scripts/filter-trusted-comments.sh"
GATE="$REPO_ROOT/scripts/split-role-gate.sh"
[ -f "$SKILL" ] || { echo "missing $SKILL"; exit 1; }
[ -f "$SELECTOR" ] || { echo "missing $SELECTOR"; exit 1; }
[ -f "$TRUST_HELPER" ] || { echo "missing $TRUST_HELPER"; exit 1; }

# Extract the REAL Step 11.2b awk one-liner from the SKILL.md source (same
# extraction idiom as tests/test-eval-shared-tests-parser.sh).
AWK_PROG=$(grep -oP "awk '\K[^']+(?=')" "$SKILL" | grep 'Shared tests' | head -1)
[ -n "$AWK_PROG" ] || { echo "FAIL: could not extract Shared-tests awk program from $SKILL"; exit 1; }

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

# mk_comments_json <assoc>$'\x1e'<body> ... — compose {"comments":[...]}
# preserving order, jq-composed so bodies survive quoting byte-for-byte.
mk_comments_json() {
  jq -n --args '
    {comments: [$ARGS.positional[] | split("") | {authorAssociation: .[0], body: .[1]}]}
  ' "$@"
}

# resolve_plan <json> — run the REAL Step 1 trust-then-anchor pipeline
# (filter-trusted-comments.sh is-trusted-author + select-plan-comment.sh),
# byte-identical in shape to skills/evaluate-issue-pr/SKILL.md Step 1.
resolve_plan() {
  local json="$1" keep="" idx=0 assoc
  while IFS= read -r assoc; do
    if bash "$TRUST_HELPER" is-trusted-author "$assoc"; then
      keep="${keep}${idx}"$'\n'
    fi
    idx=$((idx + 1))
  done < <(jq -r '.comments[] | (.authorAssociation // "")' <<<"$json")
  local keep_json trusted_json
  keep_json=$(printf '%s' "$keep" | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')
  trusted_json=$(jq -c --argjson keep "$keep_json" '{comments: [.comments[$keep[]]]}' <<<"$json")
  printf '%s' "$trusted_json" | bash "$SELECTOR"
}

PLAN_BODY=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/foo.sh` — the real target

**Shared tests (split-role):**
- tests/test-shared-widget.sh

**Estimated effort:** 1 hour
EOF
)

# The dominant real shape (#1263): the heading quoted in an INLINE CODE SPAN
# inside the evaluator's own comment, posted AFTER the plan.
EVAL_BODY=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

Round-2 re-evaluation of the latest `## Implementation Plan` on this issue —
confirmed the plan-sanctioned shared-test edit.
EOF
)

# ---------------------------------------------------------------------------
echo "Case A: plan + trailing eval quoting the heading -> composed pipeline still resolves the PLAN's carve-out"
inc
JSON_A=$(mk_comments_json "OWNER"$'\x1e'"$PLAN_BODY" "OWNER"$'\x1e'"$EVAL_BODY")
PLAN_A=$(resolve_plan "$JSON_A")
SHARED_A=$(printf '%s\n' "$PLAN_A" | awk "$AWK_PROG")
if [ "$SHARED_A" = "tests/test-shared-widget.sh" ]; then
  pass_msg "Case A: carve-out resolved to tests/test-shared-widget.sh"
else
  fail_msg "Case A: got carve-out '$SHARED_A' from selected plan body:"
  printf '%s\n' "$PLAN_A" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
echo "Case B: negative control -- no plan comment at all -> empty carve-out (default-deny preserved)"
inc
JSON_B=$(mk_comments_json "OWNER"$'\x1e'"$EVAL_BODY")
PLAN_B=$(resolve_plan "$JSON_B")
SHARED_B=$(printf '%s\n' "$PLAN_B" | awk "$AWK_PROG")
if [ -z "$PLAN_B" ] && [ -z "$SHARED_B" ]; then
  pass_msg "Case B: empty plan selection -> empty carve-out"
else
  fail_msg "Case B: expected empty plan+carve-out; got plan='$PLAN_B' shared='$SHARED_B'"
fi

# ---------------------------------------------------------------------------
echo "Case C: explicit PIPELINE_SPLIT_ROLE_SHARED_TESTS=\"\" (set-but-empty, mirroring Case B's empty carve-out threaded through the gate) still blocks a tampered locked test -- 'resolved: no exemptions'"
inc
if [ ! -f "$GATE" ]; then
  fail_msg "Case C: $GATE missing"
else
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  REPO="$WORKDIR/case-c"
  mkdir -p "$REPO/tests"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  git -C "$REPO" checkout -q -b base-anchor
  echo base > "$REPO/base.txt"
  echo "echo locked-v1" > "$REPO/tests/test-locked.sh"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "base"
  git -C "$REPO" checkout -q -b feature/issue-C
  echo "echo red-suite" > "$REPO/tests/test-red.sh"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "test(x): add failing suite [split-role-red] (#C)"
  echo "echo locked-v2-tampered" > "$REPO/tests/test-locked.sh"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "feat(x): green impl, tamper locked test (#C)"
  # $SHARED_B (Case B's resolved-empty carve-out) is exactly what Step 11.2b
  # would export as PIPELINE_SPLIT_ROLE_SHARED_TESTS in this scenario --
  # explicitly set, not merely left unexported.
  OUT_C=$( cd "$REPO" && PIPELINE_TEST_CMD="true" PIPELINE_SPLIT_ROLE_SHARED_TESTS="$SHARED_B" \
           bash "$GATE" C base-anchor tests 2>/dev/null )
  if [ "$OUT_C" = "SPLIT_ROLE=block ISSUE=C REASON=locked-test-modified" ]; then
    pass_msg "Case C: explicit set-but-empty export still blocks (no exemptions)"
  else
    fail_msg "Case C: expected block/locked-test-modified; got '$OUT_C'"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
