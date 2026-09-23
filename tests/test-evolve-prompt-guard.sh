#!/usr/bin/env bash
# Unit guard for scripts/evolve-prompt-guard.sh (#1397).
#
# One session ranks the backlog, writes each issue's `Metric · expected delta`
# line (Step 3) AND authors the Step-4 dispatch prompts. Cycles 15 and 16 both
# shipped prompts that named the very identifiers the next cycle would grade on
# (`PIPELINE_LOGS_ENABLED=false`, `Path.joinpath`, `code review #<N>`), so the
# verdict measured the coaching, not the harness. This guard is the mechanical
# stop: a dispatch prompt may not name a pending-metric token.
#
# Contract under test:
#   evolve-prompt-guard.sh <N> <prompt-file> [--tokens-file PATH] [--help]
#   * tokens-file lines are `#<n> <token> <token> …`; field 1 is the issue ref,
#     the rest are tokens.
#   * tokens shorter than 3 characters are SKIPPED — the floor lives in the
#     SCRIPT, not only in the Step-3 writer, so a hand-edited tokens file
#     cannot smuggle a 1-char token in.
#   * every surviving token found in the prompt (fixed-string, case-
#     INSENSITIVE) prints `PROMPT-COACHED issue=#<n> token=<token>` on stdout;
#     ALL hits are printed.
#   * exit 2 when there was at least one hit, else exit 0 with EMPTY stdout.
#   * fail-OPEN on an absent/empty tokens file: warn on stderr, exit 0. A guard
#     that aborts on a missing fixture wedges the loop it is meant to protect.
#   * fail-LOUD on argv: usage on stderr, exit 1. Exit 2 is RESERVED for the
#     coached signal, which is why every usage case also asserts rc != 2 — a
#     parser bug must never masquerade as a positive detection.
#
# `--tokens-file` is a TEST-ONLY seam. Every case writes its own tokens file
# and prompt file under `mktemp -d`, so nothing here reads or writes the real
# clone's `.claude/scratch/`, and nothing touches the network.
set -uo pipefail
cd "$(dirname "$0")/.."

# The `cd` above already moved us. NO existence guard on the script: a missing
# script must surface as the genuine interpreter failure (inner rc 127).
ROOT="$(pwd)"
SCRIPT="$ROOT/scripts/evolve-prompt-guard.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
case_hdr() { echo ""; echo "-- $1 --"; }

ERRFILE="$TMP/stderr.txt"
RC=0; OUT=""; ERR=""
# guard <args...> — run the script, capturing stdout, stderr and rc separately.
guard() {
  : > "$ERRFILE"
  OUT="$(bash "$SCRIPT" "$@" 2>"$ERRFILE")"
  RC=$?
  ERR="$(cat "$ERRFILE" 2>/dev/null)"
}

expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1 (rc=$2)"; else fail_msg "$1 (want rc=$2, got rc=$RC)"; fi
}
refute_rc() { # <label> <forbidden>
  if [ "$RC" -eq "$2" ]; then fail_msg "$1 (rc is $2)"; else pass_msg "$1 (rc=$RC != $2)"; fi
}
expect_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3 | got: ${2:-<empty>})"; fi
}
refute_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail_msg "$1 (unexpectedly present: $3)"; else pass_msg "$1"; fi
}
expect_empty() { # <label> <text>
  if [ -z "$2" ]; then pass_msg "$1"; else fail_msg "$1 (expected empty, got: $2)"; fi
}
expect_nonempty() { # <label> <text>
  if [ -n "$2" ]; then pass_msg "$1"; else fail_msg "$1 (expected non-empty, got nothing)"; fi
}
count_sub() { # <fixed-substring> <text>
  local n
  n="$(printf '%s\n' "$2" | grep -cF -- "$1" 2>/dev/null)" || true
  printf '%s' "${n:-0}"
}
expect_eq() { # <label> <actual> <want>
  if [ "${2:-}" = "$3" ]; then pass_msg "$1 ($3)"; else fail_msg "$1 (want $3, got ${2:-<empty>})"; fi
}

# --- fixtures --------------------------------------------------------------
printf '#1397 PIPELINE_LOGS_ENABLED\n' > "$TMP/tokens-one.txt"
printf 'Run the suite with PIPELINE_LOGS_ENABLED=false so the hooks stay quiet.\n' > "$TMP/prompt-coached.txt"
printf 'Add the missing scenario to tests/test-evolve-loop.sh, then open a PR.\n' > "$TMP/prompt-clean.txt"

# --- (1) a coached prompt is rejected with the reserved exit code -----------
case_hdr "(1) coached: the prompt names a pending-metric token"
guard 18 "$TMP/prompt-coached.txt" --tokens-file "$TMP/tokens-one.txt"
expect_rc "(1) a coached prompt exits 2" 2
expect_sub "(1) the hit names the issue and the token" "$OUT" \
  "PROMPT-COACHED issue=#1397 token=PIPELINE_LOGS_ENABLED"

