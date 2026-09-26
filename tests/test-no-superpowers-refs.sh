#!/bin/bash
# test-no-superpowers-refs.sh — the superpowers-free guard (#1419).
#
# Calibration Block B (runs #11 vs #12, priced 6-issue slate, strict+sonnet)
# measured the superpowers plugin as `no-effect`, so #1419 dropped the
# dependency and replaced every invocation with the inline procedure it
# delegated to. This guard is what keeps it dropped: a later edit that
# re-introduces `Skill(skill: "superpowers:...")` into a pipeline skill or
# agent reds the suite instead of silently re-adding an install prerequisite
# no measurement justifies.
#
# PATTERN NOTE — the scan is for `superpowers:` WITH THE COLON, the plugin
# namespace separator. `docs/superpowers/{specs,plans}/` is a PATH convention,
# not a dependency, and is explicitly out of scope (#1419 Notes); a colonless
# pattern would false-positive on the `docs/superpowers/specs/...` spec path
# that skills/fullsend/SKILL.md legitimately cites. Check (c) below is the
# control that pins that choice.
#
# Static-only: reads tracked sources, runs nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCAN_DIRS="skills agents"

echo "=== (a) the scan surface exists (a missing dir would pass vacuously) ==="
MISSING=""
for d in $SCAN_DIRS; do
  [ -d "$ROOT/$d" ] || MISSING="$MISSING $d/"
done
if [ -z "$MISSING" ]; then
  pass_msg "both scan roots exist: skills/ agents/"
else
  fail_msg "scan root(s) missing at the plugin root —$MISSING (the scan below would be vacuous)"
fi

echo "=== (b) no \`superpowers:\` invocation survives under skills/ or agents/ ==="
SCAN_PATHS=""
for d in $SCAN_DIRS; do
  [ -d "$ROOT/$d" ] && SCAN_PATHS="$SCAN_PATHS $ROOT/$d"
done
HITS=""
if [ -n "$SCAN_PATHS" ]; then
  # shellcheck disable=SC2086
  HITS="$(grep -rn -- 'superpowers:' $SCAN_PATHS 2>/dev/null || true)"
fi
if [ -z "$HITS" ]; then
  pass_msg "skills/ and agents/ carry no \`superpowers:\` reference"
else
  # shellcheck disable=SC2086
  N_TOKENS="$(grep -roh -- 'superpowers:' $SCAN_PATHS 2>/dev/null | grep -c . )"
  N_FILES="$(printf '%s\n' "$HITS" | sed 's/:[0-9]*:.*//' | sort -u | grep -c . )"
  fail_msg "$N_FILES file(s) / $N_TOKENS \`superpowers:\` token(s) remain under skills/ + agents/ — replace each with the inline procedure it pointed at"
  printf '%s\n' "$HITS" | sed -e "s|^$ROOT/||" -e 's/\(^[^:]*:[0-9]*:\).*/\1/' | sort | sed 's/^/    /'
fi

echo "=== (c) control: the pattern ignores docs/superpowers/ PATH references ==="
# Out-of-scope by #1419's Notes. A colonless scan would red on the spec path
# skills/fullsend/SKILL.md cites, which is a filename, not an invocation.
if printf '%s\n' 'see docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md' \
   | grep -q -- 'superpowers:'; then
  fail_msg "the scan pattern matches a docs/superpowers/ path — it must stay colon-scoped"
else
  pass_msg "the scan pattern is colon-scoped: docs/superpowers/ paths are not invocations"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
