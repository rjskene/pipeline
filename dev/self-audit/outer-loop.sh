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
    # Per-digest list of Suggested default text (one per line, trimmed).
    grep -E '^- \*\*Suggested default:\*\*' "$OUT_DIR/$d" 2>/dev/null \
      | sed 's/^- \*\*Suggested default:\*\* *//' \
      | sort -u > "$TMP/def-$i.txt" || true
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

  # 2-of-3 Suggested-default detector (MVP: exact-string match).
  # Future upgrade per issue #135: token-set Jaccard >= 0.7.
  DEFAULT_HITS="$TMP/default-hits.txt"; : > "$DEFAULT_HITS"
  if [ "$i" -ge 2 ]; then
    cat "$TMP"/def-*.txt 2>/dev/null | sort | uniq -c | awk '$1 >= 2 {
      $1=""; sub(/^[ \t]+/, ""); print
    }' > "$DEFAULT_HITS"
  fi
  if [ -s "$DEFAULT_HITS" ]; then
    cat <<'MD'

**Repeating Suggested defaults (codification candidates):**

MD
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      echo "- $d"
      echo "  - **Codification target:** Claude memory (\`feedback_*.md\` under \`MEMORY.md\`) OR skill prose (\`skills/<name>/SKILL.md\`) — user choice."
    done < "$DEFAULT_HITS"
  fi

  if [ -s "$DEFAULT_HITS" ]; then
    cat <<'MD'

## Suggested issues

Candidate issues drafted from the repeating Suggested defaults above. **Read-only**: the user copies these into `/pipeline:create-issues` for Socratic refinement and filing. Do NOT auto-file.

MD
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      lower=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
      scope="self-improve"
      case "$lower" in
        *skills/run/*|*pipeline:run*) scope="run" ;;
        *classify-issue*)             scope="classify-issue" ;;
        *evaluate-issue-pr*|*evaluate-issue-plan*) scope="evaluate" ;;
        *execute-issue-plan*)         scope="execute" ;;
        *create-issues*)              scope="create-issues" ;;
        *plan-issue*)                 scope="plan-issue" ;;
        *pipeline.config*)            scope="config" ;;
        *hooks/*|*hook*)              scope="hooks" ;;
        *scripts/*)                   scope="scripts" ;;
      esac
      ctype="feat"
      case "$lower" in
        *prevent*|*skip*|*avoid*|*stop*|*block*) ctype="fix" ;;
        *cleanup*|*hygiene*|*refactor*)          ctype="chore" ;;
      esac
      summary=$(printf '%s' "$d" | sed 's/\.$//')
      first=$(printf '%s' "$summary" | cut -c1 | tr '[:upper:]' '[:lower:]')
      rest=$(printf '%s' "$summary" | cut -c2-)
      summary="$first$rest"
      if [ "${#summary}" -gt 72 ]; then
        summary=$(printf '%s' "$summary" | cut -c1-72 | sed 's/ [^ ]*$//')
      fi
      label="none"
      case "$lower" in
        *explore*|*consider*|*"should we"*|*maybe*|*\?*) label="brainstorm" ;;
      esac
      echo "- **Title:** ${ctype}(${scope}): ${summary}"
      echo "  - **Body:** Observed across the audit window — outer-loop detected this Suggested default repeating in 2 of the last ${WINDOW} inner digests. Codification target: ${scope}."
      echo "  - **Label hint:** ${label}"
      echo "  - **From Suggested default:** ${d}"
    done < "$DEFAULT_HITS"
  fi

  cat <<'MD'

## Read-only

This digest is observation-only. To act on a finding, file an issue with `brainstorm` (or skip straight to a planned issue) — do NOT auto-modify any surface.
MD
} > "$OUT_FILE"

exit 0
