#!/bin/bash
# Guard the README rail diagrams (docs/assets/*.svg) against drift from their
# template (dev/readme-assets/render.py) and against the README losing the
# <picture> embeds that select the light / dark variant per viewer.
#
# No `printf | grep -q` pipes under pipefail (SIGPIPE class, #1381): every scan
# reads the file directly.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
ASSETS="$REPO_ROOT/docs/assets"
RENDER="$REPO_ROOT/dev/readme-assets/render.py"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "(1) template matches the committed SVGs"
if python3 "$RENDER" --check >/dev/null 2>&1; then
  pass "render.py --check reports no drift"
else
  fail "render.py --check reports drift — re-run: python3 dev/readme-assets/render.py"
fi

echo "(2) every rail exists in both variants and is GitHub-safe"
for rail in lifecycle paths branches trust; do
  for f in "$rail.svg" "$rail-dark.svg"; do
    if [ -s "$ASSETS/$f" ]; then pass "$f present"; else fail "$f missing"; continue; fi
    if grep -qF 'xmlns="http://www.w3.org/2000/svg"' "$ASSETS/$f"; then
      pass "$f declares the SVG namespace"
    else
      fail "$f lacks xmlns (GitHub's image proxy needs it)"
    fi
    if grep -qF 'var(--' "$ASSETS/$f"; then
      fail "$f uses CSS custom properties (stripped by GitHub's sanitiser)"
    else
      pass "$f bakes its colours in"
    fi
  done
done

echo "(3) README embeds each rail through a theme-aware <picture>"
for rail in lifecycle paths branches trust; do
  if grep -qF "srcset=\"docs/assets/$rail-dark.svg\"" "$README" \
     && grep -qF "src=\"docs/assets/$rail.svg\"" "$README"; then
    pass "README embeds $rail (light + dark)"
  else
    fail "README does not embed docs/assets/$rail.svg with a dark source"
  fi
done

echo "(4) rail content pins"
for stage in classify plan plan-eval execute "pr-eval preflight" pr-eval "auto-merge gate"; do
  if grep -qF ">$stage<" "$ASSETS/lifecycle.svg"; then pass "lifecycle names $stage"; else fail "lifecycle lacks stage $stage"; fi
done
for lane in docs-only standard multi-task quick-fix; do
  if grep -qF "$lane" "$ASSETS/paths.svg"; then pass "paths names $lane"; else fail "paths lacks lane $lane"; fi
done
if grep -qF 'PermissionRequest' "$ASSETS/trust.svg"; then pass "trust names the PermissionRequest bridge"; else fail "trust lacks PermissionRequest"; fi
if grep -qF 'back-sync-release' "$ASSETS/branches.svg"; then pass "branches names the back-sync workflow"; else fail "branches lacks back-sync-release"; fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
