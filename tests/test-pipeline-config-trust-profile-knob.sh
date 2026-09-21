#!/bin/bash
set -uo pipefail

# Guard (issue #1291): PIPELINE_TRUST_PROFILE is a REAL knob now — both resolvers
# read it via scripts/_trust-profile.sh — so it must be DOCUMENTED as a commented
# template line in pipeline.config.example, and its spec-only #1275 exemption in
# tests/config-drift-allowlist.txt must be PEELED (the declaration now covers it).
#
# It stays COMMENTED on purpose: `doctor.sh --fix config` seeds only LIVE
# `PIPELINE_*=` lines, so a commented anchor documents the knob without pinning
# today's default (strict) into every consumer's live config (#1052).
#
# The same change RETIRES PIPELINE_CALIB_PROFILE (0 readers repo-wide —
# calibration-run.sh only ever EXPORTED it). Its surviving occurrences are
# negative regression-guards under tests/, which check-config-drift.sh reads as
# "referenced", so it needs an exact-match allowlist entry of the same class as
# PIPELINE_FRONTEND_PORT_OFFSET.
#
# Dual-scan per CLAUDE.md: pipeline.config.example is always present;
# pipeline.config is gitignored and host-only (no-op in CI / leaf worktrees).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"
ALLOW="$ROOT/tests/config-drift-allowlist.txt"
SCRIPTS="$ROOT/scripts"
LINT="$ROOT/scripts/check-config-drift.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXAMPLE" "$ALLOW" "$LINT"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

echo "pipeline.config.example: #1291 PIPELINE_TRUST_PROFILE knob"

# --- (1) example: declared, and declared COMMENTED -------------------------
inc
if grep -Eq '^#PIPELINE_TRUST_PROFILE=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_TRUST_PROFILE documented as a commented template line"
else
  fail_msg "example: PIPELINE_TRUST_PROFILE missing a commented '#PIPELINE_TRUST_PROFILE=' line"
fi

inc
if grep -Eq '^[[:space:]]*PIPELINE_TRUST_PROFILE=' "$EXAMPLE"; then
  fail_msg "example: PIPELINE_TRUST_PROFILE is LIVE — it must stay commented (--fix config must not seed it)"
else
  pass_msg "example: PIPELINE_TRUST_PROFILE stays commented (defaults-in-code, #1052)"
fi

# --- (2) live host-only pipeline.config: present, commented OR live --------
if [ -f "$LIVE" ]; then
  inc
  if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_TRUST_PROFILE=' "$LIVE"; then
    pass_msg "live: PIPELINE_TRUST_PROFILE present in pipeline.config"
  else
    fail_msg "live: PIPELINE_TRUST_PROFILE missing from pipeline.config (patch it by hand — the file is gitignored)"
  fi
else
  echo "  SKIP: pipeline.config not present (gitignored host-only file) — live scan skipped"
fi

# --- (3) allowlist: #1275 spec-only exemption PEELED -----------------------
inc
TP_ENTRIES="$(grep -Ecx '[[:space:]]*PIPELINE_TRUST_PROFILE[[:space:]]*' "$ALLOW" || true)"
if [ "$TP_ENTRIES" = "0" ]; then
  pass_msg "allowlist: #1275 spec-only PIPELINE_TRUST_PROFILE entry peeled (real declaration covers it)"
else
  fail_msg "allowlist: PIPELINE_TRUST_PROFILE still exempted ($TP_ENTRIES entr(y|ies)) — peel it, the knob is declared"
fi

# --- (3b) allowlist: retired-knob negative-guard entry, EXACT match --------
inc
CP_ENTRIES="$(grep -Ecx '[[:space:]]*PIPELINE_CALIB_PROFILE[[:space:]]*' "$ALLOW" || true)"
if [ "$CP_ENTRIES" = "1" ]; then
  pass_msg "allowlist: retired PIPELINE_CALIB_PROFILE has exactly one exact-match entry"
else
  fail_msg "allowlist: expected exactly 1 exact-match PIPELINE_CALIB_PROFILE entry, found $CP_ENTRIES"
fi

# --- (4) a real read site exists under scripts/ ----------------------------
inc
if grep -rq PIPELINE_TRUST_PROFILE "$SCRIPTS"; then
  pass_msg "scripts: PIPELINE_TRUST_PROFILE has a real read site"
else
  fail_msg "scripts: no PIPELINE_TRUST_PROFILE read site — the knob would be documentation-only"
fi

# --- (5) the drift lint is clean ------------------------------------------
inc
if bash "$LINT" >/dev/null 2>&1; then
  pass_msg "check-config-drift.sh: clean (rc=0)"
else
  fail_msg "check-config-drift.sh: reported drift (rc!=0) — run 'bash scripts/check-config-drift.sh' for detail"
fi

# --- (6) PIPELINE_CALIB_PROFILE is retired --------------------------------
inc
if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_CALIB_PROFILE=' "$EXAMPLE"; then
  fail_msg "example: retired PIPELINE_CALIB_PROFILE still declared — delete the line (#1291)"
else
  pass_msg "example: retired PIPELINE_CALIB_PROFILE absent from pipeline.config.example"
fi

inc
CP_SCRIPTS="$(grep -rl PIPELINE_CALIB_PROFILE "$SCRIPTS" | wc -l)"
if [ "$CP_SCRIPTS" -eq 0 ]; then
  pass_msg "scripts: retired PIPELINE_CALIB_PROFILE has no remaining occurrence"
else
  fail_msg "scripts: PIPELINE_CALIB_PROFILE still occurs in $CP_SCRIPTS file(s) under scripts/"
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
