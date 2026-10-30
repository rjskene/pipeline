#!/usr/bin/env bash
#
# Acceptance check for calibration issue 10 (a title filter on the web view).
#
#   bash reference-test.sh [sandbox-root]     # default: $PWD
#
# Renders web/index.html in a headless browser (--dump-dom runs the page's
# JavaScript) and checks the rows the filter shows. Exits 9 when no headless
# browser is on PATH. Fails against the untouched template (there is no
# #filter box) and passes once the filter is implemented as specified.
#
# A "shown" row is a <tbody> <tr> without a `hidden` attribute or a
# `display: none` style, so a filter that removes rows and one that hides them
# grade the same. The ?q= pre-fill of the box is NOT checked here: --dump-dom
# serializes the value attribute, not the property a script sets. The browser
# check in execute / evaluate proves the pre-fill and the live typing.
set -uo pipefail

SANDBOX="${1:-$PWD}"
cd "$SANDBOX" || { echo "no such sandbox: $SANDBOX" >&2; exit 9; }
SANDBOX="$(pwd)"

BROWSER=""
for b in google-chrome chromium chromium-browser; do
  if command -v "$b" >/dev/null 2>&1; then
    BROWSER="$b"
    break
  fi
done
if [ -z "$BROWSER" ]; then
  echo "issue 10: no headless browser (google-chrome, chromium, chromium-browser) on PATH"
  exit 9
fi

FAILURES=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

PAGE="file://$SANDBOX/web/index.html"

# dump_dom <url> — print the DOM after the page's JavaScript has run.
dump_dom() {
  timeout 60 "$BROWSER" --headless=new --disable-gpu --no-sandbox --dump-dom "$1" 2>/dev/null
}

# shown_rows <html> — one line per shown <tbody> row, the row's markup flattened.
shown_rows() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -n 's/.*<tbody[^>]*>\(.*\)<\/tbody>.*/\1/p' \
    | sed 's/<\/tr>/<\/tr>\n/g' | grep '<tr' \
    | while IFS= read -r row; do
        open="$(printf '%s' "$row" | sed 's/^[^<]*\(<tr[^>]*>\).*/\1/')"
        printf '%s' "$open" | grep -qE '[[:space:]]hidden([[:space:]=>]|$)' && continue
        printf '%s' "$open" | grep -qiE 'display:[[:space:]]*none' && continue
        printf '%s\n' "$row"
      done
}

# row_keys <rows> — per shown row: `empty` for <tr id="empty">, else its first cell.
row_keys() {
  printf '%s\n' "$1" | grep '<tr' | while IFS= read -r row; do
    if printf '%s' "$row" | grep -qE '^[^<]*<tr[^>]*[[:space:]]id="empty"'; then
      echo empty
    else
      printf '%s\n' "$row" | sed -n 's/^[^<]*<tr[^>]*>[^<]*<td[^>]*>\([^<]*\)<\/td>.*/\1/p' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
    fi
  done | tr '\n' ' ' | sed 's/ $//'
}

# count_text <html> — the text of the id="count" element.
count_text() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -n 's/.*id="count"[^>]*>\([^<]*\)<.*/\1/p' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# --- ?q=release: the matching rows only, case-insensitive --------------------

html="$(dump_dom "$PAGE?q=release")"
rows="$(shown_rows "$html")"
keys="$(row_keys "$rows")"
if [ "$keys" = "1 2 6" ]; then
  ok "?q=release shows exactly tasks 1, 2 and 6 (6 via case-insensitivity)"
else
  bad "?q=release should show tasks '1 2 6', got '$keys'"
fi
count="$(count_text "$html")"
if [ "$count" = "3 of 6 tasks" ]; then
  ok "?q=release counts '3 of 6 tasks'"
else
  bad "?q=release #count should read '3 of 6 tasks', got '$count'"
fi

# --- ?q=zzz: the single empty row -----------------------------------------------

html="$(dump_dom "$PAGE?q=zzz")"
rows="$(shown_rows "$html")"
keys="$(row_keys "$rows")"
if [ "$keys" = "empty" ] && printf '%s' "$rows" | grep -q 'no matching tasks'; then
  ok "?q=zzz shows only <tr id=\"empty\"> reading 'no matching tasks'"
else
  bad "?q=zzz should show only the empty row with 'no matching tasks', got '$keys'"
fi
count="$(count_text "$html")"
if [ "$count" = "0 of 6 tasks" ]; then
  ok "?q=zzz counts '0 of 6 tasks'"
else
  bad "?q=zzz #count should read '0 of 6 tasks', got '$count'"
fi

# --- no ?q: every task, and the filter box --------------------------------------

html="$(dump_dom "$PAGE")"
rows="$(shown_rows "$html")"
keys="$(row_keys "$rows")"
if [ "$keys" = "1 2 3 4 5 6" ]; then
  ok "no ?q shows all six tasks in id order"
else
  bad "no ?q should show tasks '1 2 3 4 5 6', got '$keys'"
fi
if printf '%s' "$html" | grep -qE '<input[^>]*id="filter"'; then
  ok "the page has the #filter box"
else
  bad "the page has no <input id=\"filter\">"
fi
count="$(count_text "$html")"
if [ "$count" = "6 of 6 tasks" ]; then
  ok "no ?q counts '6 of 6 tasks'"
else
  bad "no ?q #count should read '6 of 6 tasks', got '$count'"
fi

# --- the suite stays green ------------------------------------------------------

if bash tests/run.sh >/dev/null 2>&1; then
  ok "the test suite is green"
else
  bad "the test suite is not green"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "issue 10: PASS"
  exit 0
fi
echo "issue 10: FAIL ($FAILURES check(s))"
exit 1
