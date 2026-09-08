#!/bin/bash
set -euo pipefail

# Contract guard for issue #700 — PATH D is NOT exempt from the unified
# file-conflict serialization graph in scripts/plan-waves.sh.
#
# A `quick-fix` (PATH D) issue whose declared file paths COLLIDE with a PATH B
# issue's file must serialize into a LATER wave, exactly like any other issue.
# plan-waves.sh has no path-label gate, so this test LOCKS that contract: if the
# planner ever grew a "skip D in conflict detection" branch, this guard fails.
#
# If the planner already unifies the graph (current logic does — it never reads
# the quick-fix label), this test PASSES against current logic. That is the
# intended outcome for THIS guard; it documents/locks the contract.
#
# gh-shim harness mirrors tests/test-plan-waves.sh and
# tests/test-plan-waves-emit-edges.sh: `gh` replaced by a PATH-resident shim
# reading canned JSON from $GH_ISSUE_DIR/<N>.json.

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

run_helper() {
  bash "$HELPER" "$@"
}

# ---- Slate: a PATH B issue and a PATH D (quick-fix) issue colliding on a file.
# #1 = PATH B (no quick-fix label), touches scripts/shared.sh via a body
#      backtick.
# #2 = PATH D (quick-fix label), touches scripts/shared.sh via an
#      `## Affected areas` section (the path the planner extracts for execute).
# The shared file forces serialization: the lower-numbered issue (#1, B) lands
# in Wave 1; #2 (D) is deferred to a LATER wave. This proves D is NOT exempt
# from file-conflict serialization.
S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 '[{"name":"priority/P2"}]' \
  "PATH B standard work. Touches \`scripts/shared.sh\` only."
write_issue "$S" 2 '[{"name":"priority/P2"},{"name":"quick-fix"}]' \
  "PATH D quick fix.

## Affected areas
\`scripts/shared.sh\`
"

# ---- Case 1: colliding D issue serializes into a LATER wave than the B issue.
echo "Case 1: PATH D issue (#2) serializes after colliding PATH B issue (#1)"
inc
if OUT=$(run_helper --stage=execute 1 2 2>"$S/stderr1"); then
  W1=$(echo "$OUT" | grep -nE '^Wave [0-9]+: .*#1( |,|$)' | head -1 | cut -d: -f1 || true)
  W2=$(echo "$OUT" | grep -nE '^Wave [0-9]+: .*#2( |,|$)' | head -1 | cut -d: -f1 || true)
  # #1 must be in Wave 1; #2 must NOT share Wave 1 (it is deferred to Wave 2+).
  if echo "$OUT" | grep -qE '^Wave 1: execute #1' \
     && echo "$OUT" | grep -qE '^Wave 2: execute #2.*shares.*scripts/shared\.sh.*#1' \
     && ! echo "$OUT" | grep -qE '^Wave 1:.*#2'; then
    pass_msg "Case 1: #2 (D) deferred to Wave 2 sharing scripts/shared.sh with #1 (B)"
  else
    fail_msg "Case 1: D issue NOT serialized after B issue (path-label exemption regression?)"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr1"
fi

# ---- Case 2: --emit-edges surfaces the D issue's shared-file edge.
echo "Case 2: --emit-edges emits 'EDGE #2 ... files=...shared...' for the D issue"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 2>"$S/stderr2"); then
  if echo "$OUT" | grep -qE '^EDGE #2 .* files=.*scripts/shared\.sh'; then
    pass_msg "Case 2: D issue's EDGE line carries the shared file path"
  else
    fail_msg "Case 2: missing 'EDGE #2 ... files=...scripts/shared.sh'"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr2"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
