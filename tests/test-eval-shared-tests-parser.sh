#!/usr/bin/env bash
# Regression guard for issue #1107: the Step 11.2b shared-tests awk parser must
# capture BOTH the header-inline form ("**Shared tests (split-role):** path")
# AND the following-bullet form ("**Shared tests (split-role):**\n- path").
set -euo pipefail
cd "$(dirname "$0")/.."

SKILL="skills/evaluate-issue-pr/SKILL.md"
[ -f "$SKILL" ] || { echo "missing $SKILL"; exit 1; }

# Extract the awk one-liner from the SKILL.md source so we test the real parser.
AWK_PROG=$(grep -oP "awk '\K[^']+(?=')" "$SKILL" | grep 'Shared tests' | head -1)
[ -n "$AWK_PROG" ] || { echo "FAIL: could not extract Shared-tests awk program from $SKILL"; exit 1; }

# (a) header-inline form: path on the same line as the header.
result_a=$(printf '%s\n' "**Shared tests (split-role):** tests/test-foo.sh" \
  | awk "$AWK_PROG")
if [ "$result_a" != "tests/test-foo.sh" ]; then
  echo "FAIL(a): header-inline shared-test path not extracted; got: '$result_a'"
  exit 1
fi

# (b) following-bullet form: path on a subsequent line (regression guard for existing behaviour).
result_b=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test-bar.sh" \
  | awk "$AWK_PROG")
if [ "$result_b" != "tests/test-bar.sh" ]; then
  echo "FAIL(b): following-bullet shared-test path not extracted; got: '$result_b'"
  exit 1
fi

# (c) header-inline with backtick quoting: **Shared tests (split-role):** \`tests/test-baz.sh\`
result_c=$(printf '%s\n' "**Shared tests (split-role):** \`tests/test-baz.sh\`" \
  | awk "$AWK_PROG")
if [ "$result_c" != "tests/test-baz.sh" ]; then
  echo "FAIL(c): header-inline backtick-quoted path not extracted; got: '$result_c'"
  exit 1
fi

# (d) absent section => empty output (fail-closed unchanged).
result_d=$(printf '%s\n' "Some other plan content" | awk "$AWK_PROG")
if [ -n "$result_d" ]; then
  echo "FAIL(d): absent section should yield empty output; got: '$result_d'"
  exit 1
fi

# (e) SKILL.md documents the header-inline form as supported (#1107 fix).
grep -q "header-inline" "$SKILL" \
  || { echo "FAIL(e): $SKILL missing header-inline documentation"; exit 1; }

# (f) following-bullet with a trailing reason: "- path — reason" => bare path (#1121).
# Plans write shared-test bullets in the same `path — one-line reason` convention
# as **Files to change:**. The parser must strip the trailing ` — reason` so the
# gate's exact-path match fires. Current code captures the whole "path — reason".
result_f=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- tests/test_widen_results_tsv.py — index correction" \
  | awk "$AWK_PROG")
if [ "$result_f" != "tests/test_widen_results_tsv.py" ]; then
  echo "FAIL(f): trailing-reason following-bullet not stripped; got: '$result_f'"
  exit 1
fi

# (g) header-inline with a trailing reason => bare path (#1121).
result_g=$(printf '%s\n' "**Shared tests (split-role):** tests/test_widen_results_tsv.py — index correction" \
  | awk "$AWK_PROG")
if [ "$result_g" != "tests/test_widen_results_tsv.py" ]; then
  echo "FAIL(g): trailing-reason header-inline not stripped; got: '$result_g'"
  exit 1
fi

# (h) header-inline empty-section sentinel `None` => empty output (#1178).
# A plan whose Shared-tests section is written as the literal `None` sentinel
# must yield an EMPTY allow-list, not the phantom path "None".
result_h=$(printf '%s\n' "**Shared tests (split-role):** None" | awk "$AWK_PROG")
if [ -n "$result_h" ]; then
  echo "FAIL(h): header-inline None sentinel should yield empty; got: '$result_h'"
  exit 1
fi

# (i) following-bullet empty-section sentinel `- None` => empty output (#1178).
result_i=$(printf '%s\n' \
  "**Shared tests (split-role):**" \
  "- None" \
  | awk "$AWK_PROG")
if [ -n "$result_i" ]; then
  echo "FAIL(i): following-bullet None sentinel should yield empty; got: '$result_i'"
  exit 1
fi

echo "ok"
