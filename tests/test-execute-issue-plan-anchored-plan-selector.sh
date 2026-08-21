#!/bin/bash
set -euo pipefail

# Regression guard (#1247): the plan-comment fetch in Step 1 of
# skills/execute-issue-plan/SKILL.md must select the plan comment by
# ANCHORED HEADING, not by loose substring. #1240 fixed the identical defect
# class in scripts/plan-waves.sh and shipped scripts/select-plan-comment.sh.
# This SKILL.md call site carried the same `contains("## Implementation
# Plan")) | last` selector: `evaluate-issue-plan` / `evaluate-issue-pr`
# routinely QUOTE that heading inside their own `## Plan Evaluation` /
# `## Evaluation` comment, and being the LATER comment it won the selection —
# so the execute stage could implement the reviewer's prose instead of the
# plan. Observed live (per #1247) on #1225, #1230, #1239, #1188.
#
# This test EXTRACTS the literal fenced ```bash``` block under Step 1's
# "Fetch the approved plan" and EXECUTES it (byte-for-byte, modulo the <N>
# placeholder) against a `gh` shim carrying a plan comment followed by a
# later eval comment that quotes the heading inline. Static assertions pin
# the call-idiom (reuse scripts/select-plan-comment.sh, no reimplementation).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

echo "Test 1: SKILL.md exists"
inc
if [ -f "$SKILL" ]; then
  pass_msg "SKILL.md found"
else
  fail_msg "SKILL.md missing at $SKILL"
fi

# Extract the fenced ```bash``` block immediately following the "Fetch the
# approved plan" step-1 heading.
STEP1_BLOCK=$(awk '
  /Fetch the approved plan/ { found = 1 }
  found && !in_block && /^[[:space:]]*```bash[[:space:]]*$/ { in_block = 1; next }
  in_block && /^[[:space:]]*```[[:space:]]*$/ { exit }
  in_block { print }
' "$SKILL")

echo "Test 2: Step 1 block found and non-empty"
inc
if [ -n "$STEP1_BLOCK" ]; then
  pass_msg "Step 1 plan-fetch bash block extracted"
else
  fail_msg "Step 1 plan-fetch bash block not found (heading text moved?)"
fi

echo "Test 3: Step 1 block does not reimplement the loose contains(...) | last selector"
inc
if ! printf '%s\n' "$STEP1_BLOCK" | grep -qF 'contains("## Implementation Plan"))] | last'; then
  pass_msg "loose contains(...) | last selector absent from Step 1 block"
else
  fail_msg "Step 1 block still contains the loose contains(...) | last selector"
fi

echo "Test 4: Step 1 block reuses scripts/select-plan-comment.sh"
inc
if printf '%s\n' "$STEP1_BLOCK" | grep -qF 'scripts/select-plan-comment.sh'; then
  pass_msg "Step 1 block invokes scripts/select-plan-comment.sh"
else
  fail_msg "Step 1 block does not invoke scripts/select-plan-comment.sh"
fi

# ---- Behavioral: execute the extracted block against a gh shim ----

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim: supports both the OLD shape (`gh issue view N --json comments
# --jq '<filter>'`, filtering server-side) and the NEW shape (`gh issue view
# N --json comments` piped to an external selector) by honoring --jq itself
# when present, and emitting raw canned JSON otherwise.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  jqfilter=""
  args=("$@")
  for i in "${!args[@]}"; do
    if [ "${args[$i]}" = "--jq" ]; then
      jqfilter="${args[$((i + 1))]}"
    fi
  done
  if [ -n "$jqfilter" ]; then
    jq -r "$jqfilter" "$GH_COMMENTS_JSON"
  else
    cat "$GH_COMMENTS_JSON"
  fi
  exit 0
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"

PLAN_ALPHA=$(cat <<'EOF'
## Implementation Plan

**Files to change:**
- `scripts/alpha.sh` — the real target

**Estimated effort:** 1 hour
EOF
)

# The observed real-world shape (#1225/#1230/#1239/#1188): a LATER
# `## Plan Evaluation` comment quoting the plan heading INLINE, with no
# `**Files to change:**` block of its own.
EVAL_INLINE=$(cat <<'EOF'
## Plan Evaluation

**Verdict:** Approved

Round-2 re-evaluation of the latest `## Implementation Plan` on #1240.
EOF
)

jq -n --arg a "$PLAN_ALPHA" --arg b "$EVAL_INLINE" \
  '{comments: [{body: $a, createdAt: "2026-05-22T00:00:00Z"}, {body: $b, createdAt: "2026-05-23T00:00:00Z"}]}' \
  > "$TMP/comments.json"

RUN_FILE="$TMP/step1-block.sh"
printf '%s\n' "$STEP1_BLOCK" | sed 's/<N>/42/g' > "$RUN_FILE"

echo "Test 5: extracted Step 1 block selects the PLAN comment, not the later eval-quote decoy"
inc
OUT=""
RC=0
OUT=$(PATH="$TMP/bin:$PATH" \
      PIPELINE_REPO="rjskene/pipeline" \
      CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      GH_COMMENTS_JSON="$TMP/comments.json" \
      bash "$RUN_FILE" 2>"$TMP/stderr") || RC=$?
ok=0
if [ "$RC" -eq 0 ] \
   && printf '%s\n' "$OUT" | grep -qF 'scripts/alpha.sh' \
   && ! printf '%s\n' "$OUT" | grep -qF 'Plan Evaluation'; then
  ok=1
fi
if [ "$ok" -eq 1 ]; then
  pass_msg "Step 1 block selected the plan comment (scripts/alpha.sh), not the eval decoy"
else
  fail_msg "Step 1 block did NOT select the plan comment"
  echo "    rc=$RC"
  echo "    stdout:"; printf '%s\n' "$OUT" | sed 's/^/      /'
  if [ -s "$TMP/stderr" ]; then
    echo "    stderr:"; sed 's/^/      /' "$TMP/stderr"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
