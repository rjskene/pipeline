#!/usr/bin/env bash
# test-auto-merge-gate-capability-refusal.sh — #1233 gate wiring + precedence.
#
# scripts/auto-merge-gate.sh gains a `block-capability-refused` token so a leaf
# that emitted the CAPABILITY-REFUSED: sentinel (#1225's contract) can never
# reach an auto-merge greenlight. Precedence:
#
#   block-flag > block-label > block-verdict > block-capability-refused >
#   block-base-mismatch > block-ci > block-mergeable > block-mergestate
#
# The two operator opt-outs and the human evaluator verdict still precede it
# (which is what makes the within-issue-history block self-clearing via the
# Step 11.4 manual-merge auto-apply); base/CI/merge-state come after, because a
# refused leaf means the WORK is incomplete.
#
# The arm runs ONLY when $PIPELINE_CAPABILITY_REFUSAL_SOURCES is non-empty, so
# unset is byte-identical to the pre-change gate (consumer installs and every
# existing gate test are unaffected).
#
# `clear` with REASON=no-sources / no-leaf-output is deliberately NON-blocking
# (hard-blocking would wedge consumer installs and every background dispatch),
# but it MUST emit a stderr WARN — otherwise the gate silently claims teeth it
# does not have.
#
# Harness copied from tests/test-auto-merge-greenlight.sh (gh shim + check +
# run_gate); every fixture is built under mktemp -d.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Assembled at runtime so this test file is never itself a scan false-positive
# (precedent: scripts/check-cross-cutting-guards.sh:121).
SENT="CAPABILITY-""REFUSED:"

ISSUE=1233

# --- gh shim (from tests/test-auto-merge-greenlight.sh) ---
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
echo "gh $ALL_ARGS" >> "${CALL_LOG:-/dev/null}"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*)
    printf '%s\n' ${GH_LABELS:-}
    ;;
  *"pr view"*"--json baseRefName"*)
    printf '%s\n' "${GH_BASE_REF:-staging}"
    ;;
  *"pr view"*"--json comments"*"Evaluation"*)
    printf '%s' "${GH_EVAL_BODY:-}"
    ;;
  *"pr view"*"--json statusCheckRollup,mergeable,mergeStateStatus"*)
    printf '%s' "${GH_ROLLUP:-}"
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export CALL_LOG="$TMP/calls.log"
export PIPELINE_REPO="test/repo"
export PIPELINE_BASE_BRANCH="staging"

# shellcheck disable=SC1090
source "$HELPER"

FAILED=0
fail() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
pass() { echo "  PASS: $*"; }

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$name -> $actual"
  else
    fail "$name expected=$expected actual=$actual"
  fi
}

make_rollup() {
  local ci="$1" mergeable="$2" mergestate="$3"
  local checks="[]"
  case "$ci" in
    success) checks='[{"name":"x","conclusion":"SUCCESS"}]' ;;
    failure) checks='[{"name":"x","conclusion":"FAILURE"}]' ;;
  esac
  printf '{"statusCheckRollup":%s,"mergeable":"%s","mergeStateStatus":"%s"}' \
    "$checks" "$mergeable" "$mergestate"
}

make_eval() { printf '## Evaluation\n\n**Verdict:** %s\n' "$1"; }

