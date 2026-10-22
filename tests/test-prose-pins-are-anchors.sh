#!/usr/bin/env bash
set -euo pipefail

# Prose-pins lint (issue #1562): tests pin TOKENS and HEADINGS in skill prose
# (knob names, script names, LOOP:/GATE:/DISPATCH contract lines, step
# headings), never sentences. A sentence pin breaks on every rewording.
#
# Heuristic, per non-comment line of tests/test-*.sh:
#   - the first quoted pattern after each `grep` (option tokens skipped);
#   - the input is prose: the line (or the previous line, when it ends in `|`
#     or `\`) names SKILL.md, references/, agents/, or a $*_BODY / _SKILL /
#     _MD / _DOC / _PROSE variable;
#   - the pattern holds a run of 5+ words.
# Each offender must match an entry in the allow-list, which only shrinks:
# an entry matching no offender fails as STALE. See docs/operational-notes.md
# section 16.
#
# Overrides (fixture test): PROSE_PINS_DIR, PROSE_PINS_ALLOW.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${PROSE_PINS_DIR:-$SCRIPT_DIR}"
ALLOW="${PROSE_PINS_ALLOW:-$SCRIPT_DIR/prose-pins.allow}"
[ -f "$ALLOW" ] || ALLOW=/dev/null

files=()
for f in "$DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    test-cage-invariant-*.sh|test-prose-pins-*.sh) continue ;;
  esac
  files+=("$f")
done

read -r -d '' PROG <<'AWK' || true
function is_prose(s) {
  return s ~ /SKILL\.md|references\/|agents\/|[$][{]?[A-Za-z0-9_]*_(BODY|SKILL|MD|DOC|PROSE)([^A-Za-z0-9_]|$)/
}
# First quoted token after the grep options in s, or "" when none.
function grep_pattern(s,    q, i, n, c, pat) {
  while (1) {
    sub(/^[[:space:]]+/, "", s)
    if (match(s, /^(--|-[A-Za-z]+)([[:space:]]|$)/)) { s = substr(s, RLENGTH + 1); continue }
    break
  }
  q = substr(s, 1, 1)
  if (q == "'") {
    s = substr(s, 2); i = index(s, "'")
    return i ? substr(s, 1, i - 1) : s
  }
  if (q != "\"") return ""
  pat = ""; n = length(s)
  for (i = 2; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\" && i < n) { pat = pat substr(s, i + 1, 1); i++; continue }
    if (c == "\"") break
    pat = pat c
  }
  return pat
}
BEGIN {
  W = "[A-Za-z`*-]+"
  RUN = W " " W " " W " " W " " W
  ne = 0; no = 0; bad = 0; in_block = 0
}
FILENAME == allowfile {
  line = $0; sub(/[[:space:]]+$/, "", line)
  if (line == "") { in_block = 0; next }
  if (line ~ /^[[:space:]]*#/) { in_block = 1; next }
  if (!in_block) { print "UNJUSTIFIED: " allowfile ":" FNR ": " line " (entry block needs a # justification line first)"; bad = 1 }
  in_block = 1
  i = index(line, ":")
  ne++; e_raw[ne] = line; e_ln[ne] = FNR
  e_path[ne] = i ? substr(line, 1, i - 1) : line
  e_pre[ne] = i ? substr(line, i + 1) : ""
  next
}
FNR == 1 { prev = ""; k = split(FILENAME, parts, "/"); rel = "tests/" parts[k] }
{
  line = $0
  if (line !~ /^[[:space:]]*#/) {
    prose = is_prose(line) || (prev ~ /[|\\][[:space:]]*$/ && is_prose(prev))
    rest = line
    while (prose && match(rest, /(^|[^A-Za-z0-9_-])grep[[:space:]]/)) {
      rest = substr(rest, RSTART + RLENGTH)
      pat = grep_pattern(rest)
      if (pat != "" && match(pat, RUN)) {
        no++; o_rel[no] = rel; o_ln[no] = FNR; o_pat[no] = pat
        o_pre[no] = substr(pat, 1, RSTART + RLENGTH - 1)
      }
    }
  }
  prev = line
}
END {
  listed = 0
  for (j = 1; j <= no; j++) {
    print "PROSE-PIN: " o_rel[j] ":" o_ln[j] ": " o_pat[j]
    hit = 0
    for (e = 1; e <= ne; e++)
      if (e_path[e] == o_rel[j] && e_pre[e] != "" && index(o_pat[j], e_pre[e]) == 1) { hit = 1; used[e] = 1 }
    if (hit) listed++
    else { print "UNLISTED: " o_rel[j] ":" o_ln[j] ": " o_pat[j] "  (anchor on a token/heading, or allow-list: " o_rel[j] ":" o_pre[j] ")"; bad = 1 }
  }
  for (e = 1; e <= ne; e++)
    if (!used[e]) { print "STALE: " allowfile ":" e_ln[e] ": " e_raw[e] " (matches no prose pin; delete it)"; bad = 1 }
  if (bad) exit 1
  print "prose-pins: ok (" listed " allow-listed)"
}
AWK

awk -v allowfile="$ALLOW" "$PROG" "$ALLOW" "${files[@]}"
