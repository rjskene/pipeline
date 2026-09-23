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
#   PIPELINE_TEST_LEAK_GUARD_REPO=path scripts/run-test-suite.sh   # redirect leak guard ("" = off)
#   scripts/run-test-suite.sh --chunk k/n [tests-dir]        # FOREGROUND chunk mode
#   TESTS_DIR=path scripts/run-test-suite.sh --chunk k/n
#   scripts/run-test-suite.sh --changed-only [--base <ref>] [tests-dir]
#   TESTS_DIR=path scripts/run-test-suite.sh --changed-only
#   PIPELINE_TEST_ROOT_OVERRIDE=1 scripts/run-test-suite.sh   # keep the caller's
#     own PIPELINE_PROJECT_ROOT/CLAUDE_PLUGIN_ROOT/PIPELINE_USE_LOCAL_PLUGIN
#     instead of scrubbing them (unused elsewhere in this repo today)
#
# --chunk k/n (issue #1208) is the FOREGROUND escape hatch for suites too large
# to fit inside a single Bash-call timeout: it runs only the k-th of n
# deterministic stride-partitioned slices of the corpus and prints exactly one
# `CHUNK=k/n FILES=<count> RESULT=pass|fail` summary line. Run `--chunk 1/n`
# through `--chunk n/n` as separate sequential foreground Bash calls instead of
# backgrounding the full suite. Default (no `--chunk`) output is unchanged.
#
# --changed-only [--base <ref>] (issue #1334) runs only the diff's touched
# tests plus their SUBJECT tests (a test that names a touched path by full
# path, unique basename, or containing `<dir>/*` glob). The diff repo is the
# git toplevel of TESTS_DIR; base resolves --base > origin/$PIPELINE_BASE_BRANCH
# > origin/main. An unresolved base or a non-repo TESTS_DIR fails OPEN to the
# full suite with one `CHANGED-ONLY: <reason> — running the full suite` stderr
# line and no summary. Otherwise prints one `CHANGED-ONLY: touched=<n>
# selected=<k>/<total> scanners=<s> RESULT=pass|fail` line; mutually exclusive
# with --chunk. When the diff touches any tests/-dir path, always-run SCANNER
# tests are additionally selected — corpus tests whose text globs the tests
# dir itself (e.g. `"$TESTS_DIR"/test*.sh`) and so name no single touched path
# (issue #1339) — and counted in `scanners=<s>`.
#
# Each test is wrapped in `timeout 300` and `</dev/null` (mirrors the live
# runner's hang-guard so an interactive `read` or a hang can't wedge a job).
#
# Post-suite worktree/branch leak guard (issue #1316). Fixture tests that drive
# scripts/setup-worktree.sh once cut REAL worktrees + branches in the live repo
# when a session exported PIPELINE_PROJECT_ROOT (the script honours that var
# over cwd). The runner now snapshots `git worktree list --porcelain` and
# `git branch --list` of the guard repo BEFORE Phase 1 and again AFTER the
# serial retry, and DIFFS them: every entry that appeared during the run is
# printed on stdout as `LEAK: worktree=<path> branch=<name>` (a leaked branch
# attached to a leaked worktree is reported once on that line; an orphan branch
# prints `worktree=-`), a `::error::leak guard: ...` summary goes to stderr, and
# the run reds (`RESULT=fail` in chunk mode, exit 1 in both modes). A clean run
# emits nothing, so default-mode output stays byte-compatible. Removals are not
# leaks. The guard repo is the checkout this script lives in (REPO_ROOT; when
# that is a linked worktree, `git -C` there still lists the WHOLE shared repo's
# worktrees and branches — exactly where the leak lands);
# PIPELINE_TEST_LEAK_GUARD_REPO=<path> redirects it (how the regression test
# drives the guard against a throwaway repo) and an explicitly EMPTY value
# disables it. Known false-positive shape: a legitimate, concurrently-started
# orchestrator worktree (a real issue-number name such as wt-1317-<slug>, not a
# wt-100-bar-style fixture name) landing mid-run — that is not a suite failure;
# re-run, or set PIPELINE_TEST_LEAK_GUARD_REPO="" for that run. A guard repo
# that is not a git repository is silently skipped.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Own-root scrub (#1389): every test this script spawns (default parallel
# fan-out, --chunk, --changed-only — all inherit this exported process env)
# must see roots it re-derives itself from ITS OWN tree (cwd/dirname, each
# test's existing at-head fallback logic), not whatever a caller (skill boot
# fence, orchestrator session) already exported — else a worktree suite run
# silently tests the caller's tree. PIPELINE_TEST_ROOT_OVERRIDE=1 is the
# escape hatch (see Usage above).
scrub_roots() {
  if [ "${PIPELINE_TEST_ROOT_OVERRIDE:-0}" != "1" ]; then
    unset PIPELINE_PROJECT_ROOT CLAUDE_PLUGIN_ROOT PIPELINE_USE_LOCAL_PLUGIN
  fi
}
scrub_roots

