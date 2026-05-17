#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
INNER="$REPO/dev/self-audit/inner-loop.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Sandbox: redirect AUDIT_OUT_DIR to a tempdir and stub external commands.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/audits"
mkdir -p "$OUT"
LOGS="$TMP/logs"
mkdir -p "$LOGS/subagents"
: > "$LOGS/runs.log"
: > "$LOGS/tool-use.log"

# Seed a runs.log row so the inner-loop's prior-session one-liner has data.
printf '2026-05-15T00:00:00Z\tsession=test-uuid-0001\tissue=99\tpath=B\tskill=execute-issue-plan\tworktree=/tmp/wt\n' \
  > "$LOGS/runs.log"

# Stub gh CLI: returns one fake merged feature PR.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) printf '[{"number":99,"title":"feat: stub","mergedAt":"2026-05-15T00:00:00Z","headRefName":"feature/stub"}]\n' ;;
  *"issue list"*) printf '[]\n' ;;
  *"pr view"*) printf '{"commits":[{"messageHeadline":"feat: stub"}]}\n' ;;
  *) printf '{}\n' ;;
esac
SH
chmod +x "$STUB_BIN/gh"

PATH="$STUB_BIN:$PATH" \
AUDIT_OUT_DIR="$OUT" \
AUDIT_LOGS_DIR="$LOGS" \
AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" \
AUDIT_OUTER_LOOP_DISABLED=1 \
  bash "$INNER"

DIGEST=$(ls "$OUT"/inner-*.md 2>/dev/null | head -1 || true)
assert "inner-*.md digest created" "[ -n \"\$DIGEST\" ] && [ -f \"\$DIGEST\" ]"
assert "digest has ## Compliance section"  "grep -q '^## Compliance' \"\$DIGEST\""
assert "digest has ## Interaction section" "grep -q '^## Interaction' \"\$DIGEST\""
assert "Interaction section has subagent-pending placeholder" \
  "grep -qE '_pending subagent classification — session [a-zA-Z0-9_-]+_' \"\$DIGEST\""
assert "Interaction section has runs.log one-liner (prior session summary)" \
  "grep -qE '^- prior session:' \"\$DIGEST\""
assert "Interaction section does NOT contain legacy TODO lines" \
  "! grep -qE 'Turn count per issue: TODO|User-correction frequency: TODO|Confirmations Claude asked for: TODO' \"\$DIGEST\""
assert "digest has ## Pattern section"     "grep -qE '^## Pattern' \"\$DIGEST\""
assert "digest has ## Efficiency section"  "grep -q '^## Efficiency' \"\$DIGEST\""
assert "digest has ## Data quality section" "grep -q '^## Data quality' \"\$DIGEST\""
assert "index.jsonl has one new line" "[ \"\$(wc -l < \"$OUT/index.jsonl\")\" = \"1\" ]"
assert "index.jsonl entry is valid JSON" "jq -e . \"$OUT/index.jsonl\" >/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
