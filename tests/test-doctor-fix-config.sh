#!/usr/bin/env bash
# test-doctor-fix-config.sh — contract test for `doctor.sh --fix config`
# (the envvar-reconcile mode, issue #1038).
#
# `--fix config` is a KEY-LEVEL MERGE, append-only:
#   - append every PIPELINE_* key present in pipeline.config.example but ABSENT
#     from the host pipeline.config, at the example default value;
#   - NEVER overwrite an existing host value (PIPELINE_REPO + per-operator paths
#     are sacred);
#   - preserve host comments / ordering / non-PIPELINE lines (append-only — no
#     in-place rewrite of existing lines);
#   - surface placeholder / no-safe-default keys (empty default, owner/repo,
#     /path/..., PIPELINE_MOCK_WEB_EVAL_*) as "added — needs your value" rather
#     than silently running empty;
#   - print a change report (version X->Y, labels added, envvars added, envvars
#     still needing a value).
#
# Hermetic: a temp fixture dir holding its own pipeline.config.example +
# pipeline.config; doctor.sh is run with cwd=fixture so it reconciles the
# fixture, never the repo's live config.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$DOCTOR" ]; then
  echo "ERROR: $DOCTOR not found" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Fixture: example carries A=1, B=2, a placeholder, and a no-default key. ---
cat > "$WORK/pipeline.config.example" <<'EOF'
# example header comment
set -a
PIPELINE_REPO="owner/repo"                # placeholder default
PIPELINE_ALPHA=1                           # has a safe default
PIPELINE_BETA=2                            # missing from host — should be added
PIPELINE_MOCK_WEB_EVAL_X=""                # placeholder family — needs your value
#PIPELINE_COMMENTED=9                       # commented template — NOT a required live key
set +a
EOF

# --- Fixture: host config has only A (custom value) + a custom comment +
#     a non-PIPELINE line. PIPELINE_REPO already set to a real value (sacred).
cat > "$WORK/pipeline.config" <<'EOF'
# my custom host header
set -a
PIPELINE_REPO="rjskene/pipeline"           # sacred host value
PIPELINE_ALPHA=99                          # host override — must NOT be touched
CUSTOM_NON_PIPELINE_LINE="keepme"
set +a
EOF

# Snapshot the host config before reconcile so we can assert existing lines
# are preserved byte-for-byte.
cp "$WORK/pipeline.config" "$WORK/pipeline.config.before"

# --- Run `doctor.sh --fix config` with cwd=fixture. ---
OUT="$(cd "$WORK" && bash "$DOCTOR" --fix config 2>&1)"
RC=$?

# Case 1: exits 0.
if [ "$RC" -eq 0 ]; then
  pass_msg "exit 0"
else
  fail_msg "expected exit 0, got $RC"
fi

HOST="$WORK/pipeline.config"

# Case 2: missing key B appended at example default.
if grep -Eq '^[[:space:]]*PIPELINE_BETA=2\b' "$HOST"; then
  pass_msg "PIPELINE_BETA=2 appended from example default"
else
  fail_msg "PIPELINE_BETA=2 not appended to host config"
fi

# Case 3: host value for A preserved (NEVER overwritten).
if grep -Eq '^[[:space:]]*PIPELINE_ALPHA=99\b' "$HOST"; then
  pass_msg "PIPELINE_ALPHA host value 99 preserved"
else
  fail_msg "PIPELINE_ALPHA host value was overwritten"
fi
# And the example default value must NOT have been appended as a duplicate.
if [ "$(grep -cE '^[[:space:]]*PIPELINE_ALPHA=' "$HOST")" -eq 1 ]; then
  pass_msg "PIPELINE_ALPHA appears exactly once (no duplicate append)"
else
  fail_msg "PIPELINE_ALPHA appended a duplicate line"
fi

