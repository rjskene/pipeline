#!/usr/bin/env bash
# test-check-capability-refusal.sh — #1233 detector unit tests.
#
# scripts/check-capability-refusal.sh is the mechanical listener for the
# CAPABILITY-REFUSED: contract established by #1225 in agents/tdd-implementer.md.
# A leaf that cannot perform a mandated plan task must fail LOUDLY; "loudly"
# needs a listener, otherwise a silently-substituting executor still merges.
#
# Contract (one stdout line, ALWAYS exit 0 — the verdict rides the token, same
# shape as scripts/split-role-gate.sh / scripts/auto-merge-gate.sh):
#
#   CAPABILITY_REFUSAL=<clear|block> ISSUE=<N> REASON=<token> SCANNED=<n> WITH_OUTPUT=<n>
#
# COUNTER CONTRACT (the plan's §3, stated once, every case below derives from it):
#   - a file is OPENED iff it is an explicit file source, or a -maxdepth 1
#     regular file in a dir source whose decomposed SLUG carries <issue-N> as a
#     whole digit run. Anything else is never opened: 0 to BOTH counters.
#   - SCANNED increments for EVERY opened file, parse outcome irrelevant (a
#     malformed .json IS an opened file).
#   - WITH_OUTPUT increments only when the opened file yielded NON-EMPTY leaf
#     text.
#
# TOKEN RULE — an ordered TOTAL FUNCTION of (HIT, SCANNED, WITH_OUTPUT):
#   1. HIT >= 1                 => block / leaf-refused
#   2. else SCANNED == 0        => clear / no-sources
#   3. else WITH_OUTPUT == 0    => clear / no-leaf-output   (proved nothing)
#   4. else                     => clear / no-refusal       (the only confident clean)
#
# SLUG DECOMPOSITION (the plan's §2 — this IS the spec, not a paraphrase):
#   1. base := filename minus a trailing .json
#   2. split base on `_` into f[1..n]; if n >= 2 DROP the LAST field (agent-id)
#   3. if the FIRST remaining field matches [0-9]{8}-[0-9]{6}-[0-9]{6} DROP it
#   4. slug := remaining fields joined with `-` (empty => never matches)
#
# Hermetic: every fixture is built under mktemp -d; NEVER reads the live
# .claude/logs/.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DETECTOR="$ROOT/scripts/check-capability-refusal.sh"

if [ ! -f "$DETECTOR" ]; then
  echo "FAIL: scripts/check-capability-refusal.sh does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Assemble the sentinel at runtime so this test file is never itself a scan
# false-positive (precedent: scripts/check-cross-cutting-guards.sh:121).
SENT="CAPABILITY-""REFUSED:"

FAILED=0
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name -> $actual"
  else
    fail "$name expected='$expected' actual='$actual'"
  fi
}

check_ne() {
  local name="$1" forbidden="$2" actual="$3"
  if [ "$forbidden" != "$actual" ]; then
    pass "$name -> $actual (not '$forbidden')"
  else
    fail "$name must NOT be '$forbidden'"
  fi
}

