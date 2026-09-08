#!/usr/bin/env bash
# test-auto-merge-gate-worktree-capability-refusal.sh — #1246 end-to-end proof
# that the #1233 `block-capability-refused` arm has TEETH when the gate is
# invoked FROM INSIDE a feature worktree.
#
# tests/test-auto-merge-gate-capability-refusal.sh proves the arm works when the
# caller hands it a source dir directly. That is not how the arm is reached in
# production: `evaluate-issue-pr` Step 11.2 runs from a feature WORKTREE and
# must RESOLVE the dir first. Before #1246 it resolved
# ${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/logs/subagents — a path that does not
# exist inside a worktree — so the knob was never threaded and the arm was
# permanently dormant. This file wires the REAL resolver to the REAL gate over
# REAL `git worktree` fixtures and asserts the block actually fires.
#
# The Step 11.2 call-site contract reproduced here (`resolve_and_thread`):
#   run `check-capability-refusal.sh --resolve-sources`, parse the token line,
#   and export PIPELINE_CAPABILITY_REFUSAL_SOURCES ONLY on SOURCES=resolved.
# `no-log-dir` and `unresolvable-root` both leave the knob unexported, so the
# gate's `-n` guard skips the arm entirely — fail-open is STRUCTURAL, never a
# hard block.
#
# Harness shapes (gh shim + make_rollup / make_eval / mk_record + run_gate) are
# copied from tests/test-auto-merge-gate-capability-refusal.sh; the gate itself
# is sourced via tests/_lib/auto-merge-gate-harness.sh. Every fixture lives
# under mktemp -d; `git worktree add` failing FAILS loudly, never skips.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DETECTOR="$ROOT/scripts/check-capability-refusal.sh"
HARNESS="$ROOT/tests/_lib/auto-merge-gate-harness.sh"
ORIG_PWD="$PWD"

for f in "$DETECTOR" "$HARNESS"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f does not exist"
    exit 1
  fi
done

TMP="$(cd "$(mktemp -d)" && pwd -P)"
# A genuinely NON-git dir, allocated OUTSIDE $TMP so it cannot inherit a repo
# from the fixture tree.
NONGIT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'cd / 2>/dev/null; rm -rf "$TMP" "$NONGIT"' EXIT

# Assembled at runtime so this test file is never itself a scan false-positive
# (precedent: scripts/check-cross-cutting-guards.sh:121).
SENT="CAPABILITY-""REFUSED:"

ISSUE=1246

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

# --- git worktree fixture --------------------------------------------------
mkdir -p "$TMP/main"
if ! git -c init.defaultBranch=main init -q "$TMP/main" 2>/dev/null; then
  echo "FAIL: git init unavailable — cannot build the worktree fixture"
  exit 1
fi
git -C "$TMP/main" config user.email t@t.t
git -C "$TMP/main" config user.name t
git -C "$TMP/main" config commit.gpgsign false
if ! git -C "$TMP/main" commit -q --allow-empty -m init 2>/dev/null; then
  echo "FAIL: git commit unavailable — cannot build the worktree fixture"
  exit 1
fi
if ! git -C "$TMP/main" worktree add -q -b wt-1246 "$TMP/wt" 2>/dev/null; then
  echo "FAIL: git worktree add unavailable — cannot build the worktree fixture"
  exit 1
fi

MAIN="$(cd "$TMP/main" && pwd -P)"
WT="$(cd "$TMP/wt" && pwd -P)"
LOGDIR="$MAIN/.claude/logs/subagents"

if git -C "$NONGIT" rev-parse --git-common-dir >/dev/null 2>&1; then
  echo "FAIL: fixture precondition broken — $NONGIT resolves a git dir; the"
  echo "      unresolvable-root case cannot be exercised on this host."
  exit 1
fi

# --- gh shim (from tests/test-auto-merge-gate-capability-refusal.sh) --------
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
source "$HARNESS"

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

# --- Step 11.2 call-site contract under test -------------------------------
CR_LINE=""
CR_STATE=""
CR_DIR=""

