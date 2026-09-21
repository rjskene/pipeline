#!/usr/bin/env bash
# Unit guard for scripts/parse-shared-tests.sh (#1287).
#
# The Step 11.2b `**Shared tests (split-role):**` parser used to live as an awk
# one-liner inside a bash fence in skills/evaluate-issue-pr/SKILL.md. The
# harness rewrites `$0`/`$1`… when it loads a skill body, so that fence could
# never survive a load intact (cycle-1: `awk '{sub(/\r$/,"",1281)}'`). The awk
# moved VERBATIM into a script, which the harness never rewrites.
#
# Every case below is BYTE-EQUIVALENT to the behaviour of the awk being
# replaced — measured against a prototype built by lifting the SKILL.md:377
# program into a file. This file is the equivalence contract; changing an
# expectation here is a behaviour change, not a cleanup.
#
# Contract under test: stdin = plan body; stdout = one sanctioned shared-test
# path per line, in source order; exit 0 ALWAYS (fail-open — callers run under
# `set -euo pipefail`, and a parser that aborts would wedge a PR evaluation).
set -euo pipefail
cd "$(dirname "$0")/.."

# `ROOT="$(pwd)"` and NOT `"$(cd "$(dirname "$0")/.." && pwd)"`: the line above
# has already cd-ed, so a second relative `$0` dirname resolves one level too
# high. NO existence guard — a missing script must surface as the genuine
# interpreter failure (exit 127), not a hand-rolled message that hides it.
ROOT="$(pwd)"
PARSER="$ROOT/scripts/parse-shared-tests.sh"

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# expect <label> <want> <input line>...
expect() {
  local label="$1" want="$2"; shift 2
  local got
  got="$(printf '%s\n' "$@" | bash "$PARSER")"
  if [ "$got" = "$want" ]; then
    pass_msg "$label"
  else
    fail_msg "$label — want $(printf '%q' "$want"), got $(printf '%q' "$got")"
  fi
}

# expect_raw <label> <want> <raw stdin string>
expect_raw() {
  local label="$1" want="$2" input="$3" got
  got="$(printf '%s' "$input" | bash "$PARSER")"
  if [ "$got" = "$want" ]; then
    pass_msg "$label"
  else
    fail_msg "$label — want $(printf '%q' "$want"), got $(printf '%q' "$got")"
  fi
}

HDR='**Shared tests (split-role):**'

# (a) header-inline form (#1107).
expect "(a) header-inline path" "tests/test-foo.sh" "$HDR tests/test-foo.sh"

# (b) header-inline, backtick-quoted.
expect "(b) header-inline backtick-quoted" "tests/test-baz.sh" "$HDR \`tests/test-baz.sh\`"

# (c) following-bullet form.
expect "(c) following-bullet" "tests/test-bar.sh" "$HDR" "- tests/test-bar.sh"

# (d) following-bullet with a trailing ` — reason` (#1121): plans write shared-
#     test bullets in the same `path — one-line reason` convention as
#     **Files to change:**, and the gate matches EXACT paths.
expect "(d) following-bullet strips ' — reason'" "tests/test_widen_results_tsv.py" \
  "$HDR" "- tests/test_widen_results_tsv.py — index correction"

# (e) header-inline with a trailing ` — reason` (#1121).
expect "(e) header-inline strips ' — reason'" "tests/test_widen_results_tsv.py" \
  "$HDR tests/test_widen_results_tsv.py — index correction"

# (f) the `None` sentinel yields an EMPTY list, never the phantom path "None"
#     (#1178) — both forms.
expect "(f) header-inline None => empty" "" "$HDR None"
expect "(f) following-bullet None => empty" "" "$HDR" "- None"

# (g) the `n/a` sentinel, case- and trailing-period-insensitive.
expect "(g) header-inline n/a => empty" "" "$HDR n/a"
expect "(g) following-bullet N/A. => empty" "" "$HDR" "- N/A."

# (h) absent section => empty output (the caller fails closed on empty).
expect "(h) absent section => empty" "" "Some other plan content"

# (i) a blank line between a header-ONLY line and its own bullet list still
#     parses (#1263 eval fix). Dropping this yields an empty carve-out, which
#     fails closed into exactly the false `locked-test-modified` block.
expect "(i) blank line after a header-only line keeps the bullet" "tests/test-gap.sh" \
  "$HDR" "" "- tests/test-gap.sh" "" "**Estimated effort:** 1 hour"

# (j) a blank line DOES close a header-INLINE section, so an unrelated bullet
#     further down the same comment is never swept in.
expect "(j) blank line closes a header-inline section" "tests/test-inline.sh" \
  "$HDR tests/test-inline.sh" "" "- some unrelated bullet that must NOT be captured"

# (k) the armed bullet region closes on ANY non-bullet line (#1263): another
#     bold `**…:**` header, an ATX heading, or prose.
expect "(k) a bold **…:** header closes the region" "tests/test-a.sh" \
  "$HDR" "- tests/test-a.sh" "**RED/GREEN ledger:**" "- must-not-be-captured.sh"
expect "(k) an ATX heading closes the region" "tests/test-a.sh" \
  "$HDR" "- tests/test-a.sh" "" "## Notes" "- must-not-be-captured.sh"
expect "(k) prose closes the region" "tests/test-prose.sh" \
  "$HDR" "- tests/test-prose.sh" "Some unrelated prose paragraph." "- must-not-be-captured.sh"

# (l) CRLF fixture (#1263): a surviving trailing \r silently defeats the gate's
#     exact-path match, reintroducing a false block by a different vector.
expect_raw "(l) CRLF following-bullet has no trailing CR" "tests/test-crlf.sh" \
  "$(printf '%s\r\n%s\r\n' "$HDR" "- tests/test-crlf.sh")"
expect_raw "(l) CRLF header-inline has no trailing CR" "tests/test-crlf2.sh" \
  "$(printf '%s\r\n' "$HDR tests/test-crlf2.sh")"

# (m) multiple bullets => one path per line, in source order.
expect "(m) multiple bullets, one path per line in order" \
  "$(printf '%s\n%s\n%s' tests/test-one.sh tests/test-two.sh tests/test-three.sh)" \
  "$HDR" "- tests/test-one.sh" "- tests/test-two.sh" "- tests/test-three.sh"

# (n) FAIL-OPEN: exit 0 unconditionally. Asserted LAST and with an explicit
#     status capture — every case above relies on `set -e` aborting on a
#     non-zero status, which is why a missing script reds this file at 127.
for probe in "$HDR tests/test-foo.sh" "Some other plan content" ""; do
  rc=0
  printf '%s\n' "$probe" | bash "$PARSER" > /dev/null || rc=$?
  if [ "$rc" = "0" ]; then
    pass_msg "(n) fail-open: exit 0 on $(printf '%q' "$probe")"
  else
    fail_msg "(n) parser must exit 0 (fail-open) on $(printf '%q' "$probe"); got rc=$rc"
  fi
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
