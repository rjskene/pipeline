#!/usr/bin/env bash
#
# Acceptance check for calibration issue 08 (underspecified convention).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# The issue asks for `calibctl export` as CSV and says nothing about columns,
# header or quoting. The sandbox already answers all three in the "Output
# conventions" section of docs/usage.md (column order follows `list`, raw
# values, RFC 4180 quoting, header row always present). A plan that reads the
# codebase's conventions produces the exact bytes pinned below; one that
# invents its own format (no header, `#1`, extra columns, an unquoted comma)
# does not.
#
# Fails against the untouched template (there is no `export` command).
set -uo pipefail

SANDBOX="${1:-$PWD}"
cd "$SANDBOX" || { echo "no such sandbox: $SANDBOX" >&2; exit 9; }

FAILURES=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

calib() { bash bin/calibctl "$@"; }

# show_bytes <file> — one line, control characters visible, for FAIL messages.
show_bytes() { od -c "$1" | sed -n '1,6p' | tr -s ' ' | tr '\n' ' '; }

# --- an empty ledger exports exactly the header ---------------------------------

CALIB_HOME="$WORK/empty"
export CALIB_HOME
mkdir -p "$CALIB_HOME"
printf 'id,status,priority,title\n' > "$WORK/want-empty.csv"
calib export > "$WORK/got-empty.csv" 2>"$WORK/err-empty"
if cmp -s "$WORK/want-empty.csv" "$WORK/got-empty.csv"; then
  ok "an empty ledger exports exactly the header row"
else
  bad "an empty ledger should export exactly 'id,status,priority,title\\n', got: $(show_bytes "$WORK/got-empty.csv")"
fi

# --- a seeded ledger exports byte-for-byte in the documented convention ---------

CALIB_HOME="$WORK/seeded"
export CALIB_HOME
mkdir -p "$CALIB_HOME"
calib add "write the release notes" --priority high >/dev/null       # id 1
calib add 'say "hi", then leave' --priority low >/dev/null           # id 2: tests/helper.sh's t_add_quoted_task title
calib add "fix the flaky lock test" >/dev/null                       # id 3
calib complete 3 >/dev/null
calib add "prune stale branches" --priority low --tag chore,ops >/dev/null   # id 4

cat > "$WORK/want-seeded.csv" <<'CSV'
id,status,priority,title
1,open,high,write the release notes
2,open,low,"say ""hi"", then leave"
3,done,med,fix the flaky lock test
4,open,low,prune stale branches
CSV
calib export > "$WORK/got-seeded.csv" 2>"$WORK/err-seeded"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "export exits 0 on a non-empty ledger"
else
  bad "export should exit 0 on a non-empty ledger, got rc $rc: $(head -c 200 "$WORK/err-seeded")"
fi
if cmp -s "$WORK/want-seeded.csv" "$WORK/got-seeded.csv"; then
  ok "export output follows docs/usage.md's output conventions byte for byte"
else
  bad "export output does not follow docs/usage.md's output conventions; diff (want vs got): $(diff "$WORK/want-seeded.csv" "$WORK/got-seeded.csv" | tr '\n' ' ' | head -c 400)"
fi

# --- the feature is covered by the suite ----------------------------------------

if grep -lqE '(calib|calibctl|CALIBCTL\}?"?)[[:space:]]+export([^A-Za-z0-9_]|$)' tests/case-*.sh 2>/dev/null; then
  ok "a test case file covers export"
else
  bad "no tests/case-*.sh file covers export"
fi

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 08: PASS"
  exit 0
fi
echo "issue 08: FAIL ($FAILURES check(s))"
exit 1
