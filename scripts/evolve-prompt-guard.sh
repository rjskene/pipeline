#!/bin/bash
set -uo pipefail
#
# evolve-prompt-guard.sh — prompt-coaching guard (#1397).
#
# Cycles 15 and 16 both shipped Step-4 dispatch prompts that named the very
# identifiers the next cycle would grade on (`PIPELINE_LOGS_ENABLED=false`,
# `Path.joinpath`, `code review #<N>`), so the verdict measured the coaching,
# not the harness. This is the mechanical stop: a dispatch prompt may not
# name a pending-metric token.
#
# CLI: evolve-prompt-guard.sh <cycle-N> <prompt-file> [--tokens-file PATH] [--help]
#
# Tokens-file lines are `#<n> <token> <token> …` (field 1 is the issue ref);
# tokens shorter than 3 characters are SKIPPED (the floor lives in the
# script, not only in the Step-3 writer). Matching is fixed-string,
# case-INSENSITIVE (coaching often paraphrases casing). Every surviving hit
# prints `PROMPT-COACHED issue=<n> token=<token>` on stdout.
#
# Exit codes: 0 clean · 1 usage error (argv, missing prompt file) ·
#             2 PROMPT-COACHED (RESERVED for the coaching signal — a usage
#             error must never masquerade as a positive detection).
#
# Fail-open on an absent/empty tokens file (warn + exit 0) — a guard that
# aborts on a missing fixture would wedge the loop it is meant to protect.
# `--tokens-file` is a TEST-ONLY seam; the default is
# `${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/evolve-metric-tokens-<N>.txt`,
# the file Step 3 writes.

print_usage() {
  cat <<'USAGE'
Usage: evolve-prompt-guard.sh <cycle-N> <prompt-file> [--tokens-file PATH] [--help]

  evolve-prompt-guard.sh — prompt-coaching guard (#1397).

  Checks a Step-4 dispatch prompt against the pending metric tokens filed for
  the current evolve cycle so the grader measures the harness, not the
  coaching. Fixed-string, case-INSENSITIVE match; tokens under 3 characters
  are skipped. Prints one `PROMPT-COACHED issue=<n> token=<token>` line per
  hit; ALL hits are printed.

  <cycle-N>             Evolve cycle number — selects the default tokens file.
  <prompt-file>         The dispatch prompt to check.
  --tokens-file PATH    TEST-ONLY seam: read tokens from PATH instead of
                        .claude/scratch/evolve-metric-tokens-<N>.txt.
  --help                Print this banner and exit 0.

Exit codes: 0 clean · 1 usage error · 2 PROMPT-COACHED (reserved for a hit).
USAGE
}

TOKENS_FILE=""
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)         print_usage; exit 0 ;;
    --tokens-file)     TOKENS_FILE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --tokens-file=*)   TOKENS_FILE="${1#--tokens-file=}"; shift ;;
    *)                 ARGS+=("$1"); shift ;;
  esac
done

N="${ARGS[0]:-}"
PROMPT_FILE="${ARGS[1]:-}"

if [ -z "$N" ] || [ -z "$PROMPT_FILE" ]; then
  echo "Usage: evolve-prompt-guard.sh <cycle-N> <prompt-file> [--tokens-file PATH]" >&2
  exit 1
fi
if [ ! -f "$PROMPT_FILE" ]; then
  echo "evolve-prompt-guard: ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

TOKENS_FILE="${TOKENS_FILE:-${PIPELINE_PROJECT_ROOT:-$(pwd)}/.claude/scratch/evolve-metric-tokens-${N}.txt}"

if [ ! -s "$TOKENS_FILE" ]; then
  echo "evolve-prompt-guard: WARN: tokens file absent or empty: $TOKENS_FILE (fail-open)" >&2
  exit 0
fi

HIT=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -z "$line" ] && continue
  read -ra fields <<<"$line"
  issue="${fields[0]:-}"
  [ -z "$issue" ] && continue
  for tok in "${fields[@]:1}"; do
    [ "${#tok}" -lt 3 ] && continue
    if grep -Fqi -- "$tok" "$PROMPT_FILE"; then
      echo "PROMPT-COACHED issue=${issue} token=${tok}"
      HIT=1
    fi
  done
done < "$TOKENS_FILE"

[ "$HIT" -eq 1 ] && exit 2
exit 0