# mk_record <dir> <filename> <result-text>
mk_record() {
  local dir="$1" fname="$2" result="$3"
  mkdir -p "$dir"
  RESULT_TEXT="$result" python3 - "$dir/$fname" <<'PY'
import json, os, sys
rec = {
    "schema_version": 1,
    "timestamp_utc": "2026-08-21T00:00:00+00:00",
    "session_id": "s1",
    "agent_id": "abcd1234ef",
    "description": "fixture",
    "subagent_type": "tdd-implementer",
    "prompt": "",
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

# --- fixtures --------------------------------------------------------------
REFUSED_DIR="$TMP/src-refused"
mk_record "$REFUSED_DIR" "execute-${ISSUE}-path-b_aaaa1111.json" \
  "$SENT cannot perform the mandated task"

CLEAN_DIR="$TMP/src-clean"
mk_record "$CLEAN_DIR" "execute-${ISSUE}-path-b_bbbb2222.json" \
  "all tasks implemented; suite green"

OTHER_ISSUE_DIR="$TMP/src-other-issue"
mk_record "$OTHER_ISSUE_DIR" "execute-9999-path-b_cccc3333.json" \
  "$SENT cannot perform the mandated task"

EMPTY_RESULT_DIR="$TMP/src-empty-result"
mk_record "$EMPTY_RESULT_DIR" "execute-${ISSUE}-path-b_dddd4444.json" ""
mk_record "$EMPTY_RESULT_DIR" "plan-issue-${ISSUE}_dddd5555.json" ""

MISSING_DIR="$TMP/src-does-not-exist"

# --- runners ---------------------------------------------------------------
# STDOUT_LINE / STDERR_TXT / GATE_RC are set by run_gate.
STDOUT_LINE=""
STDERR_TXT=""
GATE_RC=0

# run_gate — stdout captured (token), stderr captured separately. Asserts case
# (i) for EVERY invocation: stdout is exactly one token line.
run_gate() {
  local label="$1" errf="$TMP/gate.err" out nlines
  : >"$errf"
  out="$(auto_merge_should_fire "$ISSUE" 1 2>"$errf")"
  GATE_RC=$?
  STDOUT_LINE="$out"
  STDERR_TXT="$(cat "$errf")"
  nlines="$(printf '%s' "$out" | grep -c '')"
  if [ "$nlines" = "1" ]; then
    pass "(i) $label: stdout is exactly one token line"
  else
    fail "(i) $label: expected exactly 1 stdout line, got $nlines ('$out')"
  fi
}

# Baseline greenlight environment: Approved + CI SUCCESS + MERGEABLE + CLEAN.
reset_env() {
  unset MANUAL_MERGE
  unset NO_VERDICT
  unset PIPELINE_CAPABILITY_REFUSAL_SOURCES
  export GH_LABELS=""
  export GH_BASE_REF="staging"
  export GH_EVAL_BODY="$(make_eval Approved)"
  export GH_ROLLUP="$(make_rollup success MERGEABLE CLEAN)"
}

echo "=== (a) issue-scoped refusal blocks the greenlight ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
run_gate "(a)"
check "(a) token" "block-capability-refused" "$STDOUT_LINE"
check "(a) return code" "1" "$GATE_RC"

echo "=== (b) issue-scoped CLEAN non-empty record => green ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$CLEAN_DIR"
run_gate "(b)"
check "(b) token" "green" "$STDOUT_LINE"
check "(b) return code" "0" "$GATE_RC"

echo "=== (c) a refusal scoped to a DIFFERENT issue cannot block this PR ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$OTHER_ISSUE_DIR"
run_gate "(c)"
check "(c) token" "green" "$STDOUT_LINE"

echo "=== (d) knob UNSET => byte-identical pre-change behaviour ==="
reset_env
run_gate "(d)"
check "(d) token" "green" "$STDOUT_LINE"
check "(d) no WARN emitted when the knob is unset" "" "$STDERR_TXT"

echo "=== (e) every in-scope record decodes empty => green + stderr WARN ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$EMPTY_RESULT_DIR"
run_gate "(e)"
check "(e) token" "green" "$STDOUT_LINE"
case "$STDERR_TXT" in
  *WARN*no-leaf-output*) pass "(e) stderr WARN names no-leaf-output" ;;
  *) fail "(e) expected a stderr WARN naming no-leaf-output, got: '$STDERR_TXT'" ;;
esac

echo "=== (f) nonexistent source path => green + stderr WARN naming no-sources ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$MISSING_DIR"
run_gate "(f)"
check "(f) token" "green" "$STDOUT_LINE"
case "$STDERR_TXT" in
  *WARN*no-sources*) pass "(f) stderr WARN names no-sources" ;;
  *) fail "(f) expected a stderr WARN naming no-sources, got: '$STDERR_TXT'" ;;
esac

echo "=== (g) precedence ABOVE: flag / label / verdict still win ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
export MANUAL_MERGE=1
run_gate "(g) MANUAL_MERGE"
check "(g) MANUAL_MERGE=1 + refusal" "block-flag" "$STDOUT_LINE"

reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
export GH_LABELS="manual-merge"
run_gate "(g) manual-merge label"
check "(g) manual-merge label + refusal" "block-label" "$STDOUT_LINE"

reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
export GH_EVAL_BODY="$(make_eval Flagged)"
run_gate "(g) Flagged verdict"
check "(g) Flagged verdict + refusal" "block-verdict" "$STDOUT_LINE"

echo "=== (h) precedence BELOW: refusal wins over base-mismatch and CI ==="
reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
export GH_BASE_REF="main"
run_gate "(h) base-mismatch"
check "(h) refusal + GH_BASE_REF=main" "block-capability-refused" "$STDOUT_LINE"

reset_env
export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$REFUSED_DIR"
export GH_ROLLUP="$(make_rollup failure MERGEABLE CLEAN)"
run_gate "(h) CI failure"
check "(h) refusal + CI FAILURE" "block-capability-refused" "$STDOUT_LINE"

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
