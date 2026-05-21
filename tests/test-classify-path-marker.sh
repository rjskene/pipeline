#!/bin/bash
set -euo pipefail

# Tests for Proposal B in #354: <!-- pipeline:path=X --> body-marker override.
# Layer 1 — static-grep assertions on skills/classify-issue/SKILL.md.
# Layer 2 — extract BEGIN-PATH-MARKER-PARSE...END-PATH-MARKER-PARSE block and
#           run it under synthetic ISSUE_BODY inputs.

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

# (i) new step `3c` (or sub-step inside step 4 numbered 0) appears between
# cache check (step 2) and rule table (step 4), referencing the HTML comment
# marker.
inc
if grep -qE '^3c\. ' "$SKILL_FILE" && grep -qF '<!-- pipeline:path=' "$SKILL_FILE"; then
  pass_msg "step 3c present and references <!-- pipeline:path="
else
  fail_msg "missing step 3c (or missing <!-- pipeline:path= reference)"
fi

# (ii) marker rule is documented as "before" the rule table.
inc
if grep -qiE 'before' "$SKILL_FILE" && grep -qiE 'rule table|keyword scoring' "$SKILL_FILE"; then
  pass_msg "marker rule documents 'before' the 'rule table'/'keyword scoring'"
else
  fail_msg "marker rule does not document precedence over rule table"
fi

# (iii) all four valid path letters A/B/C/D listed in the marker syntax.
inc
# Look for a single line within the marker step that lists A/B/C/D as the
# valid set. Slice from `^3c\.` to `^4\. `.
MARKER_SLICE="$WORKDIR/marker-slice.md"
awk '
  /^3c\. / { inblock = 1 }
  /^4\. /  { inblock = 0 }
  inblock { print }
' "$SKILL_FILE" > "$MARKER_SLICE"

if grep -qE 'A/B/C/D|\[A-Da-d\]|\[A-Za-z\]' "$MARKER_SLICE"; then
  pass_msg "marker step lists A/B/C/D (or the regex character class)"
else
  fail_msg "marker step does not list A/B/C/D"
fi

# (iv) rationale string "user-claimed path via body marker"
inc
if grep -qF 'user-claimed path via body marker' "$SKILL_FILE"; then
  pass_msg 'rationale "user-claimed path via body marker" present'
else
  fail_msg 'rationale string "user-claimed path via body marker" missing'
fi

# (v) confidence for marker-matched issues is high.
inc
if grep -qiE 'confidence[^A-Za-z]*=.*high|confidence.*high' "$MARKER_SLICE"; then
  pass_msg "marker step sets confidence=high"
else
  fail_msg "marker step does not set confidence=high"
fi

# (vi) pinned regex — BOTH forms must appear.
inc
if grep -qF '<!--\s*pipeline:path=[A-Da-d]\s*-->' "$SKILL_FILE"; then
  pass_msg 'pinned regex documented: <!--\s*pipeline:path=[A-Da-d]\s*-->'
else
  fail_msg 'pinned regex not documented in marker prose (Perl-style form)'
fi

inc
if grep -qF '<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->' "$SKILL_FILE"; then
  pass_msg 'POSIX-equivalent pinned regex documented'
else
  fail_msg 'POSIX-equivalent pinned regex missing'
fi

# (vii) sentinel comments
inc
if grep -qE '^[[:space:]]*# BEGIN-PATH-MARKER-PARSE' "$SKILL_FILE" \
   && grep -qE '^[[:space:]]*# END-PATH-MARKER-PARSE' "$SKILL_FILE"; then
  pass_msg "BEGIN-PATH-MARKER-PARSE / END-PATH-MARKER-PARSE sentinels present"
else
  fail_msg "missing BEGIN-PATH-MARKER-PARSE or END-PATH-MARKER-PARSE sentinel"
fi

############################################################
# Layer 2 — extract block and run synthetic ISSUE_BODY tests
############################################################

echo ""
echo "Layer 2 — sentinel block extraction + parser behavior"

