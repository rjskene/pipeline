#!/bin/bash
# test-no-retired-hook-refs-docs.sh — retired-hook-free operator docs (#1418).
#
# #1418 retires the two path/deletion guard hooks. The reduced deny posture is
# an ACCEPTED operator decision: the pipeline ships no path/deletion guard
# hooks, the rail is the session's permission mode (auto mode's classifier plus
# the #1421 `PermissionRequest` bridge) plus the comment-trust guard for comment
# bytes, and the four surviving guards encode pipeline rules the classifier
# cannot know. This guard keeps the OPERATOR docs honest about that: a doc that
# still tells the operator to plan around a hook that no longer loads is worse
# than no doc, so a re-introduced reference reds the suite.
#
# SCOPE — exactly the five operator docs listed in SCAN_FILES below.
# `docs/retros/**`, `docs/superpowers/specs/**` and `CHANGELOG.md` are the
# HISTORICAL record (what a cycle measured, what a release shipped) and MUST
# keep their references; naming them in the past tense is the point. Check (c)
# is the control that pins that scope decision.
#
# PATTERN NOTE — the two forbidden stems are assembled from fragments at run
# time so this guard's own source never carries either literal. Otherwise the
# checker would be its own false positive for any wider scan.
#
# Static-only: reads tracked docs, runs nothing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SCAN_FILES="
docs/security-model.md
docs/plugin-architecture.md
docs/operational-notes.md
docs/calibration.md
docs/observability.md
"

# Assembled, never literal: the two retired hook stems.
U="_"
TOK_PATHS="restrict${U}paths"
TOK_DELETIONS="block${U}deletions"
TOKENS="$TOK_PATHS $TOK_DELETIONS"

echo "=== (a) every scanned doc exists (a missing file would pass vacuously) ==="
MISSING=""
for f in $SCAN_FILES; do
  [ -f "$ROOT/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass_msg "all 5 operator docs are present on the scan surface"
else
  fail_msg "scan target(s) missing at the repo root —$MISSING (the scan below would be vacuous)"
fi

echo "=== (b) no retired-hook reference survives in the operator docs ==="
for f in $SCAN_FILES; do
  [ -f "$ROOT/$f" ] || continue
  HITS=""
  for tok in $TOKENS; do
    FOUND="$(grep -n -- "$tok" "$ROOT/$f" 2>/dev/null || true)"
    [ -n "$FOUND" ] && HITS="${HITS}${FOUND}"$'\n'
  done
  if [ -z "$HITS" ]; then
    pass_msg "$f names neither retired hook"
  else
    N="$(printf '%s' "$HITS" | grep -c . )"
    fail_msg "$f still names a retired hook on $N line(s) — rewrite for the surviving guards, do not re-add the hook"
    printf '%s' "$HITS" | grep . | sed 's/^\([0-9]*\):.*/    line \1/' | sort -u
  fi
done

echo "=== (c) control: the historical record is OUT of scope ==="
HIST_LEAK=""
for f in $SCAN_FILES; do
  case "$f" in
    docs/retros/*|docs/superpowers/*|CHANGELOG.md) HIST_LEAK="$HIST_LEAK $f" ;;
  esac
done
if [ -z "$HIST_LEAK" ]; then
  pass_msg "no historical path (docs/retros, docs/superpowers, CHANGELOG.md) is on the scan surface"
else
  fail_msg "historical path(s) on the scan surface —$HIST_LEAK — retros/specs/CHANGELOG must keep their references"
fi

echo "=== (d) control: the assembled pattern really matches a live reference ==="
PROBE="the ${TOK_PATHS}.py and ${TOK_DELETIONS}.py hooks"
MATCHED=0
for tok in $TOKENS; do
  printf '%s\n' "$PROBE" | grep -q -- "$tok" && MATCHED=$((MATCHED + 1))
done
if [ "$MATCHED" -eq 2 ]; then
  pass_msg "both assembled stems match a synthetic reference (check (b) is not vacuous)"
else
  fail_msg "only $MATCHED/2 assembled stems matched the synthetic reference — the fragment assembly is broken"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
