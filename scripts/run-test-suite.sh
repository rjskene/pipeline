#!/usr/bin/env bash
# run-test-suite.sh — parallel test runner with STRICT aggregate fail.
#
# Fans tests/test*.sh + tests/test_*.sh across cores via `xargs -P`. xargs masks
# child exit codes by default (and `--halt` semantics on high exit codes like 250
# are unreliable across xargs builds), so each child appends a marker line to a
# shared mktemp file on failure and we exit non-zero iff that file is non-empty
# — strict fail survives even high/128+ exit codes (issue #897 acceptance bar).
#
# Two phases: a PARALLEL fan-out records candidate failures, then a SERIAL retry
# of those candidates confirms real failures vs. load-induced SIGPIPE flakes
# (see the Phase 2 note below). Only twice-failing tests red the run.
#
# Usage:
#   scripts/run-test-suite.sh [tests-dir]
#   TESTS_DIR=path scripts/run-test-suite.sh
#   PIPELINE_TEST_PARALLELISM=N scripts/run-test-suite.sh   # override -P
#   scripts/run-test-suite.sh --chunk k/n [tests-dir]        # FOREGROUND chunk mode
#   TESTS_DIR=path scripts/run-test-suite.sh --chunk k/n
#
# --chunk k/n (issue #1208) is the FOREGROUND escape hatch for suites too large
# to fit inside a single Bash-call timeout: it runs only the k-th of n
# deterministic stride-partitioned slices of the corpus and prints exactly one
# `CHUNK=k/n FILES=<count> RESULT=pass|fail` summary line. Run `--chunk 1/n`
# through `--chunk n/n` as separate sequential foreground Bash calls instead of
# backgrounding the full suite. Default (no `--chunk`) output is unchanged.
#
# Each test is wrapped in `timeout 300` and `</dev/null` (mirrors the live
# runner's hang-guard so an interactive `read` or a hang can't wedge a job).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --chunk k/n (or --chunk=k/n) parsing — MUST happen before TESTS_DIR
# resolution so the positional tests-dir and the TESTS_DIR env form both keep
# working with a leading --chunk flag shifted off.
CHUNK_MODE=0
CHUNK_RAW=""
CHUNK_K=""
CHUNK_N=""

