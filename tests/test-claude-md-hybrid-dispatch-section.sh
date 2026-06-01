#!/usr/bin/env bash
set -euo pipefail
# Guard: docs/architecture.md retains the hybrid dispatch section.
# Prior to #397 this test also asserted CLAUDE.md held a direct pointer to
# docs/architecture.md; that pointer was retired by the CLAUDE.md trim
# (CLAUDE.md now points only to docs/process-maps.md, the system-view index,
# which in turn references docs/architecture.md).
F="docs/architecture.md"
grep -q "Dispatch model (hybrid)" "$F" || { echo "FAIL: $F missing 'Dispatch model (hybrid)' section"; exit 1; }

# Scope assertions to the hybrid section only (header → next '## ' header), so the
# spawn-claude degradation note's "falls back to PATH B" line is not mis-scanned.
HYBRID=$(awk '/^## Dispatch model \(hybrid\)/{g=1; next} /^## /{if(g)exit} g{print}' "$F")
[ -n "$HYBRID" ] || { echo "FAIL: $F hybrid section is empty"; exit 1; }

echo "$HYBRID" | grep -qE "PATH A.*inline.*Agent" || { echo "FAIL: $F hybrid section does not state PATH A uses inline Agent dispatch"; exit 1; }

# Issue #748: PATH B now dispatches inline (no spawn-claude). This replaces the
# prior present-only masking guard (`PATH B.*spawn-claude` PRESENT), which stayed
# GREEN against a stale doc still claiming "PATH B uses spawn-claude.sh". The pair
# below — assert B-inline AND assert B-NOT-spawn-paired — is what converts the doc
# edit into a real red→green task.
echo "$HYBRID" | grep -qE "PATH B.*inline.*Agent" || { echo "FAIL: $F hybrid section does not state PATH B uses inline Agent dispatch"; exit 1; }
echo "$HYBRID" | grep -qE "PATH B.*spawn-claude|spawn-claude.*PATH B" && { echo "FAIL: $F hybrid section still pairs PATH B with spawn-claude (B is inline now, #748)"; exit 1; } || true

echo "$HYBRID" | grep -qE "PATH C.*spawn-claude|spawn-claude.*PATH C" || { echo "FAIL: $F hybrid section does not state PATH C uses spawn-claude.sh"; exit 1; }
echo "PASS: docs/architecture.md hybrid dispatch section"
