#!/bin/bash
set -euo pipefail

# Tests for #759: <!-- pipeline:path-hint=A|B|C --> advisory body hint.
# Layer 1 — static-grep assertions on skills/classify-issue/SKILL.md.
# Layer 2 — extract BEGIN-PATH-HINT-PARSE...END-PATH-HINT-PARSE block and
#           run it under synthetic ISSUE_BODY inputs (mirrors
#           test-classify-path-marker.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/../skills/classify-issue/SKILL.md"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_FILE" ]; then
  echo "ERROR: classify-issue SKILL.md not found at $SKILL_FILE" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

############################################################
# Layer 1 — static grep assertions
############################################################

echo "Layer 1 — SKILL.md static grep"

# (i) sentinel comments.
inc
if grep -qE '^[[:space:]]*# BEGIN-PATH-HINT-PARSE' "$SKILL_FILE" \
   && grep -qE '^[[:space:]]*# END-PATH-HINT-PARSE' "$SKILL_FILE"; then
  pass_msg "BEGIN-PATH-HINT-PARSE / END-PATH-HINT-PARSE sentinels present"
else
  fail_msg "missing BEGIN-PATH-HINT-PARSE or END-PATH-HINT-PARSE sentinel"
fi

# (ii) literal hint directive.
inc
if grep -qF 'pipeline:path-hint=' "$SKILL_FILE"; then
  pass_msg "literal pipeline:path-hint= present"
else
  fail_msg "literal pipeline:path-hint= missing"
fi

# (iii) pinned regex — Perl-style form.
inc
if grep -qF '<!--\s*pipeline:path-hint=[A-Ca-c]\s*-->' "$SKILL_FILE"; then
  pass_msg 'pinned regex documented: <!--\s*pipeline:path-hint=[A-Ca-c]\s*-->'
else
  fail_msg 'pinned regex (Perl-style) missing'
fi

# (iv) pinned regex — POSIX-equivalent form.
inc
if grep -qF '<!--[[:space:]]*pipeline:path-hint=[A-Ca-c][[:space:]]*-->' "$SKILL_FILE"; then
  pass_msg 'POSIX-equivalent pinned regex documented'
else
  fail_msg 'POSIX-equivalent pinned regex missing'
fi

# Slice the hint subsection: from BEGIN-PATH-HINT-PARSE region's prose.
# Use the whole file for advisory/prior/overridable presence near hint.
# (v) advisory / prior / overridable vocabulary present (advisory prior status).
for word in advisory prior overridable; do
  inc
  if grep -qiE "$word" "$SKILL_FILE"; then
    pass_msg "hint subsection establishes status word: $word"
  else
    fail_msg "missing status word: $word"
  fi
done

# (vi) step 4 documents the hint as a prior that is OUTRANKED by an explicit
# path label and the authoritative pipeline:path=D marker; never an override.
inc
if grep -qiE 'never an override|never short-circuits' "$SKILL_FILE"; then
  pass_msg "hint documented as never an override / never short-circuits"
else
  fail_msg "missing 'never an override' / 'never short-circuits' prose"
fi

inc
if grep -qF '<!-- pipeline:path=D -->' "$SKILL_FILE" \
   && grep -qiE 'explicit path label|path label \(row 1\)|row 1' "$SKILL_FILE"; then
  pass_msg "hint prose names both higher-precedence signals (label + path=D)"
else
  fail_msg "hint prose does not name both higher-precedence signals"
fi

# (vii) step 5 compose instructs recording an override rationale.
inc
if grep -qiE 'override rationale|create-issues hinted' "$SKILL_FILE"; then
  pass_msg "step 5 compose documents override rationale"
else
  fail_msg "missing override-rationale instruction in compose"
fi

############################################################
# Layer 2 — extract block and run synthetic ISSUE_BODY tests
############################################################

echo ""
echo "Layer 2 — sentinel block extraction + parser behavior"

PARSE_SCRIPT="$WORKDIR/parse-hint.sh"
awk '
  /^[[:space:]]*# BEGIN-PATH-HINT-PARSE/ { inblock = 1 }
  inblock { print }
  /^[[:space:]]*# END-PATH-HINT-PARSE/   { inblock = 0 }
' "$SKILL_FILE" > "$PARSE_SCRIPT"

echo 'printf "HINT_PATH=%s\n" "${HINT_PATH:-}"' >> "$PARSE_SCRIPT"

if ! [ -s "$PARSE_SCRIPT" ] || ! grep -q 'HINT_PATH' "$PARSE_SCRIPT"; then
  fail_msg "could not extract a runnable BEGIN-PATH-HINT-PARSE block (Layer 2 cannot proceed)"
  echo ""
  echo "================================"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  echo "================================"
  exit 1
fi

run_parse() {
  local body="$1"
  set +e
  env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    ISSUE_BODY="$body" \
    bash "$PARSE_SCRIPT" 2>"$WORKDIR/parse-err.txt"
  set -e
}

expect_hint() {
  local label="$1"
  local body="$2"
  local want="$3"
  inc
  local out
  out=$(run_parse "$body" | grep '^HINT_PATH=' | tail -1 | cut -d= -f2-)
  if [ "$out" = "$want" ]; then
    pass_msg "$label -> HINT_PATH=$want"
  else
    fail_msg "$label -> got HINT_PATH='$out', want '$want'"
  fi
}

expect_hint "padded hint A"             "<!-- pipeline:path-hint=A -->"   "A"
expect_hint "unpadded hint lowercase c" "<!--pipeline:path-hint=c-->"     "C"
expect_hint "padded hint B"             "<!-- pipeline:path-hint=B -->"   "B"
expect_hint "hint D rejected"           "<!-- pipeline:path-hint=D -->"   ""
expect_hint "hint Z rejected"           "<!-- pipeline:path-hint=Z -->"   ""
expect_hint "authoritative marker not a hint" "<!-- pipeline:path=A -->"  ""
expect_hint "empty body"                ""                                ""
expect_hint "inline (no HTML brackets)" "mentions pipeline:path-hint=A inline" ""

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
