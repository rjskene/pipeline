#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HOOK="$REPO/dev/hooks/audit-on-pipeline-run.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Sandbox: temp dir + stub inner-loop that writes a marker.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MARKER="$TMP/inner-loop-fired"
STUB="$TMP/inner-loop-stub.sh"
printf '#!/usr/bin/env bash\ntouch "%s"\n' "$MARKER" > "$STUB"
chmod +x "$STUB"

# Test 1: prompt does NOT start with a pipeline command -> no marker.
cat <<'JSON' | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
{"prompt": "/help"}
JSON
sleep 0.3
assert "non-pipeline prompt does NOT fire inner-loop" "[ ! -f \"\$MARKER\" ]"

# Test 2: prompt starts with /pipeline:status (new canonical) -> hook exits fast, marker materializes.
rm -f "$MARKER"
START=$(date +%s%N)
cat <<'JSON' | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
{"prompt": "/pipeline:status"}
JSON
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
assert "hook returned in <500ms (was ${ELAPSED_MS}ms)" "[ \"\$ELAPSED_MS\" -lt 500 ]"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
assert "/pipeline:status prompt DID fire inner-loop (marker written)" "[ -f \"\$MARKER\" ]"

# Test 3: prompt starts with /pipeline:status with trailing args -> still fires.
rm -f "$MARKER"
cat <<'JSON' | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
{"prompt": "/pipeline:status FULL SEND"}
JSON
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
assert "/pipeline:status FULL SEND fires inner-loop" "[ -f \"\$MARKER\" ]"

# Test 4: prompt starts with /pipeline:run (deprecated alias) -> still fires.
rm -f "$MARKER"
cat <<'JSON' | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
{"prompt": "/pipeline:run"}
JSON
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
assert "/pipeline:run alias prompt DID fire inner-loop (marker written)" "[ -f \"\$MARKER\" ]"

# Test 5: prompt starts with /pipeline:run alias with trailing args -> still fires.
rm -f "$MARKER"
cat <<'JSON' | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
{"prompt": "/pipeline:run FULL SEND"}
JSON
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -f "$MARKER" ] && break
  sleep 0.1
done
assert "/pipeline:run FULL SEND alias fires inner-loop" "[ -f \"\$MARKER\" ]"

# Test 6: garbled stdin -> hook does NOT crash, does NOT fire.
rm -f "$MARKER"
echo "not json at all" | AUDIT_INNER_LOOP="$STUB" bash "$HOOK"
sleep 0.3
assert "garbled stdin does NOT crash hook and does NOT fire" "[ ! -f \"\$MARKER\" ]"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