if [ $# -gt 0 ]; then
  case "$1" in
    --chunk=*)
      CHUNK_MODE=1
      CHUNK_RAW="${1#--chunk=}"
      shift
      ;;
    --chunk)
      CHUNK_MODE=1
      CHUNK_RAW="${2:-}"
      if [ $# -ge 2 ]; then
        shift 2
      else
        shift 1
      fi
      ;;
  esac
fi

if [ "$CHUNK_MODE" -eq 1 ]; then
  if [[ "$CHUNK_RAW" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    CHUNK_K="${BASH_REMATCH[1]}"
    CHUNK_N="${BASH_REMATCH[2]}"
  fi

  chunk_valid=1
  if [ -z "$CHUNK_K" ] || [ -z "$CHUNK_N" ]; then
    chunk_valid=0
  elif [ "$((10#$CHUNK_N))" -lt 1 ]; then
    chunk_valid=0
  elif [ "$((10#$CHUNK_K))" -lt 1 ] || [ "$((10#$CHUNK_K))" -gt "$((10#$CHUNK_N))" ]; then
    chunk_valid=0
  fi

  if [ "$chunk_valid" -ne 1 ]; then
    echo "run-test-suite.sh: invalid --chunk $CHUNK_RAW (expected k/n with 1<=k<=n)" >&2
    exit 2
  fi

  CHUNK_K="$((10#$CHUNK_K))"
  CHUNK_N="$((10#$CHUNK_N))"
fi

# tests dir: $1 > TESTS_DIR env > default "tests" (resolved under REPO_ROOT).
TESTS_DIR="${1:-${TESTS_DIR:-tests}}"
case "$TESTS_DIR" in
  /*) : ;;                          # absolute — use as-is
  *)  TESTS_DIR="$REPO_ROOT/$TESTS_DIR" ;;
esac

if [ ! -d "$TESTS_DIR" ]; then
  echo "run-test-suite.sh: tests dir not found: $TESTS_DIR" >&2
  exit 1
fi

# Parallelism: explicit override, else core count, else 1.
PAR="${PIPELINE_TEST_PARALLELISM:-}"
if [ -z "$PAR" ]; then
  PAR="$(nproc 2>/dev/null || echo 1)"
fi

# CANDIDATES records tests that failed in the PARALLEL pass; SENTINEL records
# tests CONFIRMED failing after a serial retry (the real failures).
CANDIDATES="$(mktemp)"
SENTINEL="$(mktemp)"
export CANDIDATES

# Per-file worker — exported so xargs-spawned bash subshells can call it.
# Folds the Actions log per file (::group::/::endgroup::) and records any
# failure (including high exit codes) into the shared CANDIDATES file.
run_one() {
  local t="$1"
  [ -f "$t" ] || return 0
  echo "::group::$t"
  local rc=0
  timeout 300 bash "$t" </dev/null || rc=$?
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    printf '%s\t%s\n' "$rc" "$t" >> "$CANDIDATES"
    echo "::error::$t failed in parallel pass (exit $rc) — will retry serially"
  fi
}
export -f run_one

# Phase 1 — PARALLEL fan-out. NUL-delimited to survive odd names; existence is
# re-checked in run_one to dodge failglob/nullglob surprises.
if [ "$CHUNK_MODE" -eq 1 ]; then
  # Build the full sorted file list exactly as default mode does, then select
  # a deterministic stride slice: 0-based index i belongs to chunk (i % n) + 1.
  FULL_LIST="$(mktemp)"
  find "$TESTS_DIR" -maxdepth 1 -type f \
    \( -name 'test*.sh' -o -name 'test_*.sh' \) -print0 \
    | sort -z > "$FULL_LIST"

  CHUNK_LIST="$(mktemp)"
  i=0
  while IFS= read -r -d '' f; do
    if [ "$((i % CHUNK_N))" -eq "$((CHUNK_K - 1))" ]; then
      printf '%s\0' "$f" >> "$CHUNK_LIST"
    fi
    i=$((i + 1))
  done < "$FULL_LIST"
  rm -f "$FULL_LIST"

  if [ -s "$CHUNK_LIST" ]; then
    FILE_COUNT="$(tr -cd '\0' < "$CHUNK_LIST" | wc -c | tr -d '[:space:]')"
  else
    FILE_COUNT=0
  fi

  xargs -0 -P "$PAR" -I{} bash -c 'run_one "$@"' _ {} < "$CHUNK_LIST"
  rm -f "$CHUNK_LIST"
else
  find "$TESTS_DIR" -maxdepth 1 -type f \
    \( -name 'test*.sh' -o -name 'test_*.sh' \) -print0 \
    | sort -z \
    | xargs -0 -P "$PAR" -I{} bash -c 'run_one "$@"' _ {}
fi

# Phase 2 — SERIAL retry of every parallel-pass failure. The corpus is riddled
# with `<producer> | grep -q` pipelines that, under `set -o pipefail`, return
# 141 (SIGPIPE) when grep short-circuits before the producer finishes writing —
# a load-induced FLAKE that surfaces only under the parallel fan-out (issue
# #897). A genuinely-broken test fails again here; a flake passes. This keeps
# STRICT aggregate fail intact (a real failure, including high exit codes like
# 250, reds both passes) while not manufacturing spurious failures. Retries run
# one-at-a-time with no contention, so the flake does not recur.
if [ -s "$CANDIDATES" ]; then
  echo "" >&2
  echo "Retrying $(wc -l < "$CANDIDATES") parallel-pass failure(s) serially..." >&2
  # De-dup the candidate paths (one retry per file regardless of how recorded).
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    echo "::group::retry $t"
    rc=0
    timeout 300 bash "$t" </dev/null || rc=$?
    echo "::endgroup::"
    if [ "$rc" -ne 0 ]; then
      printf '%s\t%s\n' "$rc" "$t" >> "$SENTINEL"
      echo "::error::$t failed on serial retry (exit $rc) — CONFIRMED failure"
    else
      echo "  RECOVERED on retry: $t (parallel-pass flake)" >&2
    fi
  done < <(cut -f2 "$CANDIDATES" | sort -u)
fi

rm -f "$CANDIDATES"

CHUNK_RESULT="pass"
if [ -s "$SENTINEL" ]; then
  echo "" >&2
  echo "================ FAILURES (confirmed after retry) ================" >&2
  cat "$SENTINEL" >&2
  echo "=================================================================" >&2
  CHUNK_RESULT="fail"
fi
rm -f "$SENTINEL"

if [ "$CHUNK_MODE" -eq 1 ]; then
  echo "CHUNK=$CHUNK_K/$CHUNK_N FILES=$FILE_COUNT RESULT=$CHUNK_RESULT"
fi

if [ "$CHUNK_RESULT" = "fail" ]; then
  exit 1
fi

exit 0
