#!/usr/bin/env bash
# outer-loop.sh — cross-run consistency detector. Reads the last N=3 inner
# digests from index.jsonl; for each compliance/interaction/efficiency
# signal that appears in all 3, emits a pattern finding with a candidate
# codification target. PLUGIN SURFACES ONLY — never Claude memory.
#
# Env knobs:
#   AUDIT_OUT_DIR        — default: dev/audits/
#   AUDIT_OUTER_WINDOW   — default 3
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUT_DIR="${AUDIT_OUT_DIR:-$REPO_ROOT/dev/audits}"
WINDOW="${AUDIT_OUTER_WINDOW:-3}"
INDEX="$OUT_DIR/index.jsonl"

[ -s "$INDEX" ] || { echo "no inner runs yet" >&2; exit 0; }

DIGESTS=$(tail -n "$WINDOW" "$INDEX" | jq -r '.digest')
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUT_FILE="$OUT_DIR/outer-${NOW_ISO//:/}.md"

{
  cat <<MD
# Outer audit — $NOW_ISO

**Window:** last $WINDOW inner runs
**Inputs:**
MD
  while IFS= read -r d; do
    [ -n "$d" ] && echo "- $d"
  done <<< "$DIGESTS"

  cat <<'MD'

## Cross-run consistency

A signal is a **pattern** when it appears in EVERY run in the window. Single-run signals are noise.

MD

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT INT TERM
  i=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    i=$((i+1))
    grep -E '^- (SIGNAL|signal|turn_count|tdd_|wave_)' "$OUT_DIR/$d" \
      | sort -u > "$TMP/sig-$i.txt" 2>/dev/null || true
  done <<< "$DIGESTS"

  INTERSECT="$TMP/intersect.txt"
  if [ "$i" -ge 2 ]; then
    cp "$TMP/sig-1.txt" "$INTERSECT"
    j=2
    while [ "$j" -le "$i" ]; do
      comm -12 "$INTERSECT" <(sort -u "$TMP/sig-$j.txt") > "$TMP/intersect.next"
      mv "$TMP/intersect.next" "$INTERSECT"
      j=$((j+1))
    done
  else
    cp "$TMP/sig-1.txt" "$INTERSECT" 2>/dev/null || true
  fi

  if [ -s "$INTERSECT" ]; then
    cat <<'MD'
**Patterns detected (consistent across all runs):**

MD
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      echo "$line"
      target="skills/run/SKILL.md prose (orchestrator-side discipline)"
      case "$line" in
        *TDD*|*tdd_*) target="skills/execute-issue-plan/SKILL.md prose + hooks/ (e.g. enforce-tdd-order)" ;;
        *wave_*)      target="skills/run/SKILL.md prose (wave-prioritization)" ;;
        *turn_count*) target="pipeline.config.example tuning (verbose-mode default) OR skill prose" ;;
        *PATH-*|*path-tier*) target="scripts/spawn-claude.sh (dispatch routing)" ;;
      esac
      echo "  - **Codification target:** $target"
      echo "  - **Out of scope:** local-machine personal state (does not propagate to consumers)."
    done < "$INTERSECT"
  else
    echo "No consistent cross-run patterns detected in this window."
  fi

  cat <<'MD'

## Read-only

This digest is observation-only. To act on a finding, file an issue with `brainstorm` (or skip straight to a planned issue) — do NOT auto-modify any surface.
MD
} > "$OUT_FILE"

exit 0