# resolve_and_thread — mirrors skills/evaluate-issue-pr/SKILL.md Step 11.2:
# resolve from the CURRENT working directory, then export the knob only when
# the resolver reports `resolved`.
resolve_and_thread() {
  unset PIPELINE_CAPABILITY_REFUSAL_SOURCES
  CR_LINE="$(env -u PIPELINE_PROJECT_ROOT -u PIPELINE_CAPABILITY_REFUSAL_SOURCES \
    bash "$DETECTOR" --resolve-sources 2>/dev/null)"
  CR_STATE="${CR_LINE%% *}"
  CR_STATE="${CR_STATE#SOURCES=}"
  case "$CR_LINE" in
    SOURCES=*DIR=*) CR_DIR="${CR_LINE##*DIR=}" ;;
    *) CR_DIR="" ;;
  esac
  case "$CR_STATE" in
    resolved) export PIPELINE_CAPABILITY_REFUSAL_SOURCES="$CR_DIR" ;;
  esac
}

# --- gate runner -----------------------------------------------------------
STDOUT_LINE=""
STDERR_TXT=""
GATE_RC=0

# run_gate — asserts case (f) for EVERY invocation: gate stdout is exactly one
# token line.
run_gate() {
  local label="$1" errf="$TMP/gate.err" out nlines
  : >"$errf"
  out="$(auto_merge_should_fire "$ISSUE" 1 2>"$errf")"
  GATE_RC=$?
  STDOUT_LINE="$out"
  STDERR_TXT="$(cat "$errf")"
  nlines="$(printf '%s' "$out" | grep -c '')"
  if [ "$nlines" = "1" ]; then
    pass "(f) $label: gate stdout is exactly one token line"
  else
    fail "(f) $label: expected exactly 1 stdout line, got $nlines ('$out')"
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

echo "=== (b) fixture-validity control — the worktree has no .claude/logs/ ==="
mk_record "$LOGDIR" "execute-${ISSUE}-path-b_aaaa1111.json" \
  "$SENT cannot perform the mandated task"
cd "$WT" || exit 1
if [ ! -d "$PWD/.claude/logs/subagents" ]; then
  pass "(b) the pre-fix resolution target \$(pwd)/.claude/logs/subagents does not exist in the worktree"
else
  fail "(b) fixture invalid: the worktree unexpectedly has .claude/logs/subagents"
fi
if [ -d "$LOGDIR" ]; then
  pass "(b) positive control: the MAIN checkout DOES carry the log dir"
else
  fail "(b) fixture invalid: the main checkout is missing $LOGDIR"
fi
cd "$ORIG_PWD" || exit 1

echo "=== (a) THE REGRESSION — refusal blocks when the gate runs from a worktree ==="
reset_env
cd "$WT" || exit 1
resolve_and_thread
check "(a) resolver state from the worktree" "resolved" "$CR_STATE"
check "(a) resolved DIR is the MAIN checkout log dir" "$LOGDIR" "$CR_DIR"
check "(a) the knob is threaded" "$LOGDIR" "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}"
run_gate "(a)"
check "(a) token" "block-capability-refused" "$STDOUT_LINE"
check "(a) return code" "1" "$GATE_RC"
cd "$ORIG_PWD" || exit 1

echo "=== (c) a CLEAN record resolved from the worktree must not false-block ==="
rm -f "$LOGDIR/execute-${ISSUE}-path-b_aaaa1111.json"
mk_record "$LOGDIR" "execute-${ISSUE}-path-b_bbbb2222.json" \
  "all tasks implemented; suite green"
reset_env
cd "$WT" || exit 1
resolve_and_thread
check "(c) resolver state from the worktree" "resolved" "$CR_STATE"
check "(c) the knob is threaded" "$LOGDIR" "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}"
run_gate "(c)"
check "(c) token" "green" "$STDOUT_LINE"
check "(c) return code" "0" "$GATE_RC"
cd "$ORIG_PWD" || exit 1

echo "=== (d) fail-open — genuine absence of the log dir (no-log-dir) ==="
rm -rf "$MAIN/.claude"
reset_env
cd "$WT" || exit 1
resolve_and_thread
check "(d) resolver state" "no-log-dir" "$CR_STATE"
check "(d) the knob is left UNexported" "" "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}"
run_gate "(d)"
check "(d) token" "green" "$STDOUT_LINE"
check "(d) return code" "0" "$GATE_RC"
cd "$ORIG_PWD" || exit 1

echo "=== (e) fail-open — unresolvable root (non-git cwd) ==="
reset_env
cd "$NONGIT" || exit 1
resolve_and_thread
check "(e) resolver state" "unresolvable-root" "$CR_STATE"
check "(e) the knob is left UNexported" "" "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}"
run_gate "(e)"
check "(e) token" "green" "$STDOUT_LINE"
check "(e) return code" "0" "$GATE_RC"
cd "$ORIG_PWD" || exit 1

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
