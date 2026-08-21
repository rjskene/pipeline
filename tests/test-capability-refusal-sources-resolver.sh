#!/usr/bin/env bash
# test-capability-refusal-sources-resolver.sh — #1246 worktree-aware
# capability-refusal source resolution.
#
# THE DEFECT. `skills/evaluate-issue-pr/SKILL.md` Step 11.2 resolved the #1233
# detector's source directory as
# ${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/logs/subagents. But pr-eval ALWAYS
# runs from a feature WORKTREE, and a linked worktree has no `.claude/logs/` of
# its own. With PIPELINE_PROJECT_ROOT unset (the default — the knob is commented
# out in pipeline.config), $(pwd) is the worktree, the path never exists,
# PIPELINE_CAPABILITY_REFUSAL_SOURCES is never threaded, and the gate arm sits
# permanently at REASON=no-sources. The #1233 guard is fail-open with no teeth.
#
# THE FIX UNDER TEST. An additive `--resolve-sources [<start-dir>]` mode on
# scripts/check-capability-refusal.sh that resolves the log dir against the MAIN
# checkout and emits EXACTLY ONE line, ALWAYS exit 0:
#
#   SOURCES=<resolved|no-log-dir|unresolvable-root> ROOT=<root-or-empty> DIR=<dir-or-empty>
#
# Root-resolution precedence (first usable wins):
#   1. $PIPELINE_PROJECT_ROOT when non-empty AND -d (#1215 operator override).
#      Non-empty-but-not-a-dir falls THROUGH to tier 2.
#   2. `git -C "$START" rev-parse --git-common-dir`, normalized against $START,
#      then its parent. `--git-common-dir` points at the MAIN checkout's .git
#      even from a linked worktree, where `--show-toplevel` would return the
#      worktree. The relative-output normalization is load-bearing: from the
#      main checkout git returns a bare `.git`, and from a main-checkout SUBDIR
#      it returns `../../.git`.
#   3. neither -> SOURCES=unresolvable-root.
#
# THE THREE-TOKEN CONTRACT is the distinguishability mechanism the issue asks
# for: `no-log-dir` (root resolved, log dir genuinely absent — the legitimate
# PIPELINE_LOGS_ENABLED=false consumer case) must never be confused with
# `unresolvable-root` (no main checkout resolvable — the misresolution class).
# Both leave the knob unexported at the call site, so fail-open is STRUCTURAL:
# no new code path can emit a block token.
#
# Fixtures are REAL `git worktree` checkouts under mktemp -d. `git worktree add`
# failing must FAIL loudly — never skip-and-pass. Assertions use `grep -F` and
# `case` globs, never ERE anchored-alternation (`grep` on the dogfood host is
# ugrep 7.5.0 — see the MATCH RULE note in scripts/check-capability-refusal.sh).
# Path comparisons normalize both sides with `cd X && pwd -P` (symlinked TMPDIR).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DETECTOR="$ROOT/scripts/check-capability-refusal.sh"
EVAL_SKILL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
GATE="$ROOT/scripts/auto-merge-gate.sh"
OBSERVABILITY="$ROOT/docs/observability.md"

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

refute() {
  local name="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    pass "$name (correctly not '$unexpected')"
  else
    fail "$name unexpectedly equals '$unexpected'"
  fi
}

# not_prefix <name> <prefix> <string>
not_prefix() {
  local name="$1" prefix="$2" s="$3"
  case "$s" in
    "$prefix"*) fail "$name: '$s' starts with '$prefix'" ;;
    *) pass "$name" ;;
  esac
}

if [ ! -f "$DETECTOR" ]; then
  echo "FAIL: $DETECTOR does not exist"
  exit 1
fi

# --- fixtures --------------------------------------------------------------
TMP="$(cd "$(mktemp -d)" && pwd -P)"
# A genuinely NON-git directory, allocated OUTSIDE $TMP so it cannot inherit a
# repo from the fixture tree (recommendation 3 of the plan evaluation).
NONGIT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'cd / 2>/dev/null; rm -rf "$TMP" "$NONGIT"' EXIT

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
mkdir -p "$LOGDIR"

# A SECOND checkout used as the explicit PIPELINE_PROJECT_ROOT override (f).
mkdir -p "$TMP/other"
git -c init.defaultBranch=main init -q "$TMP/other" 2>/dev/null
OTHER="$(cd "$TMP/other" && pwd -P)"
mkdir -p "$OTHER/.claude/logs/subagents"

# A subdirectory of the MAIN checkout — from here `git rev-parse
# --git-common-dir` returns a RELATIVE `../../.git`, which the resolver must
# normalize against the start dir.
mkdir -p "$MAIN/sub/dir"
MAIN_SUBDIR="$(cd "$MAIN/sub/dir" && pwd -P)"

