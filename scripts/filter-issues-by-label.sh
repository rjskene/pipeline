#!/bin/bash
# filter-issues-by-label.sh — hermetic label filter over the /pipeline:status
# issues.json payload (#1269).
#
# Usage:
#   filter-issues-by-label.sh --issues <issues.json> \
#                             [--label <name>]... \
#                             [--emit issues|trackers]
#
# Semantics:
#   * Repeated `--label` is a UNION (OR) — an issue carrying ANY of the
#     requested labels survives. This deliberately DIFFERS from
#     `gh issue list --label a --label b`, which is an AND/intersection.
#   * Label matching is EXACT STRING EQUALITY (jq `index($n)`), never
#     `test()`/regex — real label names carry `:` and spaces
#     (`autorelease: pending`) that a regex would mangle.
#   * Tracker issues (label `tracker`) are CHILD-DRIVEN: a tracker survives
#     iff >= 1 of its `## Rollout sequence` children (default-mode
#     scripts/parse-tracker-children.sh, NEVER --fallback-mentions) survives
#     the filter. The tracker's OWN labels do not keep it.
#   * Zero `--label` args → identity passthrough: the input is emitted
#     unchanged (`--emit issues`), or every tracker number is listed
#     (`--emit trackers`).
#   * Zero matches (labels given, nothing survives) → stdout `[]`
#     (`--emit issues`), exit 0, plus a WARN naming the requested labels on
#     stderr.
#
# --emit issues (default) prints the filtered issue array (JSON) to stdout.
# --emit trackers prints the surviving tracker numbers, space-separated, to
# stdout.
#
# Exit codes: 0 success, 2 usage/argv error.

set -uo pipefail

usage() {
  cat >&2 <<USAGE
usage: filter-issues-by-label.sh --issues <issues.json>
                                 [--label <name>]...
                                 [--emit issues|trackers]
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve parse-tracker-children.sh the same way render-status-table.sh does:
# prefer ${CLAUDE_PLUGIN_ROOT} (consumer install), fall back to the dogfood
# checkout sibling path.
PARSE_CHILDREN="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}/scripts/parse-tracker-children.sh"
[ -x "$PARSE_CHILDREN" ] || PARSE_CHILDREN="$SCRIPT_DIR/parse-tracker-children.sh"

# CRLF-jq boundary hardening (#1158). Git-for-Windows jq (msvcrt text-mode)
# terminates every output line with \r\n; command substitution strips the
# trailing \n but leaves the \r, poisoning any jq->shell boundary (the
# --emit trackers `for` loop downstream in SKILL.md is exactly that seam).
# Route ALL jq output through this wrapper so an LF-only Linux jq (a no-op
# for `tr -d '\r'`) and a CRLF-emitting jq both behave the same.
jqr() { jq "$@" | tr -d '\r'; }

ISSUES_FILE=""
LABELS=()
EMIT="issues"

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --issues) ISSUES_FILE="${2:-}"; shift 2 ;;
    --label)  LABELS+=("${2:-}"); shift 2 ;;
    --emit)   EMIT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "filter-issues-by-label.sh: unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$ISSUES_FILE" ]; then
  echo "filter-issues-by-label.sh: --issues is required" >&2
  usage
  exit 2
fi

# Accept regular files AND bash process substitutions (/dev/fd/N) — use `-r`
# (readable) instead of `-f` (regular file), mirroring render-status-table.sh.
if [ ! -r "$ISSUES_FILE" ]; then
  echo "filter-issues-by-label.sh: --issues file not found: $ISSUES_FILE" >&2
  exit 2
fi

case "$EMIT" in
  issues|trackers) ;;
  *)
    echo "filter-issues-by-label.sh: --emit must be 'issues' or 'trackers', got: $EMIT" >&2
    exit 2
    ;;
esac

# ----------------------------------------------------------------------
# Zero --label → identity passthrough
# ----------------------------------------------------------------------
if [ "${#LABELS[@]}" -eq 0 ]; then
  if [ "$EMIT" = "issues" ]; then
    cat "$ISSUES_FILE"
    exit 0
  else
    TRACKER_NUMS=$(jqr -r '
      [.[] | select([.labels[].name] | any(. == "tracker")) | .number] | sort | .[]
    ' "$ISSUES_FILE" | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')
    printf '%s\n' "$TRACKER_NUMS"
    exit 0
  fi
