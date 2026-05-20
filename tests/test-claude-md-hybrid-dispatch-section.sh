#!/usr/bin/env bash
set -euo pipefail
F="docs/architecture.md"
grep -q "Dispatch model (hybrid)" "$F" || { echo "FAIL: $F missing 'Dispatch model (hybrid)' section"; exit 1; }
grep -qE "PATH A.*inline.*Agent" "$F" || { echo "FAIL: $F hybrid section does not state PATH A uses inline Agent dispatch"; exit 1; }
grep -qE "PATH B.*spawn-claude|spawn-claude.*PATH B" "$F" || { echo "FAIL: $F hybrid section does not state PATH B uses spawn-claude.sh"; exit 1; }
grep -qE "PATH C.*spawn-claude|spawn-claude.*PATH C" "$F" || { echo "FAIL: $F hybrid section does not state PATH C uses spawn-claude.sh"; exit 1; }
grep -q "docs/architecture.md" CLAUDE.md || { echo "FAIL: CLAUDE.md missing pointer to docs/architecture.md"; exit 1; }
echo "PASS: docs/architecture.md hybrid dispatch section"
