#!/bin/bash
set -uo pipefail

# Behavioral test for scripts/path-b-execute-eligible.sh (issue #955).
#
# The helper is a dispatch-time blast-radius ESTIMATE that gates the PATH B
# Sonnet execute downshift to the #950 §4 low-blast lane:
#   ≤1 source MODULE (excl tests/docs) · ≤6 source files · ≤150 added-LOC
#   (proxy estimate, NOT a measured diff) · no security/migration/auth/
#   concurrency signal. ALL four must hold for `low-blast`; ANY failure ⇒
#   `high-blast` (fail-closed to Opus).
#
# It emits exactly one machine-readable line on stdout:
#   ELIGIBLE=<low-blast|high-blast> ISSUE=<N> REASON=<token>
# and exits 0 in every case (the token carries the verdict, mirroring
# scripts/check-ci-fix-loop.sh).
#
# This test stubs `gh` on PATH (same pattern as tests/test-classify-*.sh) so
# `gh issue view <N> --json title,body,labels` returns canned fixtures, then
# invokes the helper and greps the single emitted ELIGIBLE= line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/path-b-execute-eligible.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper not found at $HELPER" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"

# `gh` stub: emits a canned JSON document read from $GH_FIXTURE for the
# `gh issue view ... --json title,body,labels` call. The helper consumes the
# JSON via --jq, so the stub just prints the fixture verbatim (it is already
# the {title,body,labels} object the helper would have fetched). To keep the
# stub --jq-agnostic, it shells out to the real `jq` against the fixture.
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
# Find the --jq argument (if any) and apply it to the fixture with real jq.
JQ_EXPR=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then JQ_EXPR="$a"; fi
  prev="$a"
done
if [ -n "$JQ_EXPR" ]; then
  jq -r "$JQ_EXPR" < "$GH_FIXTURE"
else
  cat "$GH_FIXTURE"
fi
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Build a {title,body,labels} JSON fixture file and return its path.
make_fixture() {
  local title="$1" body="$2" labels_json="$3"
  local f="$WORKDIR/fixture-$RANDOM.json"
  jq -n --arg t "$title" --arg b "$body" --argjson l "$labels_json" \
    '{title:$t, body:$b, labels:$l}' > "$f"
  echo "$f"
}

# Run the helper against a fixture; echo the ELIGIBLE= line it emits.
run_helper() {
  local fixture="$1"
  PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fixture" PIPELINE_REPO="owner/repo" \
    bash "$HELPER" 999 2>/dev/null | grep -E '^ELIGIBLE=' | head -1
}

assert_token() {
  local desc="$1" expect_eligible="$2" expect_reason="$3" line="$4"
  inc
  if echo "$line" | grep -q "ELIGIBLE=$expect_eligible" \
     && echo "$line" | grep -q "REASON=$expect_reason"; then
    pass_msg "$desc -> $line"
  else
    fail_msg "$desc: expected ELIGIBLE=$expect_eligible REASON=$expect_reason, got: '$line'"
  fi
}

echo "== test-path-b-execute-eligible (issue #955) =="

# (a) 1 src file + colocated test, single module, no signal -> low-blast.
BODY_A=$'## Summary\nfix a thing\n\n## Affected areas\n- `scripts/foo.sh`\n- `tests/test-foo.sh`\n'
FIX_A=$(make_fixture "fix(foo): tweak" "$BODY_A" '[]')
assert_token "(a) 1 src + colocated test, single module, no signal" \
  "low-blast" "single-module" "$(run_helper "$FIX_A")"

# (b) 5 src files across 2 top-level modules -> high-blast multi-module.
BODY_B=$'## Affected areas\n- `scripts/a.sh`\n- `scripts/b.sh`\n- `scripts/c.sh`\n- `skills/x/SKILL.md`\n- `skills/y/SKILL.md`\n'
FIX_B=$(make_fixture "feat(x): big" "$BODY_B" '[]')
assert_token "(b) 5 src across 2 modules" \
  "high-blast" "multi-module" "$(run_helper "$FIX_B")"

# (c) 1 src file but body contains concurrency/race -> high-blast high-uncertainty.
BODY_C=$'## Affected areas\n- `scripts/lockfix.sh`\n\nThis fixes a race condition in the concurrency path.\n'
FIX_C=$(make_fixture "fix(lock): race" "$BODY_C" '[]')
assert_token "(c) 1 src but concurrency/race signal" \
  "high-blast" "high-uncertainty" "$(run_helper "$FIX_C")"

