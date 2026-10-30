#!/usr/bin/env bash
# case-web.sh — the static ledger view in web/ (rendered by a headless browser).
. "$(dirname "$0")/helper.sh"

BROWSER=""
for b in google-chrome chromium chromium-browser; do
  if command -v "$b" >/dev/null 2>&1; then
    BROWSER="$b"
    break
  fi
done
if [ -z "$BROWSER" ]; then
  echo "SKIP case-web (no headless browser)"
  exit 0
fi

t_setup

# dump_dom <url> — print the DOM after the page's JavaScript has run.
dump_dom() {
  timeout 60 "$BROWSER" --headless=new --disable-gpu --no-sandbox --dump-dom "$1" 2>/dev/null
}

# tbody_rows <html> — one line per <tbody> row, the row's markup flattened.
tbody_rows() {
  printf '%s' "$1" | tr -d '\n' \
    | sed -n 's/.*<tbody[^>]*>\(.*\)<\/tbody>.*/\1/p' \
    | sed 's/<\/tr>/<\/tr>\n/g' | grep '<tr'
}

# row_cells <row markup> — the row's cell texts, separated by '/'.
row_cells() {
  printf '%s' "$1" | sed -e 's/<\/td>/\//g' -e 's/<[^>]*>//g' -e 's/\/$//'
}

html="$(dump_dom "file://$PROJECT_ROOT/web/index.html")"; rc=$?
assert_rc 0 "$rc" "the browser renders web/index.html"
assert_contains "$html" "<title>calibctl ledger</title>" "the page is titled calibctl ledger"

rows="$(tbody_rows "$html")"
assert_eq "6" "$(printf '%s\n' "$rows" | grep -c '<tr')" "the table shows one row per fixture task"
assert_eq "1/open/high/write the release notes" "$(row_cells "$(printf '%s\n' "$rows" | head -1)")" \
  "the first row is task 1 in the list column order"

t_report
