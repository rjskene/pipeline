#!/bin/bash
set -uo pipefail

# Tests for the PIPELINE_OPTIMISTIC_EXECUTE knob in scripts/plan-waves.sh (#1536).
#
# Default (`true`, or unset): the execute stage no longer serializes issues on
# shared FILES — conflicts are resolved by a merge-time rebase instead. Explicit
# `blocked by #N` edges still serialize. `--emit-edges` is byte-identical across
# knob values. `false` restores the legacy file-conflict waves.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/plan-waves.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh shim (mirrors tests/test-plan-waves.sh): `gh issue view <N> ... --json ...`
# emits $GH_ISSUE_DIR/<N>.json; a bare `comments` token serves
# $GH_ISSUE_DIR/<N>.comments.json (or an empty comments list).
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
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
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo "shim: no canned JSON for issue $n" >&2
  exit 1
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

write_issue() {
  local dir="$1" num="$2" body="$3"
  jq -n --arg num "$num" --arg body "$body" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: [{name: "priority/P2"}]}' \
    > "$dir/$num.json"
}

# Shared slate: #1 and #2 both touch shared/common.sh; #3 is blocked by #1.
D="$TMP/slate"; mkdir -p "$D"; export GH_ISSUE_DIR="$D"
write_issue "$D" 1 "Edits \`shared/common.sh\` only."
write_issue "$D" 2 "Also edits \`shared/common.sh\` here."
write_issue "$D" 3 "Touches \`other/b.sh\`. blocked by #1 for ordering."

run_knob() {  # $1 = knob value or "UNSET"; rest = helper args
  local k="$1"; shift
  if [ "$k" = "UNSET" ]; then
    env -u PIPELINE_OPTIMISTIC_EXECUTE bash "$HELPER" "$@" 2>"$TMP/stderr"
  else
    PIPELINE_OPTIMISTIC_EXECUTE="$k" bash "$HELPER" "$@" 2>"$TMP/stderr"
  fi
}

check() {  # $1 = label, $2 = output, $3 = ERE that must match a line
  inc
  if printf '%s\n' "$2" | grep -qE "$3"; then
    pass_msg "$1"
  else
    fail_msg "$1 (missing /$3/)"
    printf '%s\n' "$2" | sed 's/^/      /'
  fi
}

check_absent() {  # $1 = label, $2 = output, $3 = ERE that must NOT match
  inc
  if printf '%s\n' "$2" | grep -qE "$3"; then
    fail_msg "$1 (unexpected /$3/)"
    printf '%s\n' "$2" | sed 's/^/      /'
  else
    pass_msg "$1"
  fi
}

echo "O1: knob true => shared-file issues run in parallel"
OUT=$(run_knob true 1 2)
check "O1 parallel wave" "$OUT" '^Wave 1: execute #1, #2 in parallel$'
check_absent "O1 no Wave 2" "$OUT" '^Wave 2:'

echo "O2: knob true => explicit blocker still serializes"
OUT=$(run_knob true 1 3)
check "O2 blocker wave" "$OUT" '^Wave 2: execute #3 \(serial — blocked by #1\)$'

echo "O3: knob unset => same as true"
OUT=$(run_knob UNSET 1 2)
check "O3 default parallel" "$OUT" '^Wave 1: execute #1, #2 in parallel$'
check_absent "O3 no shares reason" "$OUT" 'shares'

echo "O4: knob false => legacy file-conflict wave"
OUT=$(run_knob false 1 2)
check "O4 legacy serial" "$OUT" '^Wave 2: execute #2 \(serial — shares shared/common.sh with #1\)$'

echo "O5: --emit-edges identical across knob values"
E_TRUE=$(run_knob true --emit-edges 1 2 3)
E_FALSE=$(run_knob false --emit-edges 1 2 3)
E_UNSET=$(run_knob UNSET --emit-edges 1 2 3)
check "O5 files edge present" "$E_TRUE" '^EDGE #1 blockers=- files=shared/common.sh$'
inc
if [ "$E_TRUE" = "$E_FALSE" ] && [ "$E_TRUE" = "$E_UNSET" ]; then
  pass_msg "O5 byte-identical edges"
else
  fail_msg "O5 edges differ across knob values"
  printf 'true:\n%s\nfalse:\n%s\nunset:\n%s\n' "$E_TRUE" "$E_FALSE" "$E_UNSET" | sed 's/^/      /'
fi

echo "O6: --stage=plan unaffected by the knob"
P_TRUE=$(run_knob true --stage=plan 1 2 3)
P_FALSE=$(run_knob false --stage=plan 1 2 3)
check "O6 plan parallel" "$P_TRUE" '^Wave 1: plan #1, #2 in parallel$'
inc
if [ "$P_TRUE" = "$P_FALSE" ]; then
  pass_msg "O6 plan output identical across knob values"
else
  fail_msg "O6 plan output differs"
fi

echo
echo "Results: $PASS/$TESTS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
