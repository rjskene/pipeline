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

# --- Scenario E: Suggested default lines repeat across 2 of 3 runs -> flagged
TMP2=$(mktemp -d); trap 'rm -rf "$TMP" "$TMP2"' EXIT
OUT2="$TMP2/audits"; mkdir -p "$OUT2"
for i in 1 2 3; do
  D="$OUT2/inner-2026-05-16T0${i}0000Z.md"
  cat > "$D" <<MD
# Inner audit — 2026-05-16T0${i}:00:00Z

## Interaction
### Event 1
- **Trigger:** assistant proposed cleanup of three worktrees
- **Correction:** the user said skip those
- **Suggested default:** Confirm cleanup once per batch not per worktree.
MD
  # 3rd run carries a DIFFERENT suggested default to confirm 2-of-3 still fires
  if [ "$i" = "3" ]; then
    sed -i 's|Confirm cleanup once per batch not per worktree.|Some unrelated default.|' "$D"
  fi
  printf '{"timestamp":"2026-05-16T0%d:00:00Z","digest":"inner-2026-05-16T0%d0000Z.md","merged_prs":0}\n' "$i" "$i" >> "$OUT2/index.jsonl"
done
AUDIT_OUT_DIR="$OUT2" bash "$OUTER"
OUTER_DIGEST=$(ls "$OUT2"/outer-*.md | head -1)
assert "outer-loop flags repeating Suggested default (2-of-3)" \
  "grep -qF 'Confirm cleanup once per batch not per worktree.' \"\$OUTER_DIGEST\""
assert "outer-loop tags Suggested-default codification target" \
  "grep -qiE 'codification candidate|repeating suggested default' \"\$OUTER_DIGEST\""
assert "outer-loop emits ## Suggested issues section when patterns exist" \
  "grep -qE '^## Suggested issues' \"\$OUTER_DIGEST\""
assert "outer-loop Suggested-issues row has conventional-commit title shape" \
  "grep -qE '^- \\*\\*Title:\\*\\* (feat|fix|chore)\\([a-z0-9-]+\\): ' \"\$OUTER_DIGEST\""
assert "outer-loop Suggested-issues row includes a Body field" \
  "grep -qE '^  - \\*\\*Body:\\*\\* ' \"\$OUTER_DIGEST\""
assert "outer-loop Suggested-issues row includes a Label hint field" \
  "grep -qE '^  - \\*\\*Label hint:\\*\\* (brainstorm|none)$' \"\$OUTER_DIGEST\""
assert "outer-loop Suggested-issues row references the originating Suggested default" \
  "grep -qE '^  - \\*\\*From Suggested default:\\*\\* ' \"\$OUTER_DIGEST\""

# --- Scenario F: no repeating Suggested defaults -> ## Suggested issues section is OMITTED
TMP3=$(mktemp -d); trap 'rm -rf "$TMP" "$TMP2" "$TMP3"' EXIT
OUT3="$TMP3/audits"; mkdir -p "$OUT3"
for i in 1 2 3; do
  D="$OUT3/inner-2026-05-18T0${i}0000Z.md"
  cat > "$D" <<MD
# Inner audit — 2026-05-18T0${i}:00:00Z

## Interaction
### Event 1
- **Trigger:** unique trigger ${i}
- **Correction:** unique correction ${i}
- **Suggested default:** Unique default text number ${i}.
MD
  printf '{"timestamp":"2026-05-18T0%d:00:00Z","digest":"inner-2026-05-18T0%d0000Z.md","merged_prs":0}\n' "$i" "$i" >> "$OUT3/index.jsonl"
done
AUDIT_OUT_DIR="$OUT3" bash "$OUTER"
OUTER_DIGEST3=$(ls "$OUT3"/outer-*.md | head -1)
assert "outer-loop OMITS ## Suggested issues section when no patterns" \
  "! grep -qE '^## Suggested issues' \"\$OUTER_DIGEST3\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