# --- (2) an uncoached prompt is silent -------------------------------------
case_hdr "(2) uncoached: the prompt names no pending-metric token"
guard 18 "$TMP/prompt-clean.txt" --tokens-file "$TMP/tokens-one.txt"
expect_rc "(2) an uncoached prompt exits 0" 0
expect_empty "(2) an uncoached prompt prints NOTHING on stdout" "$OUT"

# --- (3) the < 3-char skip is TOKEN-scoped, not LINE-scoped ----------------
case_hdr "(3) short token: tokens under 3 characters are skipped"
printf '#1397 is a PIPELINE_LOGS_ENABLED\n' > "$TMP/tokens-short.txt"
printf 'This is a prompt that names no metric identifier at all.\n' > "$TMP/prompt-short.txt"
guard 18 "$TMP/prompt-short.txt" --tokens-file "$TMP/tokens-short.txt"
expect_rc "(3) the 1- and 2-char tokens never fire" 0
expect_empty "(3) a short-token-only match prints nothing" "$OUT"
# Non-vacuity control on the SAME tokens file: the long token on that line must
# still fire, which is what proves the skip dropped TOKENS, not the whole LINE.
printf 'This is a prompt that sets PIPELINE_LOGS_ENABLED explicitly.\n' > "$TMP/prompt-short-hit.txt"
guard 18 "$TMP/prompt-short-hit.txt" --tokens-file "$TMP/tokens-short.txt"
expect_rc "(3) the long token on the same line still fires" 2
expect_sub "(3) the surviving token is reported" "$OUT" \
  "PROMPT-COACHED issue=#1397 token=PIPELINE_LOGS_ENABLED"
refute_sub "(3) the 2-char token is never reported" "$OUT" "token=is"
refute_sub "(3) the 1-char token is never reported" "$OUT" "token=a"

# --- (4) matching is case-INSENSITIVE (coaching paraphrases casing) --------
case_hdr "(4) case-insensitive: a re-cased token still counts as coaching"
printf '#1397 Path.joinpath\n' > "$TMP/tokens-case.txt"
printf 'Prefer path.joinpath over the / operator in that helper.\n' > "$TMP/prompt-case.txt"
guard 18 "$TMP/prompt-case.txt" --tokens-file "$TMP/tokens-case.txt"
expect_rc "(4) a re-cased token exits 2" 2
expect_sub "(4) the token is reported as WRITTEN in the tokens file" "$OUT" \
  "PROMPT-COACHED issue=#1397 token=Path.joinpath"

# --- (5) ALL hits are printed, one line per issue ---------------------------
case_hdr "(5) multi-issue: every coached issue gets its own line"
{ printf '#1397 PIPELINE_LOGS_ENABLED\n'; printf '#1398 joinpath\n'; } > "$TMP/tokens-multi.txt"
printf 'Set PIPELINE_LOGS_ENABLED=false, then swap the joinpath call out.\n' > "$TMP/prompt-multi.txt"
guard 18 "$TMP/prompt-multi.txt" --tokens-file "$TMP/tokens-multi.txt"
expect_rc "(5) two coached issues still exit 2" 2
expect_eq "(5) exactly two PROMPT-COACHED lines" "$(count_sub 'PROMPT-COACHED' "$OUT")" 2
expect_sub "(5) the first issue is reported" "$OUT" "PROMPT-COACHED issue=#1397 token=PIPELINE_LOGS_ENABLED"
expect_sub "(5) the second issue is reported" "$OUT" "PROMPT-COACHED issue=#1398 token=joinpath"

# --- (6) FAIL-OPEN on a missing tokens file ---------------------------------
case_hdr "(6) missing tokens file: warn and fail open"
guard 18 "$TMP/prompt-coached.txt" --tokens-file "$TMP/does-not-exist.txt"
expect_rc "(6) an absent tokens file exits 0 (fail-open)" 0
expect_empty "(6) an absent tokens file prints nothing on stdout" "$OUT"
expect_nonempty "(6) an absent tokens file warns on stderr" "$ERR"

# --- (7) FAIL-LOUD on argv, and NEVER with the reserved code ---------------
case_hdr "(7) usage error: missing args exit 1, never 2"
guard
expect_rc "(7) no args is a usage error" 1
refute_rc "(7) a usage error is never read as a coaching hit" 2
expect_nonempty "(7) the usage banner goes to stderr" "$ERR"
# Same contract for a prompt-file that does not exist: the guard cannot vouch
# for a prompt it never read, so this is loud, not open.
guard 18 "$TMP/no-such-prompt.txt" --tokens-file "$TMP/tokens-one.txt"
expect_rc "(7) an unreadable prompt file is a usage error" 1
refute_rc "(7) an unreadable prompt file is never read as a coaching hit" 2

# --- (8) --help is a documented, zero-cost banner ---------------------------
case_hdr "(8) --help: rc 0 and a banner that names the signal"
guard --help
expect_rc "(8) --help exits 0" 0
expect_sub "(8) the banner names the PROMPT-COACHED signal" "$OUT" "PROMPT-COACHED"

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