# (d) 1 src file but body contains ~200 LOC -> high-blast loc-over.
BODY_D=$'## Affected areas\n- `scripts/foo.sh`\n\nRoughly ~200 LOC of new code.\n'
FIX_D=$(make_fixture "feat(foo): big single file" "$BODY_D" '[]')
assert_token "(d) 1 src but ~200 LOC override" \
  "high-blast" "loc-over" "$(run_helper "$FIX_D")"

# (e) 7 src files single module -> high-blast too-many-files.
BODY_E=$'## Affected areas\n- `scripts/a.sh`\n- `scripts/b.sh`\n- `scripts/c.sh`\n- `scripts/d.sh`\n- `scripts/e.sh`\n- `scripts/f.sh`\n- `scripts/g.sh`\n'
FIX_E=$(make_fixture "feat(scripts): many" "$BODY_E" '[]')
assert_token "(e) 7 src single module" \
  "high-blast" "too-many-files" "$(run_helper "$FIX_E")"

# (f) empty/absent Affected areas -> high-blast indeterminate (fail-closed).
BODY_F=$'## Summary\njust some prose, no affected areas section\n'
FIX_F=$(make_fixture "feat(x): vague" "$BODY_F" '[]')
assert_token "(f) absent Affected areas (fail-closed)" \
  "high-blast" "indeterminate" "$(run_helper "$FIX_F")"

# MANDATORY positive truth-table case (evaluator recommendation #2):
# single-module + 2-6 source files + no uncertainty signal -> low-blast.
# Exercises the ≤6 / single-module boundary so the unit-conflation bug
# (gating on file count instead of MODULE count) cannot ship green.
BODY_G=$'## Affected areas\n- `scripts/a.sh`\n- `scripts/b.sh`\n- `scripts/c.sh`\n- `tests/test-a.sh`\n'
FIX_G=$(make_fixture "fix(scripts): multi-file single module" "$BODY_G" '[]')
assert_token "(g) single-module + 3 src files (2-6) no signal" \
  "low-blast" "single-module" "$(run_helper "$FIX_G")"

# (g2) needs-browser label, otherwise low-blast (single module, no other signal)
#      -> high-blast needs-browser (issue #960: browser/UI execute never validated on Sonnet).
BODY_G2=$'## Affected areas\n- `scripts/foo.sh`\n'
FIX_G2=$(make_fixture "fix(ui): tweak admin events table" "$BODY_G2" '[{"name":"needs-browser"}]')
assert_token "(g2) needs-browser label single src -> browser carve-out" \
  "high-blast" "needs-browser" "$(run_helper "$FIX_G2")"

# (h) gh failure / parse error -> high-blast indeterminate (fail-closed).
# Simulate by pointing the stub at a missing fixture so jq fails.
inc
LINE_H="$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$WORKDIR/does-not-exist.json" PIPELINE_REPO="owner/repo" \
  bash "$HELPER" 999 2>/dev/null | grep -E '^ELIGIBLE=' | head -1)"
if echo "$LINE_H" | grep -q "ELIGIBLE=high-blast" && echo "$LINE_H" | grep -q "REASON=indeterminate"; then
  pass_msg "(h) gh/jq failure -> high-blast indeterminate (fail-closed) -> $LINE_H"
else
  fail_msg "(h) gh failure: expected high-blast indeterminate, got: '$LINE_H'"
fi

# Exit-0 contract: the helper must exit 0 even on the high-blast verdict.
inc
PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIX_B" PIPELINE_REPO="owner/repo" \
  bash "$HELPER" 999 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "exit 0 on high-blast verdict (token carries verdict, not exit code)"
else
  fail_msg "exit $rc on high-blast verdict (expected 0)"
fi

# Single-line contract: exactly one ELIGIBLE= line on stdout.
inc
COUNT="$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIX_A" PIPELINE_REPO="owner/repo" \
  bash "$HELPER" 999 2>/dev/null | grep -cE '^ELIGIBLE=')"
if [ "$COUNT" -eq 1 ]; then
  pass_msg "emits exactly one ELIGIBLE= line"
else
  fail_msg "emitted $COUNT ELIGIBLE= lines (expected 1)"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
