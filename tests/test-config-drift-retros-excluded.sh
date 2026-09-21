#!/bin/bash
set -uo pipefail
#
# Tests for scripts/check-config-drift.sh — `docs/retros/` is EVIDENCE, not
# knob documentation, so the DEFAULT scan must skip it (issue #1293).
#
# Why: every evolve-loop retro quotes the knobs the cycle touched. A quoted
# `PIPELINE_*` token in retro prose reads to the lint as a REFERENCE, so a
# retro that names a knob the example does not declare turns the tip red and
# the operator hand-rewords the retro. Retros are an append-only record of
# what happened; they must not be edited to satisfy a lint.
#
# The contract pinned here:
#   1. the DEFAULT scan (no positional dirs) skips `retros/` subtrees;
#   2. the rest of `docs/` is still scanned (so 1 is not "the tree was skipped");
#   3. an EXPLICIT positional dir still scans the subtree — the escape hatch;
#   4. a knob DECLARED in the example and referenced ONLY from retro prose
#      surfaces as ORPHAN rather than vanishing.
#
# FULLY HERMETIC. Every sub-case builds a FRESH synthetic root via mkfx() —
# sub-case 4's seed applied to a shared root makes sub-case 1 report
# `ORPHAN: PIPELINE_SYNTH_DECLARED_RETRO` instead of `ok`, so the sub-cases
# would be order-dependent. Nothing here reads the live tree's state.
#
# The lint copy lands in `$FX/bin/`, NOT `$FX/scripts/`: REPO_ROOT is
# `dirname "$0"/..`, so `$FX/bin/check-config-drift.sh` still yields
# REPO_ROOT=$FX while keeping the lint's OWN header tokens
# (PIPELINE_CONFIG_DRIFT_ALLOWLIST, PIPELINE_EVAL_, …) out of the referenced
# set. `$FX/bin` is in no default SCAN_DIRS.
#
# Every invocation runs under `env -u PIPELINE_CONFIG_DRIFT_ALLOWLIST`. The
# lint resolves its allowlist as
# `${PIPELINE_CONFIG_DRIFT_ALLOWLIST:-$REPO_ROOT/tests/config-drift-allowlist.txt}`,
# so an inherited export would point the FIXTURE lint at the REAL allowlist —
# which suppresses every PIPELINE_SYNTH_* token — and sub-case 1 would report
# `ok` for the wrong reason while sub-case 4's ORPHAN assertion collapsed.
# The sibling tests/test-check-config-drift.sh sets that var per sub-case, so
# inheritance is a live possibility under run-test-suite.sh.
#
# The four PIPELINE_SYNTH_* names below are heredoc literals inside this file
# and `tests/` IS a default scan dir, so the live-tree scan reads them off
# this test. They are suppressed by the justified `PIPELINE_SYNTH_`
# concat-prefix entry in tests/config-drift-allowlist.txt, which is part of
# the same deliverable as this file.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LINT_SRC="$ROOT/scripts/check-config-drift.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

if [ ! -f "$LINT_SRC" ]; then
  echo "ERROR: lint not found at $LINT_SRC" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FXN=0
# mkfx -> echoes the path of a FRESH synthetic repo root.
mkfx() {
  FXN=$((FXN + 1))
  local fx="$TMP/fx$FXN"
  mkdir -p "$fx/bin" "$fx/tests" "$fx/docs/retros"
  cp "$LINT_SRC" "$fx/bin/check-config-drift.sh"
  : > "$fx/tests/config-drift-allowlist.txt"
  cat > "$fx/pipeline.config.example" <<'EOF'
PIPELINE_SYNTH_DOCS_ONLY=""
EOF
  cat > "$fx/docs/guide.md" <<'EOF'
The documented knob is PIPELINE_SYNTH_DOCS_ONLY.
EOF
  cat > "$fx/docs/retros/evidence.md" <<'EOF'
Cycle evidence: this retro quotes PIPELINE_SYNTH_RETRO_ONLY verbatim.
EOF
  printf '%s' "$fx"
}

# run_lint <outfile-prefix> <args...> -> sets RC; writes .out/.err
run_lint() {
  local prefix="$1"; shift
  env -u PIPELINE_CONFIG_DRIFT_ALLOWLIST bash "$@" >"$prefix.out" 2>"$prefix.err"
  RC=$?
}

# ---------------------------------------------------------------------------
scenario "Sub-case 1: DEFAULT scan skips docs/retros/"
# ---------------------------------------------------------------------------
FX="$(mkfx)"
run_lint "$TMP/c1" "$FX/bin/check-config-drift.sh"
OUT="$(cat "$TMP/c1.out")"
BOTH="$(cat "$TMP/c1.out" "$TMP/c1.err")"
if [ "$RC" -eq 0 ]; then
  pass_msg "default run exits 0 with a retro-only token present"
