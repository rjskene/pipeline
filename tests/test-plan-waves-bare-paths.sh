#!/bin/bash
set -euo pipefail

# Regression guard for issue #1006 — Files-to-change extraction must catch bare
# file paths (not backtick-wrapped) and reject backtick-wrapped reason symbols.
#
# Root cause: the `**Files to change:**` branch (L128-137) extracted only
# backtick-wrapped tokens, so:
#   - bare paths like `assets/dashboard/pages/legal.page.js` were MISSED
#   - backticked reason symbols like `data.map`, `next_due` (no slash, no known
#     extension) leaked into the file set, poisoning conflict detection.
#
# Fix: hoist FILE_PATH_RE above both branches; in the plan-comment branch split
# each bullet on whitespace, strip backticks, and keep only FILE_PATH_RE-
# matching tokens — bare paths caught, reason symbols rejected.
#
# gh-shim harness mirrors tests/test-plan-waves-emit-edges.sh and
# tests/test-plan-waves-empty-backtick-files.sh.

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

# Helper: write a canned issue JSON. Args: dir, number, labels-json, body
write_issue() {
  local dir="$1" num="$2" labels="$3" body="$4"
  jq -n \
    --arg num "$num" \
    --arg body "$body" \
    --argjson labels "$labels" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: $labels}' \
    > "$dir/$num.json"
}

# Helper: write a canned comments JSON carrying a single plan comment body.
write_plan_comment() {
  local dir="$1" num="$2" plan_body="$3"
  jq -n --arg body "$plan_body" \
    '{comments: [{body: $body}]}' \
    > "$dir/$num.comments.json"
}

run_helper() {
  bash "$HELPER" "$@"
}

S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"

# Shared plan comment body — matches the shape from the repro in issue #1006:
#   path (bare) — reason with `backticked` `symbols`
PLAN_WITH_BARE_PATHS="## Implementation Plan

**Files to change:**
- assets/dashboard/pages/legal.page.js — masthead headline from \`meta.next_deadline\`; MATERIALIZE \`next_due\` onto each record in \`data.map\`; flip default \`sort\` to urgency (\`key:\"next_due\"\`, \`dir:1\`).
- subagents/legal/scripts/matters/projection.py — add \`next_deadline\`/\`overdue\` keys to \`build_summary\`.

**Tasks (ordered):**
- do the thing
"

# Issue #1: uses the problematic plan format above.
write_issue "$S" 1 '[{"name":"priority/P2"}]' \
  "Issue that edits legal.page.js and projection.py."
write_plan_comment "$S" 1 "$PLAN_WITH_BARE_PATHS"

# ---- Case 1: EDGE for a single issue with bare-path plan bullet contains the
#      bare paths, NOT the backticked reason symbols ----
echo "Case 1: EDGE contains bare path tokens, not backticked reason symbols"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2>"$S/stderr1"); then
  e1=$(echo "$OUT" | grep -E '^EDGE #1 ' || true)
  # The path-shaped tokens should appear
  has_legal=$(echo "$e1" | grep -c 'legal\.page\.js' || true)
  has_proj=$(echo "$e1" | grep -c 'projection\.py' || true)
  # The backtick-only reason symbols must NOT appear as file entries
  has_data_map=$(echo "$e1" | grep -c 'data\.map' || true)
  has_next_due=$(echo "$e1" | grep -c 'next_due' || true)
  has_sort=$(echo "$e1" | grep -cw 'sort' || true)
  if [ "$has_legal" -ge 1 ] && [ "$has_proj" -ge 1 ] \
     && [ "$has_data_map" -eq 0 ] && [ "$has_next_due" -eq 0 ] \
     && [ "$has_sort" -eq 0 ]; then
    pass_msg "Case 1: EDGE contains bare paths; reason symbols absent"
  else
    fail_msg "Case 1: wrong file tokens in EDGE"
    echo "    edge: [$e1]"
    echo "    has_legal=$has_legal has_proj=$has_proj has_data_map=$has_data_map has_next_due=$has_next_due has_sort=$has_sort"
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr1"
fi

# ---- Case 2: Two issues sharing a bare path get a shared-file edge (serialized)
#      Issue #2 also edits legal.page.js (bare, in its plan comment) → must be
#      serialized after #1, NOT placed in the same wave. ----
echo "Case 2: two issues sharing a bare path are serialized, not parallel"
inc
# Issue #2: also edits legal.page.js (same bare path), plus another file.
PLAN_2="## Implementation Plan

**Files to change:**
- assets/dashboard/pages/legal.page.js — fix \`renderHeader\` call signature.
- assets/dashboard/components/legal-nav.tsx — update nav link \`href\` values.

**Tasks (ordered):**
- fix header
"
write_issue "$S" 2 '[{"name":"priority/P2"}]' \
  "Issue that also edits legal.page.js."
write_plan_comment "$S" 2 "$PLAN_2"

if OUT=$(run_helper --stage=execute 1 2 2>"$S/stderr2"); then
  # #1 and #2 share legal.page.js → they cannot be in the same wave.
  # Wave 1 must contain exactly one of them; a later wave contains the other.
  wave1_line=$(echo "$OUT" | grep -E '^Wave 1: ' || true)
  both_in_wave1=$(echo "$wave1_line" | grep -c '#2' || true)
  has_wave2=$(echo "$OUT" | grep -cE '^Wave 2: ' || true)
  if [ "$both_in_wave1" -eq 0 ] && [ "$has_wave2" -ge 1 ]; then
    pass_msg "Case 2: issues with shared bare path are serialized across waves"
  else
    fail_msg "Case 2: issues with shared bare path were NOT serialized"
    echo "    wave1: [$wave1_line]"
    echo "    both_in_wave1=$both_in_wave1 has_wave2=$has_wave2"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr2"
fi

# ---- Case 3: EDGE for both issues shows the shared bare path ----
echo "Case 3: --emit-edges shows legal.page.js in both EDGE lines"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 2>"$S/stderr3"); then
  e1=$(echo "$OUT" | grep -E '^EDGE #1 ' || true)
  e2=$(echo "$OUT" | grep -E '^EDGE #2 ' || true)
  if echo "$e1" | grep -q 'legal\.page\.js' \
     && echo "$e2" | grep -q 'legal\.page\.js'; then
    pass_msg "Case 3: shared bare path appears in both EDGE lines"
  else
    fail_msg "Case 3: shared bare path missing from one or both EDGE lines"
    echo "    e1: [$e1]"
    echo "    e2: [$e2]"
  fi
else
  rc=$?
  fail_msg "Case 3: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr3"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