PARSE_SCRIPT="$WORKDIR/parse-marker.sh"
awk '
  /^[[:space:]]*# BEGIN-PATH-MARKER-PARSE/ { inblock = 1 }
  inblock { print }
  /^[[:space:]]*# END-PATH-MARKER-PARSE/   { inblock = 0 }
' "$SKILL_FILE" > "$PARSE_SCRIPT"

# Also append a print of MARKER_PATH so the harness can read it.
echo 'printf "MARKER_PATH=%s\n" "${MARKER_PATH:-}"' >> "$PARSE_SCRIPT"

if ! [ -s "$PARSE_SCRIPT" ] || ! grep -q 'MARKER_PATH' "$PARSE_SCRIPT"; then
  fail_msg "could not extract a runnable BEGIN-PATH-MARKER-PARSE block (Layer 2 cannot proceed)"
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

expect_marker() {
  local label="$1"
  local body="$2"
  local want="$3"
  inc
  local out
  out=$(run_parse "$body" | grep '^MARKER_PATH=' | tail -1 | cut -d= -f2-)
  if [ "$out" = "$want" ]; then
    pass_msg "$label -> MARKER_PATH=$want"
  else
    fail_msg "$label -> got MARKER_PATH='$out', want '$want'"
  fi
}

expect_marker "padded marker letter A"      "<!-- pipeline:path=A -->"           "A"
expect_marker "unpadded marker lowercase a" "<!--pipeline:path=a-->"             "A"
expect_marker "double-padded marker D"      "<!--  pipeline:path=D  -->"         "D"
expect_marker "padded marker letter C"      "<!-- pipeline:path=C -->"           "C"
expect_marker "malformed letter Z ignored"  "<!-- pipeline:path=Z -->"           ""
expect_marker "malformed directive name"    "<!-- pipeline:foo=A -->"            ""
expect_marker "multi-marker — first wins"   "<!-- pipeline:path=A -->
<!-- pipeline:path=C -->"                                                          "A"
expect_marker "empty body"                  ""                                   ""
expect_marker "inline (no HTML brackets)"   "mentions pipeline:path=A inline"    ""

############################################################
# Layer 2b — B-marker label-removal interaction with BEGIN-LABEL-APPLY
############################################################

echo ""
echo "Layer 2b — B-marker triggers existing BEGIN-LABEL-APPLY remove path"

APPLY_SCRIPT="$WORKDIR/apply-label.sh"
awk '
  /^[[:space:]]*# BEGIN-LABEL-APPLY/ { inblock = 1 }
  inblock { print }
  /^[[:space:]]*# END-LABEL-APPLY/   { inblock = 0 }
' "$SKILL_FILE" > "$APPLY_SCRIPT"

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
GH_LOG="$WORKDIR/gh-calls.log"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "$@" >> "$GH_LOG_FILE"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

inc
# First confirm B marker is parsed.
out=$(run_parse "<!-- pipeline:path=B -->" | grep '^MARKER_PATH=' | tail -1 | cut -d= -f2-)
if [ "$out" != "B" ]; then
  fail_msg "B-marker did not parse to MARKER_PATH=B (got '$out')"
else
  : > "$GH_LOG"
  set +e
  env -i \
    HOME="$HOME" \
    PATH="$STUB_DIR:/usr/bin:/bin" \
    GH_LOG_FILE="$GH_LOG" \
    ISSUE_N="2354" \
    RECOMMENDED_PATH="B" \
    CURRENT_LABELS="multi-task" \
    REPO="fake/repo" \
    bash "$APPLY_SCRIPT" >"$WORKDIR/apply-out.txt" 2>"$WORKDIR/apply-err.txt"
  set -e
  remove_count=$(grep -c -- '--remove-label multi-task' "$GH_LOG" || true)
  add_count=$(grep -c -- '--add-label' "$GH_LOG" || true)
  total=$(wc -l < "$GH_LOG" | tr -d ' ')
  if [ "$remove_count" = "1" ] && [ "$add_count" = "0" ] && [ "$total" = "1" ]; then
    pass_msg "B-marker + multi-task -> exactly one --remove-label multi-task, no --add-label"
  else
    fail_msg "B-marker label-apply log mismatch: total=$total remove=$remove_count add=$add_count contents=$(cat "$GH_LOG")"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