# Guard the (e)/(i) fixture: if the host's TMPDIR ever sits inside a repo this
# case would silently degrade, so assert the precondition loudly instead.
if git -C "$NONGIT" rev-parse --git-common-dir >/dev/null 2>&1; then
  echo "FAIL: fixture precondition broken — $NONGIT resolves a git dir; the"
  echo "      unresolvable-root case cannot be exercised on this host."
  exit 1
fi

# --- resolver runner -------------------------------------------------------
# RES_LINE / RES_RC are set by run_resolver. $PPR controls tier 1:
# "unset" scrubs PIPELINE_PROJECT_ROOT; any other value is exported for the
# single invocation.
RES_LINE=""
RES_RC=0
PPR="unset"

# run_resolver <label> <start-cwd> [extra-args...]
run_resolver() {
  local label="$1" dir="$2"
  shift 2
  local errf="$TMP/resolver.err" out nlines
  : >"$errf"
  if [ "$PPR" = "unset" ]; then
    out="$(cd "$dir" && env -u PIPELINE_PROJECT_ROOT -u PIPELINE_CAPABILITY_REFUSAL_SOURCES \
      bash "$DETECTOR" --resolve-sources "$@" 2>"$errf")"
  else
    out="$(cd "$dir" && env -u PIPELINE_CAPABILITY_REFUSAL_SOURCES \
      PIPELINE_PROJECT_ROOT="$PPR" \
      bash "$DETECTOR" --resolve-sources "$@" 2>"$errf")"
  fi
  RES_RC=$?
  RES_LINE="$out"
  # (h) fail-open contract, asserted on EVERY invocation above.
  check "(h) $label exit code" "0" "$RES_RC"
  nlines="$(printf '%s' "$out" | grep -c '')"
  check "(h) $label stdout is exactly one line" "1" "$nlines"
}

# Total parsers over the token line. `<unparsable>` when the emitted line is not
# a SOURCES= line at all (which is exactly what the pre-fix detector emits: it
# parses `--resolve-sources` as the ISSUE argument).
res_state() {
  case "$RES_LINE" in
    SOURCES=*) local s="${RES_LINE%% *}"; printf '%s' "${s#SOURCES=}" ;;
    *) printf '%s' '<unparsable>' ;;
  esac
}
res_root() {
  case "$RES_LINE" in
    SOURCES=*ROOT=*) local r="${RES_LINE#*ROOT=}"; printf '%s' "${r%% *}" ;;
    *) printf '%s' '<unparsable>' ;;
  esac
}
# DIR= is emitted LAST so a path containing spaces still parses.
res_dir() {
  case "$RES_LINE" in
    SOURCES=*DIR=*) printf '%s' "${RES_LINE##*DIR=}" ;;
    *) printf '%s' '<unparsable>' ;;
  esac
}

echo "=== (a) from the MAIN checkout with the log dir present ==="
PPR="unset"
run_resolver "(a)" "$MAIN"
check "(a) SOURCES" "resolved" "$(res_state)"
check "(a) ROOT" "$MAIN" "$(res_root)"
check "(a) DIR" "$LOGDIR" "$(res_dir)"

echo "=== (a2) from a SUBDIR of the main checkout (relative ../../.git) ==="
PPR="unset"
run_resolver "(a2)" "$MAIN_SUBDIR"
check "(a2) SOURCES" "resolved" "$(res_state)"
check "(a2) ROOT is the main root, not the subdir" "$MAIN" "$(res_root)"
check "(a2) DIR" "$LOGDIR" "$(res_dir)"

echo "=== (b) THE REGRESSION — from a linked WORKTREE with no .claude/ ==="
if [ -d "$WT/.claude/logs/subagents" ]; then
  fail "(b) fixture invalid: the linked worktree unexpectedly has .claude/logs/subagents"
else
  pass "(b) fixture valid: the linked worktree has no .claude/logs/subagents of its own"
fi
PPR="unset"
run_resolver "(b)" "$WT"
check "(b) SOURCES" "resolved" "$(res_state)"
check "(b) ROOT is the MAIN checkout, not the worktree" "$MAIN" "$(res_root)"
check "(b) DIR" "$LOGDIR" "$(res_dir)"
not_prefix "(b) DIR does not start with the worktree path" "$WT" "$(res_dir)"

echo "=== (c) explicit start-dir form is identical to (b) ==="
PPR="unset"
run_resolver "(c)" "$TMP" "$WT"
check "(c) SOURCES" "resolved" "$(res_state)"
check "(c) ROOT" "$MAIN" "$(res_root)"
check "(c) DIR" "$LOGDIR" "$(res_dir)"