# mk_record <dir> <filename> <result-text> [<prompt-text>]
# Writes a subagent-shaped record with python's json.dump, so a `\n` inside
# .result is JSON-escaped exactly as hooks/log_subagent.py writes it (which is
# why a raw grep over the file bytes misses a sentinel that is not on physical
# line 1 — see case (c)).
mk_record() {
  local dir="$1" fname="$2" result="$3" prompt="${4:-}"
  mkdir -p "$dir"
  RESULT_TEXT="$result" PROMPT_TEXT="$prompt" python3 - "$dir/$fname" <<'PY'
import json, os, sys
rec = {
    "schema_version": 1,
    "timestamp_utc": "2026-08-21T00:00:00+00:00",
    "session_id": "s1",
    "agent_id": "abcd1234ef",
    "description": "fixture",
    "subagent_type": "tdd-implementer",
    "prompt": os.environ.get("PROMPT_TEXT", ""),
    "prompt_truncated": False,
    "result": os.environ.get("RESULT_TEXT", ""),
    "result_truncated": False,
    "usage": {"input_tokens": 0, "output_tokens": 0,
              "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0},
    "total_tokens": 0,
    "total_duration_ms": 0,
    "num_turns": 0,
    "jsonl_path_hint": "",
}
with open(sys.argv[1], "w") as fh:
    json.dump(rec, fh, indent=2)
PY
}

# --- (p)/(x) harness -------------------------------------------------------
# Every detector invocation in this file goes through run_det/run_det_env, so
# (p) (exactly one stdout line, exit 0) is asserted for EVERY case in this file
# and (x) collects the (SCANNED, WITH_OUTPUT, REASON) triple of every `clear`.
TRIPLES="$TMP/triples.txt"
: >"$TRIPLES"
LINE=""

_assert_contract() {
  local label="$1" rc="$2" out="$3" nlines
  if [ "$rc" -ne 0 ]; then
    fail "(p) $label: expected exit 0, got $rc"
  fi
  nlines="$(printf '%s' "$out" | grep -c '')"
  if [ "$nlines" != "1" ]; then
    fail "(p) $label: expected exactly 1 stdout line, got $nlines"
    return 0
  fi
  if [[ "$out" =~ ^CAPABILITY_REFUSAL=(clear|block)\ ISSUE=[0-9]+\ REASON=[a-z-]+\ SCANNED=[0-9]+\ WITH_OUTPUT=[0-9]+$ ]]; then
    :
  else
    fail "(p) $label: stdout does not match the one-line contract: '$out'"
    return 0
  fi
  if [ "$(fld "$out" CAPABILITY_REFUSAL)" = "clear" ]; then
    printf '%s %s %s\n' \
      "$(fld "$out" SCANNED)" "$(fld "$out" WITH_OUTPUT)" "$(fld "$out" REASON)" \
      >>"$TRIPLES"
  fi
}

# fld <line> <KEY> — field extraction, never whole-line equality.
fld() {
  printf '%s\n' "$1" | tr ' ' '\n' | grep "^$2=" | head -1 | cut -d= -f2-
}

# run_det <issue> [source...] — PIPELINE_CAPABILITY_REFUSAL_SOURCES unset.
run_det() {
  local out rc
  out="$(env -u PIPELINE_CAPABILITY_REFUSAL_SOURCES bash "$DETECTOR" "$@" 2>/dev/null)"
  rc=$?
  LINE="$out"
  _assert_contract "run_det $*" "$rc" "$out"
}

# run_det_env <sources-value> <issue> [source...]
run_det_env() {
  local sources="$1"; shift
  local out rc
  out="$(PIPELINE_CAPABILITY_REFUSAL_SOURCES="$sources" bash "$DETECTOR" "$@" 2>/dev/null)"
  rc=$?
  LINE="$out"
  _assert_contract "run_det_env($sources) $*" "$rc" "$out"
}

# ---------------------------------------------------------------------------
echo "=== (a) sentinel at line start in .result => block ==="
A_DIR="$TMP/a"
mk_record "$A_DIR" "execute-1233-path-b_aaaa1111.json" "$SENT cannot drive a browser for the mandated visual proof"
run_det 1233 "$A_DIR"
check "(a) verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(a) issue echoed" "1233" "$(fld "$LINE" ISSUE)"
check "(a) reason" "leaf-refused" "$(fld "$LINE" REASON)"

echo "=== (b) clean non-empty .result => clear/no-refusal ==="
B_DIR="$TMP/b"
mk_record "$B_DIR" "execute-1233-path-b_aaaa1111.json" "all four tasks implemented; suite green"
run_det 1233 "$B_DIR"
check "(b) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(b) reason" "no-refusal" "$(fld "$LINE" REASON)"
check "(b) SCANNED" "1" "$(fld "$LINE" SCANNED)"
check "(b) WITH_OUTPUT" "1" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (c) JSON-escaped newline: jq decode is the catcher, not a raw grep ==="
C_DIR="$TMP/c"
C_FILE="$C_DIR/execute-1233-path-b_aaaa1111.json"
mk_record "$C_DIR" "execute-1233-path-b_aaaa1111.json" "work done
$SENT the plan mandates a capability I do not have"
run_det 1233 "$C_DIR"
check "(c) verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(c) reason" "leaf-refused" "$(fld "$LINE" REASON)"
C_RAW="$(grep -cE "^[[:space:]]*$SENT" "$C_FILE" 2>/dev/null || true)"
check "(c) negative control: raw anchored grep over the file bytes finds nothing" "0" "$C_RAW"

echo "=== (d) all-empty decode => no-leaf-output, NEVER no-refusal ==="
D_DIR="$TMP/d"
mk_record "$D_DIR" "execute-1233-path-b_aaaa1111.json" ""
mk_record "$D_DIR" "plan-issue-1233_aaaa2222.json" ""
mk_record "$D_DIR" "evaluate-pr-issue-1233_aaaa3333.json" ""
run_det 1233 "$D_DIR"
check "(d) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(d) reason" "no-leaf-output" "$(fld "$LINE" REASON)"
check_ne "(d) reason is not a confident clean" "no-refusal" "$(fld "$LINE" REASON)"
check "(d) SCANNED" "3" "$(fld "$LINE" SCANNED)"
check "(d) WITH_OUTPUT" "0" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (e) cross-issue isolation ==="
E_DIR="$TMP/e"
mk_record "$E_DIR" "execute-9999-path-b_bbbb2222.json" "$SENT cannot do the thing"
mk_record "$E_DIR" "execute-1233-path-b_cccc3333.json" "implemented and committed"
run_det 1233 "$E_DIR"
check "(e) issue 1233 verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(e) issue 1233 reason" "no-refusal" "$(fld "$LINE" REASON)"
check "(e) issue 1233 SCANNED" "1" "$(fld "$LINE" SCANNED)"
run_det 9999 "$E_DIR"
check "(e) inverse: issue 9999 verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(e) inverse: issue 9999 reason" "leaf-refused" "$(fld "$LINE" REASON)"
check "(e) inverse: issue 9999 SCANNED" "1" "$(fld "$LINE" SCANNED)"

echo "=== (f) digit-boundary: 1233 must not match inside 11233 ==="
F_DIR="$TMP/f"
mk_record "$F_DIR" "classify-11233_dddd4444.json" "$SENT cannot do the thing"
run_det 1233 "$F_DIR"
check "(f) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(f) reason" "no-sources" "$(fld "$LINE" REASON)"
check "(f) SCANNED" "0" "$(fld "$LINE" SCANNED)"

echo "=== (g) multi-number slug: whole-digit-run match on EITHER number ==="
G_DIR="$TMP/g"
mk_record "$G_DIR" "evaluate-pr-1229-issue-1233_eeee5555.json" "$SENT cannot do the thing"
run_det 1233 "$G_DIR"
check "(g) issue 1233 verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
run_det 1229 "$G_DIR"
check "(g) issue 1229 verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
run_det 1240 "$G_DIR"
check "(g) issue 1240 verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(g) issue 1240 reason" "no-sources" "$(fld "$LINE" REASON)"

echo "=== (h) sentinel in .prompt only is orchestrator text, never leaf output ==="
H_DIR="$TMP/h"
mk_record "$H_DIR" "execute-1233-path-b_aaaa1111.json" "implemented and committed" \
  "$SENT is the contract you must honour if you cannot perform a task"
run_det 1233 "$H_DIR"
check "(h) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(h) reason" "no-refusal" "$(fld "$LINE" REASON)"
check "(h) SCANNED" "1" "$(fld "$LINE" SCANNED)"
check "(h) WITH_OUTPUT" "1" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (i) malformed JSON is not a refusal (no raw-byte fallback) ==="
I_DIR="$TMP/i"
mkdir -p "$I_DIR"
printf '{ this is not json\n%s cannot do the thing\n' "$SENT" \
  >"$I_DIR/execute-1233-path-b_ffff6666.json"
run_det 1233 "$I_DIR"
check "(i) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(i) reason" "no-leaf-output" "$(fld "$LINE" REASON)"
check_ne "(i) never falsely refused" "leaf-refused" "$(fld "$LINE" REASON)"
check "(i) SCANNED (the file WAS opened)" "1" "$(fld "$LINE" SCANNED)"
check "(i) WITH_OUTPUT" "0" "$(fld "$LINE" WITH_OUTPUT)"

I2_DIR="$TMP/i2"
mkdir -p "$I2_DIR"
printf '{ this is not json\n%s cannot do the thing\n' "$SENT" \
  >"$I2_DIR/execute-1233-path-b_ffff6666.json"
mk_record "$I2_DIR" "plan-issue-1233_ffff7777.json" "plan posted"
run_det 1233 "$I2_DIR"
check "(i2) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(i2) reason" "no-refusal" "$(fld "$LINE" REASON)"
check "(i2) SCANNED" "2" "$(fld "$LINE" SCANNED)"
check "(i2) WITH_OUTPUT" "1" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (j) mid-line prose about the contract must not false-positive ==="
J_DIR="$TMP/j"
J_FILE="$J_DIR/execute-1233-path-b_aaaa1111.json"
mk_record "$J_DIR" "execute-1233-path-b_aaaa1111.json" \
  "the $SENT contract is documented in agents/tdd-implementer.md"
run_det 1233 "$J_DIR"
check "(j) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(j) reason" "no-refusal" "$(fld "$LINE" REASON)"
J_UNANCHORED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"])' "$J_FILE" \
  | grep -cF "$SENT" 2>/dev/null || true)"
if [ "$J_UNANCHORED" -ge 1 ] 2>/dev/null; then
  pass "(j) negative control: unanchored grep over the DECODED text hits ($J_UNANCHORED) - the line anchor is the discriminator"
else
  fail "(j) negative control vacuous: unanchored grep over the decoded text found nothing"
fi

echo "=== (k) leading-whitespace tolerance ==="
K_DIR="$TMP/k"
mk_record "$K_DIR" "execute-1233-path-b_aaaa1111.json" "  $SENT cannot do the thing"
run_det 1233 "$K_DIR"
check "(k) verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(k) reason" "leaf-refused" "$(fld "$LINE" REASON)"

echo "=== (l) explicit non-.json file source bypasses issue scoping ==="
L_DIR="$TMP/l"
mkdir -p "$L_DIR"
printf 'leaf transcript tail\n%s cannot do the thing\n' "$SENT" >"$L_DIR/leaf-output.txt"
run_det 1233 "$L_DIR/leaf-output.txt"
check "(l) verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(l) reason" "leaf-refused" "$(fld "$LINE" REASON)"

echo "=== (m) no positional args, knob unset => no-sources ==="
run_det 1233
check "(m) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(m) reason" "no-sources" "$(fld "$LINE" REASON)"
check "(m) SCANNED" "0" "$(fld "$LINE" SCANNED)"
check "(m) WITH_OUTPUT" "0" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (n) env tier + positional-wins ==="
run_det_env "$A_DIR" 1233
check "(n) env tier verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(n) env tier reason" "leaf-refused" "$(fld "$LINE" REASON)"
run_det_env "$A_DIR" 1233 "$B_DIR"
check "(n) positional wins over env: verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(n) positional wins over env: reason" "no-refusal" "$(fld "$LINE" REASON)"

echo "=== (o) only-nonexistent source path => no-sources ==="
run_det 1233 "$TMP/does-not-exist"
check "(o) verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(o) reason" "no-sources" "$(fld "$LINE" REASON)"
check "(o) SCANNED" "0" "$(fld "$LINE" SCANNED)"

echo "=== (q) the <issue-N> argument is echoed verbatim ==="
run_det 4242 "$TMP/does-not-exist"
check "(q) issue echoed verbatim" "4242" "$(fld "$LINE" ISSUE)"
run_det 7 "$TMP/does-not-exist"
check "(q) issue echoed verbatim (short)" "7" "$(fld "$LINE" ISSUE)"

echo "=== (r) zero args => usage on stderr, exit 2 ==="
R_ERR="$TMP/r.err"
R_OUT="$(bash "$DETECTOR" 2>"$R_ERR")"
R_RC=$?
check "(r) exit code" "2" "$R_RC"
if grep -qi 'usage' "$R_ERR"; then
  pass "(r) usage printed on stderr"
else
  fail "(r) expected a usage line on stderr, got: $(head -1 "$R_ERR")"
fi
check "(r) nothing on stdout" "" "$R_OUT"

echo "=== (s) cross-host portability: no ERE anchored alternation ==="
S_OPEN="$(grep -cF '(^|' "$DETECTOR" 2>/dev/null || true)"
S_CLOSE="$(grep -cF '|$)' "$DETECTOR" 2>/dev/null || true)"
check "(s) detector contains no '(^|' (ugrep 7.5.0 NOMATCHes anchored ERE alternations)" "0" "$S_OPEN"
check "(s) detector contains no '|\$)'" "0" "$S_CLOSE"

echo "=== (t) real 3-field filename: the issue lives in the SLUG field ==="
T_DIR="$TMP/t"
mk_record "$T_DIR" "20260821-055731-123456_execute-1233-path-b_ab99cd11.json" \
  "$SENT cannot do the thing"
run_det 1233 "$T_DIR"
check "(t) verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(t) reason" "leaf-refused" "$(fld "$LINE" REASON)"
check "(t) SCANNED" "1" "$(fld "$LINE" SCANNED)"
check "(t) WITH_OUTPUT" "1" "$(fld "$LINE" WITH_OUTPUT)"

echo "=== (u) an agent-id hex digit run must NOT match ==="
U_DIR="$TMP/u"
mk_record "$U_DIR" "20260821-000000-000000_plan-issue-999_ab1233cd.json" \
  "$SENT cannot do the thing"
run_det 1233 "$U_DIR"
check "(u) agent-id hex run: verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(u) agent-id hex run: reason" "no-sources" "$(fld "$LINE" REASON)"
check "(u) agent-id hex run: SCANNED" "0" "$(fld "$LINE" SCANNED)"
check "(u) agent-id hex run: WITH_OUTPUT" "0" "$(fld "$LINE" WITH_OUTPUT)"
run_det 999 "$U_DIR"
check "(u) paired positive control over the SAME fixture: verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(u) paired positive control: reason" "leaf-refused" "$(fld "$LINE" REASON)"
check "(u) paired positive control: SCANNED" "1" "$(fld "$LINE" SCANNED)"

echo "=== (v) a timestamp digit run must NOT match ==="
V_DIR="$TMP/v"
mk_record "$V_DIR" "20260821-123456-000000_plan-issue-999_ab99cd11.json" \
  "$SENT cannot do the thing"
run_det 123456 "$V_DIR"
check "(v) timestamp run: verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(v) timestamp run: reason" "no-sources" "$(fld "$LINE" REASON)"
check "(v) timestamp run: SCANNED" "0" "$(fld "$LINE" SCANNED)"
run_det 999 "$V_DIR"
check "(v) paired positive control over the SAME fixture: verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(v) paired positive control: SCANNED" "1" "$(fld "$LINE" SCANNED)"

echo "=== (w) trailing agent-id is stripped even with NO leading timestamp field ==="
W_DIR="$TMP/w"
mk_record "$W_DIR" "execute-9999-path-b_bb1233cc.json" "$SENT cannot do the thing"
run_det 1233 "$W_DIR"
check "(w) 2-field agent-id run: verdict" "clear" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(w) 2-field agent-id run: reason" "no-sources" "$(fld "$LINE" REASON)"
check "(w) 2-field agent-id run: SCANNED" "0" "$(fld "$LINE" SCANNED)"
run_det 9999 "$W_DIR"
check "(w) paired positive control over the SAME fixture: verdict" "block" "$(fld "$LINE" CAPABILITY_REFUSAL)"
check "(w) paired positive control: SCANNED" "1" "$(fld "$LINE" SCANNED)"

echo "=== (x) REASON is a total FUNCTION of (SCANNED, WITH_OUTPUT) on every clear ==="
TRIPLE_COUNT="$(grep -c '' "$TRIPLES" 2>/dev/null || echo 0)"
if [ "$TRIPLE_COUNT" -lt 3 ] 2>/dev/null; then
  fail "(x) vacuous: only $TRIPLE_COUNT clear-verdict triples collected"
else
  pass "(x) collected $TRIPLE_COUNT clear-verdict (SCANNED, WITH_OUTPUT, REASON) triples"
fi

DUPE_KEYS="$(sort -u "$TRIPLES" | awk '{print $1" "$2}' | sort | uniq -d)"
if [ -z "$DUPE_KEYS" ]; then
  pass "(x) no (SCANNED, WITH_OUTPUT) key maps to two distinct REASONs"
else
  fail "(x) counter pair(s) mapping to MULTIPLE REASONs: $(printf '%s' "$DUPE_KEYS" | tr '\n' ';')"
fi

lookup_reason() {
  awk -v s="$1" -v w="$2" '$1==s && $2==w {print $3}' "$TRIPLES" | sort -u | tr '\n' ',' | sed 's/,$//'
}
check "(x) canonical (0,0)" "no-sources" "$(lookup_reason 0 0)"
check "(x) canonical (1,0)" "no-leaf-output" "$(lookup_reason 1 0)"
check "(x) canonical (1,1)" "no-refusal" "$(lookup_reason 1 1)"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
