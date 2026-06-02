#!/bin/bash
set -euo pipefail

# Tests for scripts/plan-campaign.sh (#835) — the leg partitioner.
#
# plan-campaign.sh shells out to scripts/plan-waves.sh --stage=execute
# --emit-edges to recover the per-issue blockers/files edge map, fetches each
# issue's path-class label, then greedily partitions issues into "legs" subject
# to (1) per-path-class caps, (2) dependency order, (3) same-leg file conflicts.
# It also exposes a `closure` subcommand that walks the edge map to a fixpoint.
#
# `gh` is replaced by a PATH-resident shim that reads canned JSON from
# $GH_ISSUE_DIR/<N>.json — the SAME shim covers the nested plan-waves.sh
# invocation (which also calls `gh issue view`).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/plan-campaign.sh"

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

# Helper: write a canned issue JSON.
# Args: dir, number, path_label (docs-only|quick-fix|multi-task|"" for B), body
write_issue() {
  local dir="$1" num="$2" path="$3" body="$4"
  local labels='[]'
  if [ -n "$path" ]; then
    labels=$(printf '[{"name":"%s"}]' "$path")
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

# =====================================================================
# Case 1: BC cap honored (default MAX_BC=2)
# Three PATH-B issues, no deps, no file conflicts. With MAX_BC=2 the first leg
# takes #1 and #2; #3 rolls to leg 2.
# =====================================================================
echo "Case 1: BC cap (default 2) caps a leg at 2 B-class issues"
S="$TMP/case1"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "" "Independent B work."
write_issue "$S" 2 "" "Independent B work."
write_issue "$S" 3 "" "Independent B work."
inc
if OUT=$(run_helper 1 2 3 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '#1, #2' \
     && ! echo "$L1" | grep -q '#3' \
     && echo "$L2" | grep -qE '#3'; then
    pass_msg "Case 1: leg 1 holds #1,#2; #3 rolls to leg 2 (BC=2 cap)"
  else
    fail_msg "Case 1: BC cap not honored"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# =====================================================================
# Case 2: AD cap honored independently of BC (default MAX_AD=5)
# Six PATH-A/D issues (docs-only / quick-fix), no deps, no conflicts. With
# MAX_AD=5 the first leg takes five; the sixth rolls to leg 2. Crucially the
# AD pool is accounted SEPARATELY from BC.
# =====================================================================
echo "Case 2: AD cap (default 5) caps a leg at 5 A/D-class issues, independent of BC"
S="$TMP/case2"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "docs-only" "Docs A."
write_issue "$S" 2 "quick-fix" "Quick D."
write_issue "$S" 3 "docs-only" "Docs A."
write_issue "$S" 4 "quick-fix" "Quick D."
write_issue "$S" 5 "docs-only" "Docs A."
write_issue "$S" 6 "quick-fix" "Quick D."
inc
if OUT=$(run_helper 1 2 3 4 5 6 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '\(BC=0 AD=5\)' \
     && echo "$L1" | grep -qE '#1, #2, #3, #4, #5' \
     && ! echo "$L1" | grep -q '#6' \
     && echo "$L2" | grep -qE '#6'; then
    pass_msg "Case 2: leg 1 holds 5 A/D issues (AD=5); #6 rolls to leg 2"
  else
    fail_msg "Case 2: AD cap not honored independently"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