echo "=== (f) PIPELINE_PROJECT_ROOT override wins over the git tier ==="
PPR="$OTHER"
run_resolver "(f)" "$WT"
check "(f) SOURCES" "resolved" "$(res_state)"
check "(f) ROOT is the override" "$OTHER" "$(res_root)"
check "(f) DIR is under the override" "$OTHER/.claude/logs/subagents" "$(res_dir)"

echo "=== (g) PIPELINE_PROJECT_ROOT set-but-nonexistent falls THROUGH ==="
PPR="$TMP/no-such-project-root"
run_resolver "(g)" "$WT"
check "(g) SOURCES" "resolved" "$(res_state)"
check "(g) ROOT falls through to the git tier" "$MAIN" "$(res_root)"
refute "(g) a stale override must not short-circuit" "unresolvable-root" "$(res_state)"

echo "=== (e) misresolution class — a NON-git start dir ==="
PPR="unset"
run_resolver "(e)" "$NONGIT"
check "(e) SOURCES" "unresolvable-root" "$(res_state)"
check "(e) ROOT is empty" "" "$(res_root)"
check "(e) DIR is empty" "" "$(res_dir)"
refute "(e) distinguishable from a genuine missing log dir" "no-log-dir" "$(res_state)"

echo "=== (i) anti-BASH_SOURCE — resolution keys off cwd, never the script ==="
# Same invocation as (e): on a consumer install this script lives under
# ~/.claude/plugins/claude-pipeline/, which is NOT the project.
refute "(i) ROOT is not the pipeline repo root" "$ROOT" "$(res_root)"
refute "(i) DIR is not the pipeline repo log dir" "$ROOT/.claude/logs/subagents" "$(res_dir)"
not_prefix "(i) DIR does not start with the pipeline repo root" "$ROOT/" "$(res_dir)"

echo "=== (d) genuine missing log dir on a resolvable root ==="
rm -rf "$MAIN/.claude"
PPR="unset"
run_resolver "(d) from main" "$MAIN"
check "(d) SOURCES" "no-log-dir" "$(res_state)"
check "(d) ROOT is still populated" "$MAIN" "$(res_root)"
check "(d) DIR is empty" "" "$(res_dir)"
refute "(d) distinguishable from an unresolvable root" "unresolvable-root" "$(res_state)"

PPR="unset"
run_resolver "(d) from the worktree" "$WT"
check "(d) SOURCES from the worktree" "no-log-dir" "$(res_state)"
check "(d) ROOT from the worktree" "$MAIN" "$(res_root)"

echo "=== (j) control — the additive mode does not break the existing contract ==="
J_DIR="$TMP/j-sources"
mkdir -p "$J_DIR"
J_LINE="$(env -u PIPELINE_PROJECT_ROOT -u PIPELINE_CAPABILITY_REFUSAL_SOURCES \
  bash "$DETECTOR" 1233 "$J_DIR" 2>/dev/null)"
J_RC=$?
check "(j) issue-number mode exit code" "0" "$J_RC"
case "$J_LINE" in
  CAPABILITY_REFUSAL=*ISSUE=1233*) pass "(j) issue-number mode still emits its own line -> $J_LINE" ;;
  *) fail "(j) expected a CAPABILITY_REFUSAL= line for issue 1233, got: '$J_LINE'" ;;
esac
env -u PIPELINE_PROJECT_ROOT -u PIPELINE_CAPABILITY_REFUSAL_SOURCES \
  bash "$DETECTOR" >/dev/null 2>&1
check "(j) zero args still exits 2" "2" "$?"

# --- static wiring assertions ----------------------------------------------