else
  fail_msg "expected rc=0, got rc=$RC; err=$(cat "$TMP/c1.err")"
fi
if [ "$OUT" = "check-config-drift: ok" ]; then
  pass_msg "stdout is exactly 'check-config-drift: ok'"
else
  fail_msg "stdout is not exactly 'check-config-drift: ok' (got: $OUT)"
fi
if printf '%s\n' "$BOTH" | grep -qF 'PIPELINE_SYNTH_RETRO_ONLY'; then
  fail_msg "output names PIPELINE_SYNTH_RETRO_ONLY — retro prose was still counted as a reference"
else
  pass_msg "output never names PIPELINE_SYNTH_RETRO_ONLY"
fi

# ---------------------------------------------------------------------------
scenario "Sub-case 2: non-vacuity control — the rest of docs/ is still scanned"
# ---------------------------------------------------------------------------
FX="$(mkfx)"
cat >> "$FX/docs/guide.md" <<'EOF'
An undeclared knob outside retros: PIPELINE_SYNTH_UNDOC.
EOF
run_lint "$TMP/c2" "$FX/bin/check-config-drift.sh"
BOTH="$(cat "$TMP/c2.out" "$TMP/c2.err")"
if [ "$RC" -eq 1 ]; then
  pass_msg "default run exits 1 for an undeclared token in docs/ outside retros/"
else
  fail_msg "expected rc=1, got rc=$RC; out=$(cat "$TMP/c2.out") err=$(cat "$TMP/c2.err")"
fi
if printf '%s\n' "$BOTH" | grep -qF 'PIPELINE_SYNTH_UNDOC'; then
  pass_msg "the finding names PIPELINE_SYNTH_UNDOC — sub-case 1 is not passing because the whole tree was skipped"
else
  fail_msg "expected PIPELINE_SYNTH_UNDOC to be named; out=$(cat "$TMP/c2.out") err=$(cat "$TMP/c2.err")"
fi

# ---------------------------------------------------------------------------
scenario "Sub-case 3: an EXPLICIT positional dir still scans the retros subtree"
# ---------------------------------------------------------------------------
FX="$(mkfx)"
run_lint "$TMP/c3" "$FX/bin/check-config-drift.sh" "$FX/pipeline.config.example" "$FX/docs"
if [ "$RC" -eq 1 ]; then
  pass_msg "positional run exits 1 (behaviour unchanged)"
else
  fail_msg "expected rc=1 on the positional run, got rc=$RC; out=$(cat "$TMP/c3.out") err=$(cat "$TMP/c3.err")"
fi
if grep -q '^UNDOCUMENTED' "$TMP/c3.err" && grep -qF 'PIPELINE_SYNTH_RETRO_ONLY' "$TMP/c3.err"; then
  pass_msg "UNDOCUMENTED group names PIPELINE_SYNTH_RETRO_ONLY — the explicit-dir escape hatch still reads retro prose"
else
  fail_msg "expected UNDOCUMENTED naming PIPELINE_SYNTH_RETRO_ONLY; err=$(cat "$TMP/c3.err")"
fi

# ---------------------------------------------------------------------------
scenario "Sub-case 4: declared-and-retro-only flips to ORPHAN, not silence"
# ---------------------------------------------------------------------------
FX="$(mkfx)"
cat >> "$FX/pipeline.config.example" <<'EOF'
PIPELINE_SYNTH_DECLARED_RETRO=""
EOF
cat >> "$FX/docs/retros/evidence.md" <<'EOF'
The cycle also touched PIPELINE_SYNTH_DECLARED_RETRO.
EOF
run_lint "$TMP/c4" "$FX/bin/check-config-drift.sh"
if [ "$RC" -eq 1 ]; then
  pass_msg "default run exits 1 for a declared knob referenced only from retro prose"
else
  fail_msg "expected rc=1, got rc=$RC; out=$(cat "$TMP/c4.out") err=$(cat "$TMP/c4.err")"
fi
if grep -q '^ORPHAN' "$TMP/c4.err" && grep -qF 'PIPELINE_SYNTH_DECLARED_RETRO' "$TMP/c4.err"; then
  pass_msg "ORPHAN group names PIPELINE_SYNTH_DECLARED_RETRO — the knob surfaces instead of vanishing"
else
  fail_msg "expected an ORPHAN group naming PIPELINE_SYNTH_DECLARED_RETRO; err=$(cat "$TMP/c4.err")"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
