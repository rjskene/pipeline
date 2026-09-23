#!/bin/bash
set -uo pipefail
#
# evolve-diminishing.sh — diminishing-returns kill switch (#1397).
#
# The diminishing-returns kill switch used to be prose only
# (skills/evolve/SKILL.md Step 7: "two verdict lines and neither contains
# `confirmed` -> pause"), with no script, no test, and no notion of it in
# scripts/evolve-loop.sh, so the wrapper kept relaunching whatever the
# verdicts said. This is the coded switch both the skill fence and the
# wrapper call.
#
# CLI: evolve-diminishing.sh --tracker N [--comments-file PATH] [--help]
#
# Walks the trusted comment stream tracking the current cycle from
# `^## Cycle <N>`; records `<cycle> <line>` for every `^- verdicts:` line;
# keeps the LAST TWO records. Fires when exactly two records exist AND
# neither line contains the fixed string `confirmed`: prints
# `DIMINISHING cycles=<older>,<newer>` on stdout, exit 3. The cycle LABEL
# degrades to `--` when no `## Cycle` heading precedes the line; the
# fire/no-fire decision never degrades.
#
# Exit codes: 0 clean/fail-open (empty stream, failed read, fewer than two
#             records) · 1 usage error (no --tracker and no --comments-file)
#             · 3 DIMINISHING (RESERVED for the kill-switch signal — a usage
#             error must never masquerade as a positive detection).
#
# `--comments-file` is a TEST-ONLY seam (mirrors scripts/evolve-projection.sh
# --comments-file). `--tracker` is the sole production route and always goes
# through filter-trusted-comments.sh — hooks/enforce-comment-trust.py denies
# a raw `gh issue view` call for comment bodies.

print_usage() {
  cat <<'USAGE'
Usage: evolve-diminishing.sh --tracker N [--comments-file PATH] [--help]

  evolve-diminishing.sh — diminishing-returns kill switch (#1397).

  Keeps the last two tracker `- verdicts:` lines (labelled by the nearest
  preceding `## Cycle <N>` heading, `--` when none precedes) and fires when
  neither of those two lines contains the fixed string `confirmed`: prints
  `DIMINISHING cycles=<older>,<newer>` and exits 3. Fail-open on an
  empty/short/unreadable stream (exit 0).

  --tracker N          Tracker issue number (production route: reads trusted
                        comments via filter-trusted-comments.sh; requires
                        PIPELINE_REPO in the environment).
  --comments-file PATH TEST-ONLY seam: read comments from a local file
                        instead of gh/filter-trusted-comments.sh.
  --help               Print this banner and exit 0.

Exit codes: 0 clean/fail-open · 1 usage error · 3 DIMINISHING (reserved).
USAGE
}

TRACKER=""
COMMENTS_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)          print_usage; exit 0 ;;
    --tracker)          TRACKER="${2:-}"; shift 2 2>/dev/null || shift ;;
    --tracker=*)        TRACKER="${1#--tracker=}"; shift ;;
    --comments-file)    COMMENTS_FILE="${2:-}"; shift 2 2>/dev/null || shift ;;
    --comments-file=*)  COMMENTS_FILE="${1#--comments-file=}"; shift ;;
    *)
      echo "evolve-diminishing: WARN: unknown arg: $1 (ignored)" >&2
      shift
      ;;
  esac
done

if [ -z "$TRACKER" ] && [ -z "$COMMENTS_FILE" ]; then
  echo "Usage: evolve-diminishing.sh --tracker N [--comments-file PATH]" >&2
  exit 1
fi

SELF_DIR="$(dirname "$0")"

# --- 1. read comments. --comments-file is TEST-ONLY; --tracker is the sole
#        production route (always through filter-trusted-comments.sh) -------
if [ -n "$COMMENTS_FILE" ]; then
  COMMENTS="$(cat "$COMMENTS_FILE" 2>/dev/null || true)"
else
  COMMENTS="$(bash "$SELF_DIR/filter-trusted-comments.sh" "$TRACKER" 2>/dev/null || true)"
fi

# --- 2. walk the stream: track the current cycle, record the last two
#        `- verdicts:` lines as "<cycle>\t<line>" ---------------------------
RECORDS="$(printf '%s\n' "$COMMENTS" | awk '
  /^## Cycle [0-9]+/ { cyc=$0; sub(/^## Cycle /,"",cyc); sub(/[^0-9].*/,"",cyc); next }
  /^- verdicts:/ { print (cyc == "" ? "--" : cyc) "\t" $0 }
' | tail -2)"

COUNT="$(printf '%s\n' "$RECORDS" | grep -c . || true)"
if [ "${COUNT:-0}" -ne 2 ]; then
  exit 0
fi

OLDER_CYCLE="$(sed -n '1p' <<<"$RECORDS" | cut -f1)"
NEWER_CYCLE="$(sed -n '2p' <<<"$RECORDS" | cut -f1)"
OLDER_LINE="$(sed -n '1p' <<<"$RECORDS" | cut -f2-)"
NEWER_LINE="$(sed -n '2p' <<<"$RECORDS" | cut -f2-)"

if printf '%s' "$OLDER_LINE" | grep -qF 'confirmed'; then exit 0; fi
if printf '%s' "$NEWER_LINE" | grep -qF 'confirmed'; then exit 0; fi

echo "DIMINISHING cycles=${OLDER_CYCLE},${NEWER_CYCLE}"
exit 3