# min_distance <file> <patternA> <patternB> — smallest |lineA - lineB| over all
# matching line pairs; prints 999999 when either side has no match. Idiom copied
# from tests/test-evaluate-pr-capability-refusal-prose.sh.
min_distance() {
  local file="$1" a="$2" b="$3"
  A_PAT="$a" B_PAT="$b" python3 - "$file" <<'PY'
import os, sys
a = os.environ["A_PAT"]
b = os.environ["B_PAT"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
al = [i for i, l in enumerate(lines) if a in l]
bl = [i for i, l in enumerate(lines) if b in l]
print(min((abs(x - y) for x in al for y in bl), default=999999))
PY
}

# slice_between <file> <start-marker> <end-marker> — the start marker's line
# through the line BEFORE the first subsequent end-marker line (end-EXCLUSIVE).
slice_between() {
  local file="$1" start="$2" end="$3"
  START_M="$start" END_M="$end" python3 - "$file" <<'PY'
import os, sys
start = os.environ["START_M"]
end = os.environ["END_M"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
out, started = [], False
for l in lines:
    if not started:
        if start in l:
            started = True
            out.append(l)
        continue
    if end in l:
        break
    out.append(l)
sys.stdout.write("\n".join(out))
PY
}

# header_comment <file> — every line before the first non-blank, non-# line.
header_comment() {
  python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
out = []
for l in lines:
    if l.strip() and not l.lstrip().startswith("#"):
        break
    out.append(l)
sys.stdout.write("\n".join(out))
PY
}

DEFECT_LITERAL='${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/logs/subagents'

echo "=== (k) Step 11.2 no longer resolves the sources dir from \$(pwd) ==="
if [ ! -f "$EVAL_SKILL" ]; then
  fail "(k) $EVAL_SKILL does not exist"
elif grep -qF "$DEFECT_LITERAL" "$EVAL_SKILL"; then
  fail "(k) $EVAL_SKILL still contains the defect literal: $DEFECT_LITERAL"
else
  pass "(k) the \$(pwd)-relative sources path is gone from evaluate-issue-pr"
fi

echo "=== (l) Step 11.2 calls the resolver at the auto_merge_should_fire site ==="
if [ ! -f "$EVAL_SKILL" ]; then
  fail "(l) $EVAL_SKILL does not exist"
else
  if grep -F -- '--resolve-sources' "$EVAL_SKILL" | grep -qF 'check-capability-refusal.sh'; then
    pass "(l) evaluate-issue-pr invokes check-capability-refusal.sh --resolve-sources"
  else
    fail "(l) no line invokes check-capability-refusal.sh with --resolve-sources"
  fi
  L_DIST="$(min_distance "$EVAL_SKILL" 'auto_merge_should_fire' '--resolve-sources')"
  if [ "$L_DIST" -le 15 ] 2>/dev/null; then
    pass "(l) --resolve-sources is invoked within $L_DIST line(s) of auto_merge_should_fire"
  else
    fail "(l) --resolve-sources is not invoked at the auto_merge_should_fire call site (min distance $L_DIST)"
  fi
fi

echo "=== (m) Step 11.2 names all three resolver tokens ==="
if [ ! -f "$EVAL_SKILL" ]; then
  fail "(m) $EVAL_SKILL does not exist"
else
  M_SLICE="$(slice_between "$EVAL_SKILL" '**Source the helper and run the gate.**' '**Split-role gate')"
  if [ -z "$M_SLICE" ]; then
    fail "(m) Step 11.2 ('Source the helper and run the gate.') not found in $EVAL_SKILL"
  else
    for tok in resolved no-log-dir unresolvable-root; do
      if printf '%s' "$M_SLICE" | grep -qF "$tok"; then
        pass "(m) Step 11.2 names the '$tok' token"
      else
        fail "(m) Step 11.2 does not name the '$tok' token"
      fi
    done
  fi
fi

echo "=== (n) docs/observability.md documents the worktree-aware resolution ==="
if [ ! -f "$OBSERVABILITY" ]; then
  fail "(n) $OBSERVABILITY does not exist"
else
  N_SECTION="$(MARKER='## Subagent log' python3 - "$OBSERVABILITY" <<'PY'
import os, sys
marker = os.environ["MARKER"]
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
out, started = [], False
for l in lines:
    if not started:
        if l.strip() == marker:
            started = True
        continue
    if l.startswith("## "):
        break
    out.append(l)
sys.stdout.write("\n".join(out))
PY
)"
  if [ -z "$N_SECTION" ]; then
    fail "(n) no '## Subagent log' section found in $OBSERVABILITY"
  else
    for tok in worktree --resolve-sources no-log-dir unresolvable-root; do
      if printf '%s' "$N_SECTION" | grep -qF -- "$tok"; then
        pass "(n) the '## Subagent log' section documents '$tok'"
      else
        fail "(n) the '## Subagent log' section never documents '$tok'"
      fi
    done
  fi
fi

echo "=== (o) auto-merge-gate.sh header names the resolver mode ==="
if [ ! -f "$GATE" ]; then
  fail "(o) $GATE does not exist"
else
  O_HEADER="$(header_comment "$GATE")"
  if [ -z "$O_HEADER" ]; then
    fail "(o) no header comment block found in $GATE"
  elif printf '%s' "$O_HEADER" | grep -qF -- '--resolve-sources'; then
    pass "(o) the gate header names check-capability-refusal.sh --resolve-sources"
  else
    fail "(o) the gate header comment never names --resolve-sources"
  fi
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
