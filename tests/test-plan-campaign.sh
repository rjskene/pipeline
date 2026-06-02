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

# =====================================================================
# Case 3: dependency order — a same-leg blocker defers the dependent to the
# NEXT leg. #1 and #2 are both PATH-B, no file conflict, so absent deps they
# would share leg 1 (BC cap is 2). But #2 is `blocked by #1`; since #1 is
# placed in THIS same leg, #2 must defer to leg 2 (a same-leg blocker is not
# yet satisfied). Leg 2's single #2 line carries the `blocked by #1` reason.
# =====================================================================
echo "Case 3: a same-leg blocker defers the dependent to the next leg"
S="$TMP/case3"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "" "Independent B; touches \`x.sh\`."
write_issue "$S" 2 "" "B work; touches \`y.sh\`. blocked by #1 for ordering."
inc
if OUT=$(run_helper 1 2 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '^Leg 1: #1 ' \
     && ! echo "$L1" | grep -q '#2' \
     && echo "$L2" | grep -qE '^Leg 2: #2 ' \
     && echo "$L2" | grep -q 'blocked by #1'; then
    pass_msg "Case 3: #2 deferred to leg 2 with 'blocked by #1' reason"
  else
    fail_msg "Case 3: same-leg blocker did not defer dependent"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 3: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# =====================================================================
# Case 4: same-leg file conflict serializes. #1 and #2 are both PATH-B with
# no deps (BC cap 2 would allow them together), but BOTH touch `shared.sh`.
# The second placed (#2) shares a file with an already-placed leg member, so
# it rolls to leg 2 with a `shares shared.sh with #1` reason.
# =====================================================================
echo "Case 4: same-leg file conflict serializes the second issue"
S="$TMP/case4"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "" "Touches \`shared.sh\` only."
write_issue "$S" 2 "" "Also touches \`shared.sh\` (conflict)."
inc
if OUT=$(run_helper 1 2 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '^Leg 1: #1 ' \
     && ! echo "$L1" | grep -q '#2' \
     && echo "$L2" | grep -qE '^Leg 2: #2 ' \
     && echo "$L2" | grep -q 'shares shared.sh with #1'; then
    pass_msg "Case 4: #2 serialized to leg 2 with 'shares shared.sh with #1'"
  else
    fail_msg "Case 4: same-leg file conflict did not serialize"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 4: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# =====================================================================
# Case 5: a dangling blocker (referenced issue NOT in the input set) is treated
# as SATISFIED. #1 is `blocked by #99`, but #99 is not in {1}. #1 must still be
# placed in leg 1 (no deferral, no serial reason from the dangling blocker).
# =====================================================================
echo "Case 5: dangling/out-of-set blocker is treated as satisfied"
S="$TMP/case5"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "" "B work. blocked by #99 (out of set)."
inc
if OUT=$(run_helper 1 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  if echo "$L1" | grep -qE '^Leg 1: #1 ' \
     && ! echo "$L1" | grep -q 'blocked by'; then
    pass_msg "Case 5: #1 placed in leg 1; dangling blocker #99 did not defer it"
  else
    fail_msg "Case 5: dangling blocker not treated as satisfied"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 5: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# =====================================================================
# Case 6: CLI flags --max-bc / --max-ad OVERRIDE the env caps.
# Three PATH-B issues, no deps/conflicts. With env MAX_BC=2 they would split
# 2+1. We set env MAX_BC=2 but pass --max-bc=3 on the CLI: the override must
# win, putting all three in a single leg (BC=3).
# =====================================================================
echo "Case 6: --max-bc CLI flag overrides PIPELINE_CAMPAIGN_MAX_BC env"
S="$TMP/case6"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 "" "Independent B."
write_issue "$S" 2 "" "Independent B."
write_issue "$S" 3 "" "Independent B."
inc
if OUT=$(PIPELINE_CAMPAIGN_MAX_BC=2 run_helper --max-bc=3 1 2 3 2>"$S/err"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '#1, #2, #3' \
     && echo "$L1" | grep -qE '\(BC=3 AD=0\)' \
     && [ -z "$L2" ]; then
    pass_msg "Case 6: --max-bc=3 beat env=2; all three in one leg (BC=3)"
  else
    fail_msg "Case 6: CLI --max-bc did not override env"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 6: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# Symmetric AD override: env MAX_AD=5 but --max-ad=2 forces a 2+1 split of 3
# PATH-A/D issues.
echo "Case 6b: --max-ad CLI flag overrides PIPELINE_CAMPAIGN_MAX_AD env"
write_issue "$S" 4 "docs-only" "Docs A."
write_issue "$S" 5 "docs-only" "Docs A."
write_issue "$S" 6 "docs-only" "Docs A."
inc
if OUT=$(PIPELINE_CAMPAIGN_MAX_AD=5 run_helper --max-ad=2 4 5 6 2>"$S/errb"); then
  L1=$(echo "$OUT" | grep -E '^Leg 1: ' || true)
  L2=$(echo "$OUT" | grep -E '^Leg 2: ' || true)
  if echo "$L1" | grep -qE '#4, #5' \
     && echo "$L1" | grep -qE '\(BC=0 AD=2\)' \
     && echo "$L2" | grep -qE '#6'; then
    pass_msg "Case 6b: --max-ad=2 beat env=5; #4,#5 in leg 1 (AD=2), #6 rolls"
  else
    fail_msg "Case 6b: CLI --max-ad did not override env"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 6b: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/errb"
fi

# =====================================================================
# Case 7: scoped-halt `closure` — fixpoint walk, multi-hop, via BOTH a
# blocked-by edge AND a file-conflict edge.
#   #10  = the blocked issue (seed).
#   #11  = `blocked by #10`            -> 1st hop (blocker edge to seed)
#   #12  = shares `f.sh` with #11      -> 2nd hop (file edge to a member)
#   #13  = unrelated                   -> must NOT enter the closure
# Closure of {#10} = {10, 11, 12}; #13 excluded.
# =====================================================================
echo "Case 7: closure subcommand — multi-hop transitive (blocker + file edge)"
S="$TMP/case7"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 10 "" "Seed issue; touches \`seed.sh\`."
write_issue "$S" 11 "" "Touches \`f.sh\`. blocked by #10."
write_issue "$S" 12 "" "Also touches \`f.sh\` (file edge to #11)."
write_issue "$S" 13 "" "Unrelated; touches \`other.sh\`."
inc
if OUT=$(run_helper closure 10 10 11 12 13 2>"$S/err"); then
  GOT=$(echo "$OUT" | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ' | sed 's/ *$//')
  if [ "$GOT" = "10 11 12" ]; then
    pass_msg "Case 7: closure(10) = {10,11,12}; #13 excluded"
  else
    fail_msg "Case 7: wrong closure set (got: [$GOT], expected: [10 11 12])"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 7: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/err"
fi

# Case 7b: --closure=<N> flag form yields the same closure set.
echo "Case 7b: --closure=<N> flag form equals the subcommand form"
inc
if OUT=$(run_helper --closure=10 10 11 12 13 2>"$S/errb"); then
  GOT=$(echo "$OUT" | grep -E '^[0-9]+$' | sort -n | tr '\n' ' ' | sed 's/ *$//')
  if [ "$GOT" = "10 11 12" ]; then
    pass_msg "Case 7b: --closure=10 = {10,11,12}"
  else
    fail_msg "Case 7b: wrong closure set (got: [$GOT])"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 7b: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/errb"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