fi

# ----------------------------------------------------------------------
# Build the --argjson "want" array from the collected --label values.
# ----------------------------------------------------------------------
WANT_JSON=$(printf '%s\n' "${LABELS[@]}" | jqr -R '.' | jqr -s -c '.')

# Non-tracker issues that carry one of the requested labels (exact string
# equality only — never test()/regex).
NON_TRACKER_NUMBERS=$(jqr -c --argjson want "$WANT_JSON" '
  [.[] | select(([.labels[].name] | any(. == "tracker")) | not)
       | select([.labels[].name] | any(. as $n | $want | index($n)))
       | .number]
' "$ISSUES_FILE")

# ALL issues (tracker or not) that carry one of the requested labels — used
# ONLY to test whether a tracker's CHILD survives the filter. A tracker's
# OWN matching label is irrelevant to whether the tracker itself is kept
# (that is child-driven, below); this set is about the child's labels.
ALL_MATCHED_NUMBERS=$(jqr -c --argjson want "$WANT_JSON" '
  [.[] | select([.labels[].name] | any(. as $n | $want | index($n))) | .number]
' "$ISSUES_FILE")

# ----------------------------------------------------------------------
# Tracker survival: child-driven. A tracker survives iff >= 1 of its
# `## Rollout sequence` children (parsed via the shared, DEFAULT-mode
# parse-tracker-children.sh — never --fallback-mentions) is present in
# ALL_MATCHED_NUMBERS.
# ----------------------------------------------------------------------
KEPT_TRACKERS=()
while IFS= read -r tnum; do
  [ -z "$tnum" ] && continue

  has_body=$(jqr -r --argjson n "$tnum" '.[] | select(.number == $n) | has("body")' "$ISSUES_FILE")
  if [ "$has_body" != "true" ]; then
    echo "filter-issues-by-label.sh: WARN: tracker #$tnum has no .body — cannot evaluate the tracker rule" >&2
  fi

  body=$(jqr -r --argjson n "$tnum" '.[] | select(.number == $n) | (.body // "")' "$ISSUES_FILE")
  children=$(printf '%s' "$body" | bash "$PARSE_CHILDREN" -)

  survives=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if printf '%s' "$ALL_MATCHED_NUMBERS" | jqr -e --argjson c "$c" 'index($c) != null' >/dev/null 2>&1; then
      survives=1
      break
    fi
  done <<< "$children"

  if [ "$survives" -eq 1 ]; then
    KEPT_TRACKERS+=("$tnum")
  fi
done < <(jqr -r '[.[] | select([.labels[].name] | any(. == "tracker")) | .number] | sort | .[]' "$ISSUES_FILE")

if [ "$EMIT" = "trackers" ]; then
  if [ "${#KEPT_TRACKERS[@]}" -eq 0 ]; then
    echo "filter-issues-by-label.sh: WARN: no tracker survives labels: ${LABELS[*]}" >&2
    printf '\n'
  else
    printf '%s\n' "${KEPT_TRACKERS[*]}"
  fi
  exit 0
fi

# ----------------------------------------------------------------------
# --emit issues (default): non-tracker survivors UNION kept trackers,
# rendered in the ORIGINAL document order.
# ----------------------------------------------------------------------
if [ "${#KEPT_TRACKERS[@]}" -gt 0 ]; then
  KEPT_TRACKERS_JSON=$(printf '%s\n' "${KEPT_TRACKERS[@]}" | jqr -R 'tonumber' | jqr -s -c '.')
else
  KEPT_TRACKERS_JSON='[]'
fi

FINAL_NUMBERS=$(jqr -n --argjson a "$NON_TRACKER_NUMBERS" --argjson b "$KEPT_TRACKERS_JSON" '$a + $b')

OUTPUT=$(jqr -c --argjson keep "$FINAL_NUMBERS" '
  [.[] | select(.number as $n | $keep | index($n) != null)]
' "$ISSUES_FILE")

COUNT=$(printf '%s' "$OUTPUT" | jqr 'length')
if [ "$COUNT" -eq 0 ]; then
  echo "filter-issues-by-label.sh: WARN: no issues match labels: ${LABELS[*]}" >&2
fi

printf '%s\n' "$OUTPUT"
exit 0
