#!/bin/bash
set -uo pipefail

# Guard (issue #1353): PIPELINE_LOGS_RETENTION_DAYS is the retention window read
# by scripts/prune-logs.sh, so it must be DOCUMENTED as a COMMENTED template
# line in pipeline.config.example, alongside the PIPELINE_LOGS_ENABLED block.
#
# It stays COMMENTED on purpose: `doctor.sh --fix config` seeds only LIVE
# `PIPELINE_*=` lines, so a commented anchor documents the knob without pinning
# today's default (30) into every consumer's live config (#1052, pinned by
# tests/test-doctor-golden-seed-set.sh). The single source of truth for the
# default is the read site `${PIPELINE_LOGS_RETENTION_DAYS:-30}` in
# scripts/prune-logs.sh; the example's documented default must agree with it.
#
# Triple scan per CLAUDE.md "Configuration conventions":
#   (1) pipeline.config.example — always present (tracked)
#   (2) scripts/prune-logs.sh   — the read site, and the default it encodes
#   (3) pipeline.config         — gitignored, host-only. Present on the dogfood
#       host, absent in CI. When present it must document the knob: the fix is
#       an operator HAND-PATCH (the file cannot ship in a PR). Hard FAIL, never
#       a WARN — same shape as tests/test-pipeline-config-trust-profile-knob.sh.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
READ_SITE="$ROOT/scripts/prune-logs.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXAMPLE" ]; then
  echo "ERROR: $EXAMPLE not found" >&2
  exit 1
fi

echo "pipeline.config.example: #1353 PIPELINE_LOGS_RETENTION_DAYS knob"

# --- (1) example: declared, and declared COMMENTED -------------------------
inc
if grep -Eq '^#[[:space:]]*PIPELINE_LOGS_RETENTION_DAYS=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_LOGS_RETENTION_DAYS documented as a commented template line"
else
  fail_msg "example: PIPELINE_LOGS_RETENTION_DAYS missing a commented '#PIPELINE_LOGS_RETENTION_DAYS=' line"
fi

inc
if grep -Eq '^[[:space:]]*PIPELINE_LOGS_RETENTION_DAYS=' "$EXAMPLE"; then
  fail_msg "example: PIPELINE_LOGS_RETENTION_DAYS is LIVE — it must stay commented (--fix config must not seed it)"
else
  pass_msg "example: PIPELINE_LOGS_RETENTION_DAYS stays commented (defaults-in-code, #1052)"
fi

# --- (2) read site: the knob is read, with a :-30 shaped default -----------
inc
if [ -f "$READ_SITE" ] && grep -Eq '\$\{PIPELINE_LOGS_RETENTION_DAYS:-[0-9]+\}' "$READ_SITE"; then
  pass_msg "scripts/prune-logs.sh reads \${PIPELINE_LOGS_RETENTION_DAYS:-N}"
else
  fail_msg "scripts/prune-logs.sh has no \${PIPELINE_LOGS_RETENTION_DAYS:-N} read site — the knob would be documentation-only"
fi

inc
CODE_DEFAULT="$(grep -Eo '\$\{PIPELINE_LOGS_RETENTION_DAYS:-[0-9]+\}' "$READ_SITE" 2>/dev/null \
  | head -1 | grep -Eo '[0-9]+' || true)"
EXAMPLE_DEFAULT="$(grep -E '^#[[:space:]]*PIPELINE_LOGS_RETENTION_DAYS=' "$EXAMPLE" 2>/dev/null \
  | head -1 | sed -E 's/^#[[:space:]]*PIPELINE_LOGS_RETENTION_DAYS=//; s/^["'\'']//; s/["'\'']$//' || true)"
if [ -n "$CODE_DEFAULT" ] && [ "$CODE_DEFAULT" = "30" ] && [ "$EXAMPLE_DEFAULT" = "$CODE_DEFAULT" ]; then
  pass_msg "default 30 agrees between the read site and the example line"
else
  fail_msg "default mismatch: read site='${CODE_DEFAULT:-<none>}' example='${EXAMPLE_DEFAULT:-<none>}' (both must be 30)"
fi

# --- (3) live host-only pipeline.config: present, commented OR live --------
if [ -f "$LIVE" ]; then
  inc
  if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_LOGS_RETENTION_DAYS=' "$LIVE"; then
    pass_msg "live: PIPELINE_LOGS_RETENTION_DAYS present in pipeline.config"
  else
    fail_msg "live: PIPELINE_LOGS_RETENTION_DAYS missing from pipeline.config (patch it by hand — the file is gitignored)"
  fi
else
  echo "  SKIP: pipeline.config not present (gitignored host-only file) — live scan skipped"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

if [ "$FAIL" -eq 0 ]; then
  echo "RESULT: PASS"
else
  echo "RESULT: FAIL"
  exit 1
fi
