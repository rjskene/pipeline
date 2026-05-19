#!/bin/bash
set -euo pipefail

# Tests for scripts/plan-waves.sh — the wave planner that takes a list of issue
# numbers, fetches metadata via `gh`, and emits a wave plan honoring
# priority tiers, explicit blockers, and file-overlap conflicts.
#
# `gh` is replaced by a PATH-resident shim that reads canned JSON from
# $GH_ISSUE_DIR/<N>.json keyed on the issue number passed to `gh issue view N`.

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

# gh shim: parses `gh issue view <N> --repo ... --json ...` and emits
# the canned JSON at $GH_ISSUE_DIR/<N>.json.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
# Args look like: issue view 42 --repo owner/repo --json number,title,body,labels
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
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
  # jq-compose to keep body safe
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

# ---- Case A: three issues, distinct files, identical priority ----
echo "Case A: distinct files + equal priority → single parallel wave"
inc
A="$TMP/case-a"; mkdir -p "$A"; export GH_ISSUE_DIR="$A"
write_issue "$A" 1 "priority/P2" "Touches \`scripts/a.sh\` only."
write_issue "$A" 2 "priority/P2" "Touches \`scripts/b.sh\` only."
write_issue "$A" 3 "priority/P2" "Touches \`scripts/c.sh\` only."

if OUT=$(run_helper 1 2 3 2>"$A/stderr"); then
  if echo "$OUT" | grep -qE "^Wave 1: classify #1, #2, #3 in parallel$" \
     && ! echo "$OUT" | grep -qE "^Wave 2:"; then
    pass_msg "Case A: emitted single parallel Wave 1"
  else
    fail_msg "Case A: unexpected output"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case A: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$A/stderr"
fi

# ---- Case B: file overlap forces serialization ----
echo "Case B: shared file path → later number serializes"
inc
B="$TMP/case-b"; mkdir -p "$B"; export GH_ISSUE_DIR="$B"
write_issue "$B" 1 "priority/P2" "Touches \`scripts/x.sh\` only."
write_issue "$B" 2 "priority/P2" "Affects \`shared/common.sh\` here."
write_issue "$B" 3 "priority/P2" "Also affects \`shared/common.sh\` (conflict)."

if OUT=$(run_helper 1 2 3 2>"$B/stderr"); then
  if echo "$OUT" | grep -qE "^Wave 1: classify #1, #2 in parallel$" \
     && echo "$OUT" | grep -qE "^Wave 2: classify #3.*shares.*shared/common.sh.*#2"; then
    pass_msg "Case B: #3 serialized into Wave 2 due to shared file"
  else
    fail_msg "Case B: unexpected output"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case B: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$B/stderr"
fi

# ---- Case C: explicit blocker ----
echo "Case C: explicit 'blocked by #1' on #2 → #1 Wave 1, #2 Wave 2"
inc
C="$TMP/case-c"; mkdir -p "$C"; export GH_ISSUE_DIR="$C"
write_issue "$C" 1 "priority/P2" "Touches \`a.sh\` only."
write_issue "$C" 2 "priority/P2" "Touches \`b.sh\`. blocked by #1 for the migration."

if OUT=$(run_helper 1 2 2>"$C/stderr"); then
  if echo "$OUT" | grep -qE "^Wave 1: classify #1 in parallel$|^Wave 1: classify #1$" \
     && echo "$OUT" | grep -qE "^Wave 2: classify #2.*blocked by #1"; then
    pass_msg "Case C: #2 deferred to Wave 2 with 'blocked by #1' reason"
  else
    fail_msg "Case C: unexpected output"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case C: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$C/stderr"
fi

# ---- Case D: P0 jumps to Wave 1, P2 issues defer ----
echo "Case D: priority/P0 on #3 → #3 in Wave 1, P2 in Wave 2"
inc
D="$TMP/case-d"; mkdir -p "$D"; export GH_ISSUE_DIR="$D"
write_issue "$D" 1 "priority/P2" "Touches \`p2a.sh\`."
write_issue "$D" 2 "priority/P2" "Touches \`p2b.sh\`."
write_issue "$D" 3 "priority/P0" "Touches \`p0.sh\` urgently."

if OUT=$(run_helper 1 2 3 2>"$D/stderr"); then
  if echo "$OUT" | grep -qE "^Wave 1: classify #3" \
     && echo "$OUT" | grep -qE "^Wave 2: classify #1, #2 in parallel$"; then
    pass_msg "Case D: P0 #3 in Wave 1, P2 #1+#2 parallel in Wave 2"
  else
    fail_msg "Case D: unexpected output"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case D: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$D/stderr"
fi

# ---- Case E: dangling blocker (blocker not in input list) ----
echo "Case E: 'blocked by #99' where #99 is not in input → place in Wave 1"
inc
E="$TMP/case-e"; mkdir -p "$E"; export GH_ISSUE_DIR="$E"
write_issue "$E" 1 "priority/P2" "Touches \`only.sh\`. blocked by #99 (external)."

if OUT=$(run_helper 1 2>"$E/stderr"); then
  if echo "$OUT" | grep -qE "^Wave 1: classify #1"; then
    pass_msg "Case E: dangling blocker treated as satisfied; #1 placed in Wave 1"
  else
    fail_msg "Case E: unexpected output"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case E: helper exited $rc (dangling blocker should not deadlock)"
  echo "    stderr:"; sed 's/^/      /' "$E/stderr"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
