#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HELPER="$REPO/dev/self-audit/should-dispatch-audit.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/audits"; mkdir -p "$OUT"
PROJ="$TMP/projects/repo-hash"; mkdir -p "$PROJ"

# --- Scenario A: no transcript newer than index.jsonl -> skip
printf '{"timestamp":"2026-05-17T12:00:00Z","digest":"inner-x.md","merged_prs":0}\n' > "$OUT/index.jsonl"
OLD_TS_TRANSCRIPT="$PROJ/old.jsonl"
: > "$OLD_TS_TRANSCRIPT"
touch -d '2026-05-17T11:00:00Z' "$OLD_TS_TRANSCRIPT"
out=$(AUDIT_OUT_DIR="$OUT" AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" bash "$HELPER" || true)
assert "skips when no transcript newer than index" \
  "echo \"\$out\" | grep -q '^skip:no-newer-transcript'"

# --- Scenario A2 (NEW): empty index.jsonl + >=10-turn transcript -> dispatch
# Covers the "OR no entry yet" half of the gate from the issue spec.
rm -f "$OUT/index.jsonl"; : > "$OUT/index.jsonl"
FIRST_RUN_TRANSCRIPT="$PROJ/first.jsonl"
: > "$FIRST_RUN_TRANSCRIPT"
for i in $(seq 1 12); do
  printf '{"type":"user","uuid":"u%d","sessionId":"first-run-xyz"}\n' "$i" >> "$FIRST_RUN_TRANSCRIPT"
done
touch -d '2026-05-17T13:00:00Z' "$FIRST_RUN_TRANSCRIPT"
out=$(AUDIT_OUT_DIR="$OUT" AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" bash "$HELPER" || true)
assert "dispatches when index.jsonl is empty (first-run case)" \
  "echo \"\$out\" | grep -qE '^dispatch:.*first\\.jsonl:first-run-xyz'"

# Restore the populated index for subsequent scenarios.
printf '{"timestamp":"2026-05-17T12:00:00Z","digest":"inner-x.md","merged_prs":0}\n' > "$OUT/index.jsonl"
rm -f "$FIRST_RUN_TRANSCRIPT"

# --- Scenario B: newer transcript but only 5 turns -> skip
NEW_TS_TRANSCRIPT="$PROJ/new.jsonl"
for i in 1 2 3 4 5; do
  printf '{"type":"user","uuid":"u%d"}\n' "$i" >> "$NEW_TS_TRANSCRIPT"
done
touch -d '2026-05-17T13:00:00Z' "$NEW_TS_TRANSCRIPT"
out=$(AUDIT_OUT_DIR="$OUT" AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" bash "$HELPER" || true)
assert "skips when turn count <10" \
  "echo \"\$out\" | grep -q '^skip:turn-count-below-threshold'"

# --- Scenario C: newer transcript AND >=10 turns -> dispatch
: > "$NEW_TS_TRANSCRIPT"
for i in $(seq 1 12); do
  printf '{"type":"user","uuid":"u%d","sessionId":"abc-123"}\n' "$i" >> "$NEW_TS_TRANSCRIPT"
done
touch -d '2026-05-17T13:00:00Z' "$NEW_TS_TRANSCRIPT"
out=$(AUDIT_OUT_DIR="$OUT" AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" bash "$HELPER" || true)
assert "dispatches when both conditions hold" \
  "echo \"\$out\" | grep -qE '^dispatch:.*new\\.jsonl:abc-123'"

# --- Scenario D: in-place placeholder replacement
DIGEST="$OUT/inner-fixture.md"
cat > "$DIGEST" <<'MD'
# Inner audit — 2026-05-17T12:00:00Z

## Compliance
- x

## Interaction
- prior session: issue=#1 path=B skill=execute-issue-plan (session abc-123)
- _pending subagent classification — session abc-123_

## Pattern → defaults
- y
MD
REPLACEMENT=$'### Event 1\n- **Trigger:** assistant proposed cleanup of three worktrees\n- **Correction:** the user said skip those\n- **Suggested default:** Confirm cleanup once per batch not per worktree.'
python3 - "$DIGEST" "abc-123" "$REPLACEMENT" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); uuid = sys.argv[2]; rep = sys.argv[3]
placeholder = f"- _pending subagent classification — session {uuid}_"
body = p.read_text()
assert placeholder in body, "placeholder not found"
p.write_text(body.replace(placeholder, rep))
PY
assert "placeholder line removed after append" \
  "! grep -q '_pending subagent classification' \"\$DIGEST\""
assert "Event 1 block present"      "grep -q '^### Event 1' \"\$DIGEST\""
assert "Trigger field present"       "grep -q '^- \\*\\*Trigger:\\*\\*' \"\$DIGEST\""
assert "Correction field present"    "grep -q '^- \\*\\*Correction:\\*\\*' \"\$DIGEST\""
assert "Suggested default present"   "grep -q '^- \\*\\*Suggested default:\\*\\*' \"\$DIGEST\""
assert "surrounding sections preserved" \
  "grep -q '^## Pattern → defaults' \"\$DIGEST\" && grep -q '^## Compliance' \"\$DIGEST\""

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