# --chunk k/n (or --chunk=k/n), --changed-only, and --base <ref> parsing —
# MUST happen before TESTS_DIR resolution so the positional tests-dir and the
# TESTS_DIR env form both keep working with leading flags shifted off.
CHUNK_MODE=0
CHUNK_RAW=""
CHUNK_K=""
CHUNK_N=""
CHANGED_ONLY=0
BASE_REF=""

while [ $# -gt 0 ]; do
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
    --changed-only)
      CHANGED_ONLY=1
      shift
      ;;
    --base=*)
      BASE_REF="${1#--base=}"
      shift
      ;;
    --base)
      BASE_REF="${2:-}"
      if [ $# -ge 2 ]; then
        shift 2
      else
        shift 1
      fi
      ;;
    *)
      break
      ;;
  esac
done

# --changed-only and --chunk select mutually exclusive run modes (#1334).
if [ "$CHUNK_MODE" -eq 1 ] && [ "$CHANGED_ONLY" -eq 1 ]; then
  echo "run-test-suite.sh: --changed-only and --chunk are mutually exclusive" >&2
  echo "usage: run-test-suite.sh [--chunk k/n | --changed-only [--base <ref>]] [tests-dir]" >&2
  exit 2
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

# --changed-only (#1334): resolve the diff repo (git toplevel of TESTS_DIR)
# and the base ref, fail-OPEN to the full suite on any resolution failure.
co_fallback() {
  echo "CHANGED-ONLY: $1 — running the full suite" >&2
  CHANGED_ONLY=0
}
if [ "$CHANGED_ONLY" -eq 1 ]; then
  TESTS_DIR="$(cd "$TESTS_DIR" && pwd -P)"
  DIFF_REPO="$(git -C "$TESTS_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$DIFF_REPO" ]; then
    co_fallback "tests dir $TESTS_DIR is not inside a git repo"
  else
    if [ -z "$BASE_REF" ]; then
      [ -n "${PIPELINE_BASE_BRANCH:-}" ] || . "$REPO_ROOT/scripts/_resolve-config.sh"
      BASE_REF="origin/${PIPELINE_BASE_BRANCH:-main}"
    fi
    MERGE_BASE="$(git -C "$DIFF_REPO" merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
    [ -n "$MERGE_BASE" ] || co_fallback "base $BASE_REF unresolved"
  fi
fi

# Re-scrub (#1389): the --changed-only base resolution above sources
# _resolve-config.sh, which re-reads the consumer pipeline.config under `set -a`
# — re-EXPORTING that config's own PIPELINE_PROJECT_ROOT / PIPELINE_USE_LOCAL_PLUGIN
# into this process and back into every spawned test, defeating the scrub in the
# mode execute-issue-plan Step 6b uses by default. Idempotent no-op otherwise.
scrub_roots