# Case 4: PIPELINE_REPO sacred host value preserved + not duplicated.
if grep -Eq '^[[:space:]]*PIPELINE_REPO="rjskene/pipeline"' "$HOST" \
   && [ "$(grep -cE '^[[:space:]]*PIPELINE_REPO=' "$HOST")" -eq 1 ]; then
  pass_msg "PIPELINE_REPO sacred value preserved, not duplicated"
else
  fail_msg "PIPELINE_REPO host value was altered or duplicated"
fi

# Case 5: placeholder family key appended AND surfaced as "needs your value".
if grep -Eq '^[[:space:]]*PIPELINE_MOCK_WEB_EVAL_X=' "$HOST"; then
  pass_msg "PIPELINE_MOCK_WEB_EVAL_X placeholder key appended"
else
  fail_msg "PIPELINE_MOCK_WEB_EVAL_X placeholder key not appended"
fi
if printf '%s\n' "$OUT" | grep -Eqi 'PIPELINE_MOCK_WEB_EVAL_X.*needs your value'; then
  pass_msg "placeholder key surfaced as 'needs your value'"
else
  fail_msg "placeholder key NOT surfaced as 'needs your value'"
fi

# Case 6: commented example template line is NOT force-appended as a live key.
if grep -Eq '^[[:space:]]*PIPELINE_COMMENTED=' "$HOST"; then
  fail_msg "commented example template PIPELINE_COMMENTED was force-appended"
else
  pass_msg "commented example template not force-appended"
fi

# Case 7: original host comments / ordering / non-PIPELINE lines preserved.
# The pre-reconcile content must appear verbatim as a prefix of the result
# (append-only means the original lines are untouched, in order).
BEFORE_LINES="$(wc -l < "$WORK/pipeline.config.before")"
if head -n "$BEFORE_LINES" "$HOST" | diff -q - "$WORK/pipeline.config.before" >/dev/null 2>&1; then
  pass_msg "original host lines preserved verbatim (append-only)"
else
  fail_msg "original host lines were rewritten/reordered (not append-only)"
fi
if grep -Fxq 'CUSTOM_NON_PIPELINE_LINE="keepme"' "$HOST"; then
  pass_msg "non-PIPELINE host line preserved"
else
  fail_msg "non-PIPELINE host line was dropped"
fi

# Case 8: per-key report line for the added key.
if printf '%s\n' "$OUT" | grep -Eq 'PIPELINE_BETA=2'; then
  pass_msg "report names the added key/value PIPELINE_BETA=2"
else
  fail_msg "report does not name the added key PIPELINE_BETA"
fi

# --- Task 2: change-report assembly with optional vX vY version args. ---
# Re-run on a fresh fixture (host already reconciled above) passing the diffed
# versions so the detector's injected directive can relay them.
cat > "$WORK/pipeline.config" <<'EOF'
set -a
PIPELINE_REPO="rjskene/pipeline"
set +a
EOF

OUT2="$(cd "$WORK" && bash "$DOCTOR" --fix config 0.1.0 0.2.0 2>&1)"
RC2=$?

# Case 9: version args accepted (exit 0) and the report names the version delta.
if [ "$RC2" -eq 0 ]; then
  pass_msg "version-arg form exits 0"
else
  fail_msg "version-arg form expected exit 0, got $RC2"
fi
if printf '%s\n' "$OUT2" | grep -Eq 'version[[:space:]:]+0\.1\.0[^0-9].*0\.2\.0'; then
  pass_msg "report shows version 0.1.0 -> 0.2.0 delta"
else
  fail_msg "report does not show the 0.1.0 -> 0.2.0 version delta"
fi

# Case 10: report has a labels line (added: ... OR none).
if printf '%s\n' "$OUT2" | grep -Eqi 'labels'; then
  pass_msg "report includes a labels line"
else
  fail_msg "report missing a labels line"
fi

# Case 11: report still names an envvars-added line on this run too.
if printf '%s\n' "$OUT2" | grep -Eqi 'envvars added'; then
  pass_msg "report includes an envvars-added line"
else
  fail_msg "report missing an envvars-added line"
fi

echo ""
echo "================================"
echo "  test-doctor-fix-config: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
