#!/bin/bash
set -uo pipefail
#
# tests/test-fullsend-helpers-parallel.sh — issue #1548.
#
# The fullsend wave helpers fan their per-issue gh reads out through
# scripts/_helper-parallel.sh (helper_parallel_map, cap PIPELINE_HELPER_PARALLEL,
# default 4). This test pins the two halves of that contract:
#   - TIMING: the default cap overlaps the per-issue reads; cap 1 is serial.
#   - ORDER:  stdout is one line per issue in argv order, byte-identical across
#             caps (only wall time differs).
#
# Substrate (shared with tests/test-fullsend-helpers.sh): a stub `gh` on PATH
# logs every call; `git init` worktrees wt-<N>-foo (N=11..14) on branch
# feature/i<N> supply the branch. The stub sleeps ${GH_SLEEP:-1}s ONLY on
# `pr list … --head` (one per issue) and answers PR #1<N> for issue <N>.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/scripts"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
echo "gh $*" >> "$GH_LOG"
args=" $* "
case "$1 $2" in
  "pr list")
    case "$args" in
      *" --head "*)
        sleep "${GH_SLEEP:-1}"
        br="${args##* --head }"; br="${br%% *}"
        echo "1${br##*i}" ;;
      *) echo "" ;;
    esac ;;
  "pr view")
    case "$args" in
      *" --json files "*)
        sleep "${GH_FILES_SLEEP:-0}"
        echo "shared/path.sh"
        echo "only/$3.sh" ;;
      *baseRefName*) echo "${GH_BASE:-}" ;;
      *) echo "" ;;
    esac ;;
  "issue view") printf '%s\n' ${GH_LABELS:-} ;;
  "api "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/gh"

PROJ="$TMP/proj"
for N in 11 12 13 14; do
  W="$PROJ/.claude/worktrees/wt-$N-foo"
  mkdir -p "$W"
  git -C "$W" init -q -b "feature/i$N" 2>/dev/null \
    || { git -C "$W" init -q && git -C "$W" symbolic-ref HEAD "refs/heads/feature/i$N"; }
done

export GH_LOG="$TMP/gh.log"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="o/r" PIPELINE_BASE_BRANCH="evolve" PIPELINE_PROJECT_ROOT="$PROJ"
export PIPELINE_WORKTREE_PREFIX="wt" PIPELINE_SCREENSHOT_REWRITE_ENABLED=false
export PIPELINE_MERGEABILITY_POLL_MAX=1
unset CLAUDE_PLUGIN_ROOT MANUAL_MERGE PIPELINE_HELPER_PARALLEL 2>/dev/null || true

# timed <cmd...> — sets OUT, RC, ELAPSED (whole seconds, date +%s).
timed() {
  : > "$GH_LOG"
  local t0; t0=$(date +%s)
  OUT="$(cd "$PROJ" && "$@" 2>"$TMP/err")"; RC=$?
  ELAPSED=$(( $(date +%s) - t0 ))
}

# ---------------------------------------------------------------------------
scenario "G1: fullsend-gate.sh default cap overlaps the per-issue gh reads"

timed bash "$S/fullsend-gate.sh" 11 12 13 14
G_PAR_OUT="$OUT"
EXPECT_ORDER="$(printf '#%s\n' 11 12 13 14)"
GOT_ORDER="$(printf '%s\n' "$OUT" | grep '^GATE: ' | sed -E 's/^GATE: issue=(#[0-9]+) .*/\1/')"
if [ "$(printf '%s\n' "$OUT" | grep -c '^GATE: ')" = "4" ] && [ "$GOT_ORDER" = "$EXPECT_ORDER" ]; then
  pass_msg "exactly 4 GATE lines in argv order"
else
  fail_msg "GATE lines not 4-in-argv-order: $OUT"
fi
if printf '%s\n' "$OUT" | grep -q '^GATE: issue=#13 pr=#113 reason='; then
  pass_msg "each issue gates its own PR (#13 -> #113)"
else
  fail_msg "issue 13 line wrong: $OUT"
fi
if [ "$ELAPSED" -lt 4 ]; then
  pass_msg "default cap elapsed ${ELAPSED}s < 4s (reads overlap)"
else
  fail_msg "default cap elapsed ${ELAPSED}s >= 4s (serial loop)"
fi

# ---------------------------------------------------------------------------
scenario "G2: PIPELINE_HELPER_PARALLEL=1 is serial with the same output"

