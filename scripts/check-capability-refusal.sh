#!/usr/bin/env bash
# check-capability-refusal.sh — issue-scoped CAPABILITY-REFUSED: sentinel
# detector (#1233).
#
# #1225 landed the CAPABILITY-REFUSED: contract in agents/tdd-implementer.md
# as PROSE ONLY: a leaf that cannot perform a mandated plan task must fail
# LOUDLY. With no listener, an executor that silently substitutes still
# merges. This script is the mechanical listener.
#
# Usage: check-capability-refusal.sh <issue-N> [<source>...]
#   <issue-N>    issue number to scope the scan to; echoed back verbatim in
#                the ISSUE= field.
#   <source>...  zero or more file/dir paths to scan. Positional sources
#                ALWAYS win. Absent, falls back to
#                $PIPELINE_CAPABILITY_REFUSAL_SOURCES (space/newline
#                separated, shell glob-expanded). Neither given -> no-sources.
#                Deliberately NO cwd default — a caller must always supply a
#                source, so the gate never scans the operator's real
#                .claude/logs/subagents/ nondeterministically.
#
# Stdout (ALWAYS exactly one line, ALWAYS exit 0 — the verdict rides the
# token, same contract as scripts/split-role-gate.sh /
# scripts/auto-merge-gate.sh / scripts/verify-execute-completion.sh):
#
#   CAPABILITY_REFUSAL=<clear|block> ISSUE=<N> REASON=<token> SCANNED=<n> WITH_OUTPUT=<n>
#
# Zero args -> usage on stderr, exit 2.
#
# COUNTER CONTRACT — for each candidate file:
#   - a file is OPENED iff it is (i) an explicit file source, or (ii) a
#     -maxdepth-1 regular file inside a dir source whose decomposed slug (see
#     below) carries <issue-N> as a whole digit run. Anything else is never
#     opened: contributes 0 to BOTH counters.
#   - SCANNED increments exactly once for EVERY opened file, regardless of
#     parse outcome — a malformed .json IS an opened file.
#   - WITH_OUTPUT increments only when the opened file yielded NON-EMPTY leaf
#     text. A malformed .json yields no leaf text, so it is indistinguishable
#     in the counters from a record whose .result decodes empty — both mean
#     "this file proved nothing".
#
# TOKEN RULE — an ordered TOTAL FUNCTION of (HIT, SCANNED, WITH_OUTPUT). First
# matching arm wins:
#   1. HIT >= 1              -> block / leaf-refused
#   2. else SCANNED == 0     -> clear / no-sources      (nothing scannable)
#   3. else WITH_OUTPUT == 0 -> clear / no-leaf-output   (proved nothing)
#   4. else                  -> clear / no-refusal       (the only confident clean)
#
# SLUG DECOMPOSITION — filenames are written by hooks/log_subagent.py as
# "<file_ts>_<slug>_<agent_id_short>.json" where file_ts contains no `_`, slug
# (sanitize_slug) can never contain `_`, and agent_id_short is an 8-hex-char
# run or the literal "unknown". A dir source's entries are matched against
# <issue-N> via this exact, total 4-step decomposition of the basename:
#   1. base := filename minus a trailing .json
#   2. split base on `_` into fields f[1..n]. If n >= 2, DROP the LAST field
#      (the agent-id short). If n == 1, drop nothing.
#   3. If the FIRST remaining field matches the literal timestamp shape
#      %Y%m%d-%H%M%S-%f (8 digits, 6 digits, 6 digits, hyphen-separated),
#      DROP it. Otherwise keep it.
#   4. slug := the remaining fields joined with `-` (empty string if none
#      remain -> never matches).
# Both strips are load-bearing on real data: an unconditional "take field 2"
# false-positives on 2-field names with no timestamp; a no-strip reading
# false-positives on agent-id hex digit runs; skipping the timestamp strip
# false-positives on a 6-digit issue number colliding with a %H%M%S run.
#
# MATCH RULE (issue scoping): whole-digit-run match on the decomposed slug,
# via a PURE-SHELL matcher — no regex. `grep` on the dogfood host is
# `ugrep 7.5.0`, which NOMATCHes ERE anchored-alternation forms that GNU grep
# matches, so an issue-number boundary check built on that dialect would be
# host-dependent. Instead: collapse every non-digit character in the slug to
# `-`, then `case` for `-<N>-` as a substring. A digit run is therefore only
# a match when it is delimited on both sides — "1233" never matches inside
# "11233".
#
# SENTINEL MATCH RULE: a file's decoded leaf text is scanned line-by-line for
# a line that is (optional leading whitespace) + the sentinel, at the START
# of the line. Per-file scan source is `result` ONLY, never `prompt`
# (orchestrator dispatch text can legitimately quote the contract). For a
# *.json file: `jq -r '.result // empty'`; jq failing (malformed JSON) counts
# as an opened, unparsable file — there is NO raw-byte fallback (the leaf's
# whole return is stored as one JSON string with \n escapes, so a raw grep
# over the file bytes misses a sentinel that is not on physical line 1, and
# every observed \n-containing sentinel on the live tree lives in `.prompt`,
# never `.result` — a raw fallback here only re-introduces false positives).
# For a non-.json file: its raw contents ARE the leaf text.
#
# Self-reference safety: the sentinel is assembled at runtime from two
# fragments so this script's own source is never itself a scan false-positive
# (precedent: scripts/check-cross-cutting-guards.sh:121 FIXTURE_TOKEN).
#
# --resolve-sources [<start-dir>] (#1246) — additive mode, ALWAYS exit 0,
# EXACTLY ONE stdout line:
#
#   SOURCES=<resolved|no-log-dir|unresolvable-root> ROOT=<root-or-empty> DIR=<dir-or-empty>
#
# Resolves the subagent-log source dir against the MAIN checkout (worktree-
# aware), never $(pwd) of a linked worktree, which has no .claude/ of its own.
# <start-dir> defaults to $PWD. Root-resolution precedence (first usable wins):
#   1. $PIPELINE_PROJECT_ROOT when non-empty AND -d (#1215 operator override).
#      Non-empty-but-not-a-dir falls THROUGH to tier 2 (a stale override must
#      not re-dormant the gate).
#   2. `git -C <start-dir> rev-parse --git-common-dir`, normalized against
#      <start-dir> when relative, then its parent directory. --git-common-dir
#      resolves the MAIN checkout's .git even from a linked worktree, where
#      --show-toplevel would return the worktree itself (donor idiom:
#      scripts/capture-agent-costs.sh, scripts/_resolve-plugin-root.sh).
#   3. neither -> SOURCES=unresolvable-root (defensive; ROOT/DIR empty).
# Never resolves from $BASH_SOURCE — on a consumer install this script lives
# under ~/.claude/plugins/claude-pipeline/, which is NOT the project.
# DIR := <root>/.claude/logs/subagents; -d DIR -> resolved, else -> no-log-dir
# (ROOT stays populated, DIR empty) — the legitimate PIPELINE_LOGS_ENABLED=false
# consumer case, deliberately distinguishable from unresolvable-root.

