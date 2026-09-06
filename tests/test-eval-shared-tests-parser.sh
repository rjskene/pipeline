#!/usr/bin/env bash
# Regression guard for issue #1107: the Step 11.2b shared-tests awk parser must
# capture BOTH the header-inline form ("**Shared tests (split-role):** path")
# AND the following-bullet form ("**Shared tests (split-role):**\n- path").
set -euo pipefail
cd "$(dirname "$0")/.."

# The real parser now lives in scripts/parse-shared-tests.sh (#1287): it was
# lifted out of the Step 11.2b bash fence, where the harness rewrites `$0`/`$1`
# at skill load. This file therefore drives the script directly instead of
# grep-extracting an awk program out of SKILL.md.
#
# `ROOT="$(pwd)"` and NOT `"$(cd "$(dirname "$0")/.." && pwd)"`: line 6 has
# already cd-ed to the repo root, so a second relative `$0` dirname would
# resolve one level too high. Same idiom as
# tests/test-eval-shared-tests-carveout-selector.sh:23-24.
#
# NO existence guard on purpose — a missing script must surface as the genuine
# interpreter failure, not as a hand-rolled message that hides it.
ROOT="$(pwd)"
PARSER="$ROOT/scripts/parse-shared-tests.sh"

# (a) header-inline form: path on the same line as the header.
result_a=$(printf '%s\n' "**Shared tests (split-role):** tests/test-foo.sh" \
  | bash "$PARSER")
if [ "$result_a" != "tests/test-foo.sh" ]; then
  echo "FAIL(a): header-inline shared-test path not extracted; got: '$result_a'"
  exit 1
fi

# (b) following-bullet form: path on a subsequent line (regression guard for existing behaviour).
result_b=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test-bar.sh" \
  | bash "$PARSER")
if [ "$result_b" != "tests/test-bar.sh" ]; then
  echo "FAIL(b): following-bullet shared-test path not extracted; got: '$result_b'"
  exit 1
fi

# (c) header-inline with backtick quoting: **Shared tests (split-role):** \`tests/test-baz.sh\`
result_c=$(printf '%s\n' "**Shared tests (split-role):** \`tests/test-baz.sh\`" \
  | bash "$PARSER")
if [ "$result_c" != "tests/test-baz.sh" ]; then
  echo "FAIL(c): header-inline backtick-quoted path not extracted; got: '$result_c'"
  exit 1
fi

# (d) absent section => empty output (fail-closed unchanged).
result_d=$(printf '%s\n' "Some other plan content" | bash "$PARSER")
if [ -n "$result_d" ]; then
  echo "FAIL(d): absent section should yield empty output; got: '$result_d'"
  exit 1
fi

# (e) the parser documents the header-inline form as supported (#1107 fix).
# The contract moved with the code: it is the script header that must carry it
# now, not skills/evaluate-issue-pr/SKILL.md (#1287).
grep -q "header-inline" "$PARSER" \
  || { echo "FAIL(e): $PARSER missing header-inline documentation"; exit 1; }

# (f) following-bullet with a trailing reason: "- path — reason" => bare path (#1121).
# Plans write shared-test bullets in the same `path — one-line reason` convention
# as **Files to change:**. The parser must strip the trailing ` — reason` so the
# gate's exact-path match fires. Current code captures the whole "path — reason".
result_f=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test_widen_results_tsv.py — index correction" \
  | bash "$PARSER")
if [ "$result_f" != "tests/test_widen_results_tsv.py" ]; then
  echo "FAIL(f): trailing-reason following-bullet not stripped; got: '$result_f'"
  exit 1
fi

# (g) header-inline with a trailing reason => bare path (#1121).
result_g=$(printf '%s\n' "**Shared tests (split-role):** tests/test_widen_results_tsv.py — index correction" \
  | bash "$PARSER")
if [ "$result_g" != "tests/test_widen_results_tsv.py" ]; then
  echo "FAIL(g): trailing-reason header-inline not stripped; got: '$result_g'"
  exit 1
