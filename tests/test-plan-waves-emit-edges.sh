#!/bin/bash
set -euo pipefail

# Tests for the additive --emit-edges machine-readable mode of
# scripts/plan-waves.sh (#626).
#
# Motivation: plan-waves.sh computes every dependency edge internally
# (BLOCKERS[$N] + FILES[$N]) but only surfaces per-issue `reason` strings for
# SINGLE-issue waves. An issue grouped into a MULTI-issue wave loses its edge
# in stdout. --emit-edges emits every input issue's edges regardless of wave
# grouping, in input order, so callers (fullsend) can recover the full graph.
#
# `gh` is replaced by a PATH-resident shim that reads canned JSON from
# $GH_ISSUE_DIR/<N>.json keyed on the issue number passed to `gh issue view N`,
# mirroring tests/test-plan-waves.sh.

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

run_helper() {
  bash "$HELPER" "$@"
}

# ---- Slate reproducing the multi-issue-wave edge-loss gap ----
# #1 and #2 both touch `a.sh` (so #2 cannot share Wave 1 with #1).
# #4 independently touches `a.sh` too.
# #3 is `blocked by #1` and touches `b.sh`.
# Result: #2 and #4 defer together into a MULTI-issue later wave; their edges
# (#2 shares a.sh; #4 shares a.sh) are NOT surfaced as per-issue reasons in the
# default output — only --emit-edges recovers them.
S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "priority/P2" "Touches \`a.sh\` only."
write_issue "$S" 2 "priority/P2" "Also touches \`a.sh\` (conflict)."
write_issue "$S" 3 "priority/P2" "Touches \`b.sh\`. blocked by #1 for the migration."
write_issue "$S" 4 "priority/P2" "Also touches \`a.sh\` (conflict)."

# ---- Case 1: --emit-edges emits one EDGE line per input issue, in input order,
#      carrying blockers for #3 and file edges for #2 ----
echo "Case 1: --emit-edges recovers edges for multi-issue-wave members"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 3 4 2>"$S/stderr1"); then
  edge_count=$(echo "$OUT" | grep -cE '^EDGE #[0-9]+ ' || true)
  if [ "$edge_count" -eq 4 ] \
     && echo "$OUT" | grep -qE '^EDGE #3 blockers=1 ' \
     && echo "$OUT" | grep -qE '^EDGE #2 .* files=.*a\.sh'; then
    pass_msg "Case 1: 4 EDGE lines; #3 blockers=1; #2 files include a.sh"
  else
    fail_msg "Case 1: missing expected EDGE lines (got $edge_count EDGE lines)"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr1"
fi

# ---- Case 2: exact token format; empty blockers/files render as `-` ----
echo "Case 2: exact 'EDGE #<N> blockers=<csv-or-\"-\"> files=<csv-or-\"-\">' shape"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 3 4 2>"$S/stderr2"); then
  # #1: no blockers, touches a.sh.
  e1=$(echo "$OUT" | grep -E '^EDGE #1 ' || true)
  # #3: blocked by #1, touches b.sh.
  e3=$(echo "$OUT" | grep -E '^EDGE #3 ' || true)
  if [ "$e1" = "EDGE #1 blockers=- files=a.sh" ] \
     && [ "$e3" = "EDGE #3 blockers=1 files=b.sh" ]; then
    pass_msg "Case 2: literal shape correct; empty blockers render as '-'"
  else
    fail_msg "Case 2: token shape mismatch"
    echo "    e1: [$e1]"
    echo "    e3: [$e3]"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr2"
fi

# ---- Case 3: multi-issue-wave recoverability cross-check ----
# #2 and #3 land together in a multi-issue parallel wave. The human-readable
# output only surfaces per-issue reasons for SINGLE-issue waves, so BOTH #2's
# "shares a.sh" file edge AND #3's "blocked by #1" edge are dropped from that
# reasonless "in parallel" line. --emit-edges still carries both.
echo "Case 3: default emits reasonless multi-issue wave; --emit-edges keeps edges"
inc
DEFAULT_OUT=$(run_helper --stage=execute 1 2 3 4 2>"$S/stderr3d" || true)
EDGE_OUT=$(run_helper --stage=execute --emit-edges 1 2 3 4 2>"$S/stderr3e" || true)
# The multi-issue wave line for #2/#3 carries NO per-issue reason.
WAVE_LINE=$(echo "$DEFAULT_OUT" | grep -E '^Wave [0-9]+: execute #2, #3 in parallel$' || true)
if [ -n "$WAVE_LINE" ] \
   && ! echo "$WAVE_LINE" | grep -q 'blocked by' \
   && ! echo "$WAVE_LINE" | grep -q 'shares' \
   && echo "$EDGE_OUT" | grep -qE '^EDGE #2 .* files=.*a\.sh' \
   && echo "$EDGE_OUT" | grep -qE '^EDGE #3 blockers=1 '; then
  pass_msg "Case 3: multi-issue-wave edges (#2 file, #3 blocker) lost in default, recovered by --emit-edges"
else
  fail_msg "Case 3: expected reasonless multi-issue wave + recovered edges"
  echo "    default:"; echo "$DEFAULT_OUT" | sed 's/^/      /'
  echo "    emit-edges:"; echo "$EDGE_OUT" | sed 's/^/      /'
fi

# ---- Case 4: backward compat — default run emits NO EDGE lines, normal waves ----
echo "Case 4: no --emit-edges → no EDGE lines, normal Wave output"
inc
if OUT=$(run_helper --stage=execute 1 2 3 4 2>"$S/stderr4"); then
  if ! echo "$OUT" | grep -qE '^EDGE ' \
     && echo "$OUT" | grep -qE '^Wave 1: execute '; then
    pass_msg "Case 4: default output unchanged in shape (no EDGE lines)"
  else
    fail_msg "Case 4: default output regressed"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 4: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr4"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
