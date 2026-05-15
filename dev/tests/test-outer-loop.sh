#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUTER="$REPO/dev/self-audit/outer-loop.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/audits"
mkdir -p "$OUT"

# Three inner digests each surfacing the same compliance signal.
for i in 1 2 3; do
  D="$OUT/inner-2026-05-15T0${i}0000Z.md"
  cat > "$D" <<MD
# Inner audit — 2026-05-15T0${i}:00:00Z

## Compliance
- SIGNAL: orchestrator skipped TDD red step on PR #1${i}0
- PR #1${i}1 — feat: x (branch feature/x-${i})

## Interaction
- turn_count_p50: 12

## Pattern → defaults
## Efficiency
## Data quality
- subagents: present
MD
  printf '{"timestamp":"2026-05-15T0%d:00:00Z","digest":"inner-2026-05-15T0%d0000Z.md","merged_prs":1}\n' "$i" "$i" >> "$OUT/index.jsonl"
done

AUDIT_OUT_DIR="$OUT" bash "$OUTER"

DIGEST=$(ls "$OUT"/outer-*.md 2>/dev/null | head -1 || true)
assert "outer-*.md digest created" "[ -n \"\$DIGEST\" ] && [ -f \"\$DIGEST\" ]"
assert "outer digest references all 3 inner runs" \
  "[ \"\$(grep -c 'inner-2026-05-15T0' \"\$DIGEST\")\" -ge \"3\" ]"
assert "outer digest flags cross-run consistency" \
  "grep -qiE 'pattern|consistent|recurring|repeated' \"\$DIGEST\""
assert "outer digest names a codification target (plugin surface, not memory)" \
  "grep -qiE 'codification target|skill prose|pipeline\\.config\\.example|hooks/|scripts/' \"\$DIGEST\""
assert "outer digest does NOT recommend Claude memory" \
  "! grep -qi 'claude memory\\|user memory\\|MEMORY\\.md' \"\$DIGEST\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