fi

# (h) header-inline empty-section sentinel `None` => empty output (#1178).
# A plan whose Shared-tests section is written as the literal `None` sentinel
# must yield an EMPTY allow-list, not the phantom path "None".
result_h=$(printf '%s\n' "**Shared tests (split-role):** None" | bash "$PARSER")
if [ -n "$result_h" ]; then
  echo "FAIL(h): header-inline None sentinel should yield empty; got: '$result_h'"
  exit 1
fi

# (i) following-bullet empty-section sentinel `- None` => empty output (#1178).
result_i=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- None" \
  | bash "$PARSER")
if [ -n "$result_i" ]; then
  echo "FAIL(i): following-bullet None sentinel should yield empty; got: '$result_i'"
  exit 1
fi

# (j) CRLF fragility (#1263): a CRLF-terminated following-bullet path must not
# retain a trailing \r byte -- a surviving \r silently defeats the gate's exact
# -path match, reintroducing a false-block by a different vector than #1263's
# selector defect. Also, a CRLF-terminated header-only line (no inline path)
# must not spuriously emit a \r-only garbage "path".
result_j=$(printf '%s\r\n%s\r\n' \
  "**Shared tests (split-role):**" \
  "- tests/test-crlf.sh" \
  | bash "$PARSER")
expected_j=$'tests/test-crlf.sh'
if [ "$result_j" != "$expected_j" ]; then
  echo "FAIL(j): CRLF-terminated bullet path not cleaned; got: $(printf '%s' "$result_j" | cat -A)"
  exit 1
fi

# (k) unbounded armed-bullet region (#1263): the region must close on a blank
# line or an ATX heading, not ONLY on another bold "**...:**" header -- else an
# unrelated bullet later in the same comment (after the shared-tests section)
# is swept in as a bogus shared-test path.
result_k=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test-bar.sh" \
  "" \
  "## Notes" \
  "- some unrelated bullet that must NOT be captured" \
  | bash "$PARSER")
if [ "$result_k" != "tests/test-bar.sh" ]; then
  echo "FAIL(k): armed bullet region not bounded by blank line/heading; got:"
  printf '%s\n' "$result_k" | sed 's/^/    /'
  exit 1
fi

# (l) blank line between a header-ONLY line and its own bullet list (#1263
# eval fix): bounding the armed region must NOT narrow the previously-supported
# `**Shared tests (split-role):**\n\n- path` markdown shape. Dropping it yields
# an EMPTY carve-out, which fails closed into exactly the false
# `SPLIT_ROLE=block REASON=locked-test-modified` this issue exists to remove.
result_l=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "" \
  "- tests/test-gap.sh" \
  "" \
  "**Estimated effort:** 1 hour" \
  | bash "$PARSER")
if [ "$result_l" != "tests/test-gap.sh" ]; then
  echo "FAIL(l): blank line after a header-only line dropped the bullet; got: '$result_l'"
  exit 1
fi

# (m) header-INLINE sections stay bounded at the first blank line: an unrelated
# bullet further down the same comment must NOT be swept in (the region-bound
# protection must survive case (l)'s relaxation).
result_m=$(printf '%s\n' \
  "**Shared tests (split-role):** tests/test-inline.sh" \
  "" \
  "- some unrelated bullet that must NOT be captured" \
  | bash "$PARSER")
if [ "$result_m" != "tests/test-inline.sh" ]; then
  echo "FAIL(m): header-inline region not bounded at the first blank line; got:"
  printf '%s\n' "$result_m" | sed 's/^/    /'
  exit 1
fi

# (n) prose closes the armed region too (not only headings/bold headers).
result_n=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test-prose.sh" \
  "Some unrelated prose paragraph." \
  "- another unrelated bullet" \
  | bash "$PARSER")
if [ "$result_n" != "tests/test-prose.sh" ]; then
  echo "FAIL(n): prose did not close the armed bullet region; got:"
  printf '%s\n' "$result_n" | sed 's/^/    /'
  exit 1
fi

echo "ok"