set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <issue-N> [<source>...]" >&2
  exit 2
fi

if [ "$1" = "--resolve-sources" ]; then
  shift
  RS_START="${1:-$PWD}"
  RS_ROOT=""
  if [ -n "${PIPELINE_PROJECT_ROOT:-}" ] && [ -d "${PIPELINE_PROJECT_ROOT}" ]; then
    RS_ROOT="$PIPELINE_PROJECT_ROOT"
  else
    RS_COMMON="$(git -C "$RS_START" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$RS_COMMON" ]; then
      case "$RS_COMMON" in
        /*) : ;;
        *) RS_COMMON="$RS_START/$RS_COMMON" ;;
      esac
      RS_ROOT="$(cd "$RS_COMMON/.." 2>/dev/null && pwd -P || true)"
    fi
  fi
  if [ -z "$RS_ROOT" ]; then
    echo "SOURCES=unresolvable-root ROOT= DIR="
    exit 0
  fi
  RS_DIR="$RS_ROOT/.claude/logs/subagents"
  if [ -d "$RS_DIR" ]; then
    echo "SOURCES=resolved ROOT=${RS_ROOT} DIR=${RS_DIR}"
  else
    echo "SOURCES=no-log-dir ROOT=${RS_ROOT} DIR="
  fi
  exit 0
fi

ISSUE="$1"
shift

SENT="CAPABILITY-""REFUSED:"

SCANNED=0
WITH_OUTPUT=0
HIT=0

# slug_of <basename> — the 4-step decomposition documented above. Pure bash
# string/array ops, no regex.
slug_of() {
  local base="$1" n first f out=""
  base="${base%.json}"
  local -a fields
  IFS='_' read -r -a fields <<<"$base"
  n="${#fields[@]}"
  if [ "$n" -ge 2 ]; then
    fields=("${fields[@]:0:$((n - 1))}")
  fi
  first="${fields[0]:-}"
  case "$first" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
      fields=("${fields[@]:1}")
      ;;
  esac
  for f in "${fields[@]:-}"; do
    [ -z "$f" ] && continue
    if [ -z "$out" ]; then out="$f"; else out="$out-$f"; fi
  done
  printf '%s' "$out"
}

# matches_issue <slug> <issue-N> — whole-digit-run match; every non-digit
# character collapses to `-`, so a run is only a match when delimited on
# both sides.
matches_issue() {
  local slug="$1" n="$2" t
  t="$(printf '%s' "$slug" | tr -c '0-9' '-')"
  case "-$t-" in
    *-"$n"-*) return 0 ;;
    *) return 1 ;;
  esac
}

# process_file <path> — opens the file: increments SCANNED unconditionally,
# extracts leaf text per the per-file scan rule, increments WITH_OUTPUT on
# non-empty text, and sets HIT when the sentinel matches at a line start.
process_file() {
  local f="$1" text rc
  SCANNED=$((SCANNED + 1))
  case "$f" in
    *.json)
      text="$(jq -r '.result // empty' "$f" 2>/dev/null)"
      rc=$?
      [ "$rc" -eq 0 ] || text=""
      ;;
    *)
      text="$(cat "$f" 2>/dev/null)"
      ;;
  esac
  if [ -n "$text" ]; then
    WITH_OUTPUT=$((WITH_OUTPUT + 1))
    if printf '%s\n' "$text" | grep -qE "^[[:space:]]*${SENT}"; then
      HIT=$((HIT + 1))
    fi
  fi
}

# open_dir_source <dir> — -maxdepth-1 regular files whose decomposed slug
# carries <issue-N> as a whole digit run.
open_dir_source() {
  local dir="$1" f base slug
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    slug="$(slug_of "$base")"
    if matches_issue "$slug" "$ISSUE"; then
      process_file "$f"
    fi
  done
}

# --- three-tier source resolution: positional > env > no-sources ----------
SOURCES=()
if [ "$#" -gt 0 ]; then
  SOURCES=("$@")
elif [ -n "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}" ]; then
  # shellcheck disable=SC2206  # intentional word-splitting + glob expansion
  SOURCES=($PIPELINE_CAPABILITY_REFUSAL_SOURCES)
fi

for src in "${SOURCES[@]:-}"; do
  [ -n "$src" ] || continue
  if [ -d "$src" ]; then
    open_dir_source "$src"
  elif [ -f "$src" ]; then
    # An explicit file source is scanned unconditionally — the caller has
    # asserted relevance, and such a file may carry no issue number at all.
    process_file "$src"
  fi
  # else: does not exist — never opened, contributes 0 to both counters.
done

if [ "$HIT" -ge 1 ]; then
  VERDICT="block"
  REASON="leaf-refused"
elif [ "$SCANNED" -eq 0 ]; then
  VERDICT="clear"
  REASON="no-sources"
elif [ "$WITH_OUTPUT" -eq 0 ]; then
  VERDICT="clear"
  REASON="no-leaf-output"
else
  VERDICT="clear"
  REASON="no-refusal"
fi

echo "CAPABILITY_REFUSAL=${VERDICT} ISSUE=${ISSUE} REASON=${REASON} SCANNED=${SCANNED} WITH_OUTPUT=${WITH_OUTPUT}"
exit 0