PIPELINE_HELPER_PARALLEL=1 timed bash "$S/fullsend-gate.sh" 11 12 13 14
if [ "$OUT" = "$G_PAR_OUT" ]; then
  pass_msg "cap 1 stdout byte-identical to the default cap"
else
  fail_msg "cap 1 stdout differs: $OUT"
fi
if [ "$ELAPSED" -ge 4 ]; then
  pass_msg "cap 1 elapsed ${ELAPSED}s >= 4s (serial)"
else
  fail_msg "cap 1 elapsed ${ELAPSED}s < 4s (not serial)"
fi

# ---------------------------------------------------------------------------
scenario "G3: a one-issue run is byte-identical to that issue's wave line"

timed bash "$S/fullsend-gate.sh" 12
if [ "$OUT" = "$(printf '%s\n' "$G_PAR_OUT" | sed -n 2p)" ]; then
  pass_msg "one-issue stdout == wave line 2"
else
  fail_msg "one-issue stdout '$OUT' != wave line 2"
fi

# ---------------------------------------------------------------------------
scenario "P1/P2: fullsend-preflight.sh overlaps per-issue work, same output"

# The preflight floor is the in-worktree guards pr-eval-preflight.sh runs
# (~4 s per issue), not gh, so the bound is RELATIVE: serial minus parallel.
timed bash "$S/fullsend-preflight.sh" 11 12 13 14
P_PAR_OUT="$OUT"; P_PAR_T="$ELAPSED"
PIPELINE_HELPER_PARALLEL=1 timed bash "$S/fullsend-preflight.sh" 11 12 13 14
P_SER_OUT="$OUT"; P_SER_T="$ELAPSED"
GOT_ORDER="$(printf '%s\n' "$P_PAR_OUT" | grep '^PREFLIGHT issue=#' | sed -E 's/^PREFLIGHT issue=(#[0-9]+) .*/\1/')"
if [ "$(printf '%s\n' "$P_PAR_OUT" | grep -c '^PREFLIGHT issue=#')" = "4" ] && [ "$GOT_ORDER" = "$EXPECT_ORDER" ]; then
  pass_msg "P1: exactly 4 PREFLIGHT lines in argv order"
else
  fail_msg "P1: PREFLIGHT lines not 4-in-argv-order: $P_PAR_OUT"
fi
if [ "$P_PAR_OUT" = "$P_SER_OUT" ]; then
  pass_msg "P2: cap 1 stdout byte-identical to the default cap"
else
  fail_msg "P2: cap 1 stdout differs: $P_SER_OUT"
fi
if [ $((P_SER_T - P_PAR_T)) -ge 3 ]; then
  pass_msg "P1: serial ${P_SER_T}s - parallel ${P_PAR_T}s >= 3s"
else
  fail_msg "P1: serial ${P_SER_T}s - parallel ${P_PAR_T}s < 3s (not overlapped)"
fi

# ---------------------------------------------------------------------------
scenario "O1: detect-merge-overlap.sh prefetches every PR's files concurrently"

# The stub sleeps GH_FILES_SLEEP s on `pr view <P> --json files` and prints one
# shared path per PR, so every pair overlaps.
dmo() { ( source "$S/detect-merge-overlap.sh" && detect_merge_overlap "$@" ); }
dmo_both() { ( source "$S/detect-merge-overlap.sh" && detect_merge_overlap "$@" && echo "ORDER $(recommend_merge_order "$@" | tr '\n' ' ')" ); }
export GH_FILES_SLEEP=1
timed dmo 101 102 103 104
O_PAR_T="$ELAPSED"
unset GH_FILES_SLEEP
timed dmo_both 101 102 103 104
O_PAR_OUT="$OUT"
PIPELINE_HELPER_PARALLEL=1 timed dmo_both 101 102 103 104
O_SER_OUT="$OUT"
if [ "$(printf '%s\n' "$O_PAR_OUT" | grep -c '^OVERLAP ')" = "6" ] && [ "$O_PAR_OUT" = "$O_SER_OUT" ]; then
  pass_msg "6 OVERLAP lines, identical to the PIPELINE_HELPER_PARALLEL=1 run"
else
  fail_msg "overlap output differs or wrong (par: $O_PAR_OUT | ser: $O_SER_OUT)"
fi
# Serial would be 4 s (one 1 s files read per PR).
if [ "$O_PAR_T" -lt 4 ]; then
  pass_msg "default cap elapsed ${O_PAR_T}s < 4s (prefetch overlaps)"
else
  fail_msg "default cap elapsed ${O_PAR_T}s >= 4s (serial file reads)"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