# --changed-only selection: touched set (diff + untracked) -> needles (full
# path, unique basename, and every ancestor dir as a `<dir>/*` glob) ->
# selected corpus tests (touched themselves, or grep-matching a needle).
if [ "$CHANGED_ONLY" -eq 1 ]; then
  TOUCHED="$(mktemp)"; NEEDLES="$(mktemp)"; SEL_LIST="$(mktemp)"; FULL_LIST="$(mktemp)"; SEL_RELS="$(mktemp)"
  { git -C "$DIFF_REPO" diff --name-only "$MERGE_BASE"
    git -C "$DIFF_REPO" ls-files --others --exclude-standard; } | sort -u > "$TOUCHED"
  KNOWN="$(git -C "$DIFF_REPO" ls-files -co --exclude-standard)"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    base="${p##*/}"; printf '%s\n' "$p"
    if [ "$(printf '%s\n' "$KNOWN" | awk -F/ -v b="$base" '$NF==b' | wc -l)" -le 1 ]; then
      printf '%s\n' "$base"                 # unique basename -> the #1329 basename needle
    else
      case "$p" in */*) printf '%s\n' "${p#"${p%/*/*}/"}" ;; esac   # ambiguous basename -> parent/basename; root-level -> path only
    fi
    d="$p"; while [ "${d%/*}" != "$d" ]; do d="${d%/*}"; printf '%s/*\n' "$d"; done   # every ancestor dir as a glob
  done < "$TOUCHED" | sort -u > "$NEEDLES"
  find "$TESTS_DIR" -maxdepth 1 -type f \( -name 'test*.sh' -o -name 'test_*.sh' \) -print0 | sort -z > "$FULL_LIST"
  TOTAL="$(tr -cd '\0' < "$FULL_LIST" | wc -c | tr -d '[:space:]')"; TOUCHED_N="$(wc -l < "$TOUCHED" | tr -d '[:space:]')"; SELECTED=0; SCANNERS=0
  if [ "$TOUCHED_N" -gt 0 ]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$DIFF_REPO"/}"
      if grep -qxF -- "$rel" "$TOUCHED" || grep -qF -f "$NEEDLES" -- "$f"; then
        printf '%s\0' "$f" >> "$SEL_LIST"; printf '%s\n' "$rel" >> "$SEL_RELS"; SELECTED=$((SELECTED + 1))
        [ "${PIPELINE_TEST_VERBOSE:-0}" = 1 ] && echo "CHANGED-ONLY: selected $rel"
      fi
    done < "$FULL_LIST"

    # Always-run scanner class (#1339, backlog #65): a corpus test that globs
    # the tests dir itself (`"$TESTS_DIR"/test*.sh`, `tests/test*.sh`, …) is a
    # SUBJECT of every tests/-dir edit even though it names no single touched
    # path — select it too whenever the diff touches anything under tests/.
    TESTS_DIR_REL="${TESTS_DIR#"$DIFF_REPO"/}"
    TOUCHES_TESTS_DIR=0
    while IFS= read -r p; do
      case "$p" in
        tests/*|"$TESTS_DIR_REL"/*) TOUCHES_TESTS_DIR=1; break ;;
      esac
    done < "$TOUCHED"
    if [ "$TOUCHES_TESTS_DIR" -eq 1 ]; then
      while IFS= read -r -d '' f; do
        rel="${f#"$DIFF_REPO"/}"
        grep -qxF -- "$rel" "$SEL_RELS" && continue
        if grep -qF -e '"$TESTS_DIR"/test' -e '"$TESTS_DIR"/*' -e 'tests/test*' \
             -e 'tests/*.sh' -e 'tests/test-*' -e 'find "$TESTS_DIR"' -- "$f"; then
          printf '%s\0' "$f" >> "$SEL_LIST"; printf '%s\n' "$rel" >> "$SEL_RELS"
          SELECTED=$((SELECTED + 1)); SCANNERS=$((SCANNERS + 1))
          [ "${PIPELINE_TEST_VERBOSE:-0}" = 1 ] && echo "CHANGED-ONLY: selected $rel (scanner)"
        fi
      done < "$FULL_LIST"
    fi
  fi
  rm -f "$TOUCHED" "$NEEDLES" "$FULL_LIST" "$SEL_RELS"
fi

# Leak-guard repo (#1316): COLON-LESS expansion (precedent PIPELINE_CI_CHECK_ENABLED)
# — unset ⇒ the repo this runner lives in; a path ⇒ redirect; explicitly empty
# ⇒ guard OFF. Every guard step below is gated on `[ -n "$GUARD_REPO" ]` and the
# empty value never reaches the rev-parse probe (`git -C "" rev-parse` succeeds
# on the cwd repo, which would silently re-enable the guard). A non-repo path
# clears the guard rather than erroring.
GUARD_REPO="${PIPELINE_TEST_LEAK_GUARD_REPO-$REPO_ROOT}"
if [ -n "$GUARD_REPO" ]; then
  if ! git -C "$GUARD_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    GUARD_REPO=""
  fi
fi

# Sorted snapshot of a repo's worktree + local-branch surfaces:
#   W<TAB><path><TAB><branch>   one per `git worktree list --porcelain` entry
#                               (branch = refs/heads/ stripped, or "(detached)")
#   B<TAB><name>                one per local branch
# Paths are taken as everything after the `worktree ` prefix so spaces survive.
leak_snapshot() {
  local repo="$1"
  {
    git -C "$repo" worktree list --porcelain 2>/dev/null \
      | awk '
          index($0, "worktree ") == 1 { path = substr($0, 10); branch = "(detached)"; next }
          index($0, "branch ") == 1   { b = substr($0, 8); sub("^refs/heads/", "", b); branch = b; next }
          $0 == ""                    { if (path != "") printf "W\t%s\t%s\n", path, branch; path = "" }
          END                         { if (path != "") printf "W\t%s\t%s\n", path, branch }
        '
    git -C "$repo" branch --list --format='%(refname:short)' 2>/dev/null \
      | awk '{ printf "B\t%s\n", $0 }'
  } | LC_ALL=C sort
}

LEAK_BEFORE=""
if [ -n "$GUARD_REPO" ]; then
  LEAK_BEFORE="$(mktemp)"
  leak_snapshot "$GUARD_REPO" > "$LEAK_BEFORE"
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
elif [ "$CHANGED_ONLY" -eq 1 ]; then
  if [ -s "$SEL_LIST" ]; then
    xargs -0 -P "$PAR" -I{} bash -c 'run_one "$@"' _ {} < "$SEL_LIST"
  fi
  rm -f "$SEL_LIST"
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

# Post-suite leak guard (#1316): diff the guard repo's worktree/branch snapshot
# against the pre-run one. New W entries print one `LEAK:` line each and
# consume their branch; new B entries not consumed print with `worktree=-`.
# Any LEAK line reds the run. Nothing is printed on a clean run.
if [ -n "$GUARD_REPO" ] && [ -n "$LEAK_BEFORE" ]; then
  LEAK_AFTER="$(mktemp)"
  LEAK_REPORT="$(mktemp)"
  leak_snapshot "$GUARD_REPO" > "$LEAK_AFTER"
  LC_ALL=C comm -13 "$LEAK_BEFORE" "$LEAK_AFTER" \
    | awk -F'\t' '
        $1 == "W" { printf "LEAK: worktree=%s branch=%s\n", $2, $3; consumed[$3] = 1; next }
        $1 == "B" { pending[++np] = $2; next }
        END {
          for (i = 1; i <= np; i++) {
            if (!(pending[i] in consumed)) printf "LEAK: worktree=- branch=%s\n", pending[i]
          }
        }
      ' > "$LEAK_REPORT"
  if [ -s "$LEAK_REPORT" ]; then
    cat "$LEAK_REPORT"
    leak_n="$(wc -l < "$LEAK_REPORT" | tr -d '[:space:]')"
    leak_noun="entries"
    [ "$leak_n" -eq 1 ] && leak_noun="entry"
    echo "::error::leak guard: $leak_n new worktree/branch $leak_noun in $GUARD_REPO after the suite" >&2
    CHUNK_RESULT="fail"
  fi
  rm -f "$LEAK_BEFORE" "$LEAK_AFTER" "$LEAK_REPORT"
fi

if [ "$CHANGED_ONLY" -eq 1 ]; then
  echo "CHANGED-ONLY: touched=$TOUCHED_N selected=$SELECTED/$TOTAL scanners=$SCANNERS RESULT=$CHUNK_RESULT"
fi

if [ "$CHUNK_MODE" -eq 1 ]; then
  echo "CHUNK=$CHUNK_K/$CHUNK_N FILES=$FILE_COUNT RESULT=$CHUNK_RESULT"
fi

if [ "$CHUNK_RESULT" = "fail" ]; then
  exit 1
fi

exit 0
