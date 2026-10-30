#!/usr/bin/env bash
set -euo pipefail

# Fixture test for tests/test-prose-pins-are-anchors.sh (issue #1562).
#
# Runs the lint against temp fixture dirs via PROSE_PINS_DIR / PROSE_PINS_ALLOW.
# Fixture bodies are written with printf from variables so this file's OWN
# source lines never look like a prose pin (this file is also excluded from the
# lint's scan set as test-prose-pins-*.sh).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINT="$SCRIPT_DIR/test-prose-pins-are-anchors.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

W5='alpha bravo charlie delta echo'
W4='foxtrot golf hotel india'
PROSE_VAR='$X_BODY'
OUT_VAR='$OUT'
SKILL_PATH_ARG='skills/demo/SKILL.md'

# run_lint <dir> <allow> — sets RC and OUTPUT.
run_lint() {
  set +e
  OUTPUT="$(PROSE_PINS_DIR="$1" PROSE_PINS_ALLOW="$2" bash "$LINT" </dev/null 2>&1)"
  RC=$?
  set -e
}

# Fixture dirs.
mkdir -p "$T/a" "$T/d" "$T/e"
printf '#!/usr/bin/env bash\ngrep -qF %s <<< "%s"\n' "'$W5'" "$PROSE_VAR" > "$T/a/test-a.sh"
printf '#!/usr/bin/env bash\ngrep -qF %s <<< "%s"\n' "'$W5'" "$OUT_VAR" > "$T/d/test-b.sh"
printf '#!/usr/bin/env bash\ngrep -qiF %s %s\n' "'$W4'" "$SKILL_PATH_ARG" > "$T/e/test-b.sh"

# Allow files.
printf '# header\n\n# justification: fixture\ntests/test-a.sh:%s\n' "$W5" > "$T/allow-ok"
cp "$T/allow-ok" "$T/allow-stale"
printf '\n# justification: stale\ntests/test-a.sh:%s\n' "$W4" >> "$T/allow-stale"
printf '\ntests/test-a.sh:%s\n' "$W5" > "$T/allow-unjustified"

echo "=== (a) unlisted 5-word pin on a prose input fails ==="
run_lint "$T/a" "$T/missing-allow"
if [ "$RC" -eq 1 ] && grep -qF 'UNLISTED:' <<< "$OUTPUT"; then
  pass "(a) exit 1 with UNLISTED:"
else
  fail "(a) expected exit 1 + UNLISTED:, got rc=$RC: $OUTPUT"
fi

echo "=== (b) listed under a # comment passes ==="
run_lint "$T/a" "$T/allow-ok"
if [ "$RC" -eq 0 ] && grep -qF 'prose-pins: ok (1 allow-listed)' <<< "$OUTPUT"; then
  pass "(b) exit 0, 1 allow-listed"
else
  fail "(b) expected exit 0 + ok (1 allow-listed), got rc=$RC: $OUTPUT"
fi

echo "=== (c) a stale entry fails ==="
run_lint "$T/a" "$T/allow-stale"
if [ "$RC" -eq 1 ] && grep -qF 'STALE:' <<< "$OUTPUT"; then
  pass "(c) exit 1 with STALE:"
else
  fail "(c) expected exit 1 + STALE:, got rc=$RC: $OUTPUT"
fi

echo "=== (d) 5-word pin on script stdout is ignored ==="
run_lint "$T/d" "$T/missing-allow"
if [ "$RC" -eq 0 ] && ! grep -qF 'test-b.sh' <<< "$OUTPUT"; then
  pass "(d) stdout pin ignored"
else
  fail "(d) expected exit 0 with no test-b.sh report, got rc=$RC: $OUTPUT"
fi

echo "=== (e) 4-word pin on a SKILL.md path is ignored ==="
run_lint "$T/e" "$T/missing-allow"
if [ "$RC" -eq 0 ] && ! grep -qF 'test-b.sh' <<< "$OUTPUT"; then
  pass "(e) 4-word pin ignored"
else
  fail "(e) expected exit 0 with no test-b.sh report, got rc=$RC: $OUTPUT"
fi

echo "=== (f) an entry block without a # justification fails ==="
run_lint "$T/a" "$T/allow-unjustified"
if [ "$RC" -eq 1 ] && grep -qF 'UNJUSTIFIED:' <<< "$OUTPUT"; then
  pass "(f) exit 1 with UNJUSTIFIED:"
else
  fail "(f) expected exit 1 + UNJUSTIFIED:, got rc=$RC: $OUTPUT"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "All prose-pins lint fixture checks passed."
