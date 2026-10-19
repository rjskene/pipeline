#!/usr/bin/env bash
# plan-issue-classify.sh — the classification procedure's shell steps
# (skills/plan-issue/references/classification.md), one subcommand per step.
# The BEGIN-/END- sentinel blocks below are the reference's former fence bodies,
# moved as top-level statements so tests can extract and run them standalone.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: plan-issue-classify.sh <subcommand> [args]

  freshness <N>                    CLASS_FRESH=true|false, CACHED_PATH=<A-D or empty>
  marker                           MARKER_PATH=<A-D or empty> from $ISSUE_BODY
  hint                             HINT_PATH=<A|B|C or empty> from $ISSUE_BODY
  decide <N> [--table A|B|C|D]     freshness + marker + hint, then
                                   PATH_LETTER=<A-D>, PATH_SOURCE=<marker|cached|label|table|hint|default>
  label-apply <N> <A|B|C|D>        reconcile the docs-only/multi-task/quick-fix label
                                   (remove first, add second; any other label is REFUSED)
  verify-post <N>                  CLASS_COUNT=<n>; exit 1 when 0

Env (each fetched when unset; a set value wins): TRUSTED (filter-trusted-comments.sh <N>),
ISSUE_BODY, CURRENT_LABELS (newline-separated), CLASS_FRESH/CACHED_PATH (decide only).
Required: PIPELINE_REPO. CLAUDE_PLUGIN_ROOT self-resolves from this script's location.
USAGE
}

SUB="${1:-}"
case "$SUB" in
  -h|--help) usage; exit 0 ;;
  freshness|marker|hint|decide|label-apply|verify-post) shift ;;
  *) usage >&2; exit 2 ;;
esac

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_resolve-config.sh
[ -f "$SELF_DIR/_resolve-config.sh" ] && source "$SELF_DIR/_resolve-config.sh"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
PIPELINE_REPO="${PIPELINE_REPO:-}"

N=""
TABLE_ARG=""
case "$SUB" in
  freshness|decide|label-apply|verify-post)
    N="${1:-}"
    [ -n "$N" ] || { usage >&2; exit 2; }
    shift ;;
esac
if [ "$SUB" = decide ] && [ "${1:-}" = "--table" ]; then TABLE_ARG="${2:-}"; fi
if [ "$SUB" = label-apply ]; then
  RECOMMENDED_PATH="${1:-}"
  case "$RECOMMENDED_PATH" in A|B|C|D) ;; *) usage >&2; exit 2 ;; esac
  ISSUE_N="$N"
fi

# Inputs: env wins when set, else fetched once.
if [ "$SUB" = freshness ] || { [ "$SUB" = decide ] && [ -z "${CLASS_FRESH:-}" ]; }; then
  [ -n "${TRUSTED+x}" ] || TRUSTED=$(bash "$SELF_DIR/filter-trusted-comments.sh" "$N" 2>/dev/null)
fi
case "$SUB" in
  marker|hint|decide)
    if [ -z "${ISSUE_BODY+x}" ]; then
      if [ -n "$N" ]; then ISSUE_BODY=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json body --jq .body); else ISSUE_BODY=""; fi
    fi ;;
esac
case "$SUB" in
  decide|label-apply)
    [ -n "${CURRENT_LABELS+x}" ] || CURRENT_LABELS=$(gh issue view "$N" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name') ;;
esac
[ -n "$TABLE_ARG" ] && TABLE_PATH="$TABLE_ARG"

if [ "$SUB" = freshness ] || { [ "$SUB" = decide ] && [ -z "${CLASS_FRESH:-}" ]; }; then
# BEGIN-CLASS-FRESHNESS
# Required env: TRUSTED (trusted working set). Prints CLASS_FRESH=true|false and CACHED_PATH=<A|B|C|D or empty>.
CLASS_FRESH=false; CACHED_PATH=""
# Freshness timestamp from TRUSTED Classification authors only (--json already hard-drops outsiders).
LATEST_CLASS_TS=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/filter-trusted-comments.sh" --json "$N" \
  | jq -r '[.comments[] | select((.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) and (.body | contains("## Classification")))] | max_by(.createdAt) | .createdAt // empty')
ISSUE_TS=$(gh issue view "$N" --repo $PIPELINE_REPO --json updatedAt --jq '.updatedAt')
# ISO-8601 sorts lexicographically; `>` is strict-greater so add an OR-equality clause to treat same-second as fresh.
if [[ -n "$LATEST_CLASS_TS" && ( "$LATEST_CLASS_TS" > "$ISSUE_TS" || "$LATEST_CLASS_TS" == "$ISSUE_TS" ) ]]; then
    CACHED_PATH=$(printf '%s\n' "$TRUSTED" \
      | grep -oE 'recommended_path:\*\* [ABCD]' | awk '{print $NF}' | tail -1)
    case "$CACHED_PATH" in A|B|C|D) CLASS_FRESH=true ;; *) CACHED_PATH="" ;; esac
fi
echo "CLASS_FRESH=$CLASS_FRESH"
echo "CACHED_PATH=$CACHED_PATH"
# END-CLASS-FRESHNESS
fi

if [ "$SUB" = marker ] || [ "$SUB" = decide ]; then
# BEGIN-PATH-MARKER-PARSE
# Required env: ISSUE_BODY (issue body markdown, may be multi-line), CLAUDE_PLUGIN_ROOT.
# Sets: MARKER_PATH ("A"|"B"|"C"|"D" or empty string).
# Regex: <!--\s*pipeline:path=[A-Da-d]\s*--> (POSIX equivalent below).
MARKER_PATH=""
_raw=$(printf '%s\n' "$ISSUE_BODY" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/strip-code-spans.sh" \
  | grep -oE '<!--[[:space:]]*pipeline:path=[A-Za-z][[:space:]]*-->' \
  | head -1)
if [ -n "$_raw" ]; then
  _letter=$(printf '%s' "$_raw" \
    | grep -oE 'pipeline:path=[A-Za-z]' \
    | head -1 \
    | cut -d= -f2 \
    | tr 'a-z' 'A-Z')
  case "$_letter" in
    A|B|C|D) MARKER_PATH="$_letter" ;;
    *) MARKER_PATH="" ;;
  esac
fi
# END-PATH-MARKER-PARSE
  [ "$SUB" = marker ] && echo "MARKER_PATH=$MARKER_PATH"
fi

if [ "$SUB" = hint ] || [ "$SUB" = decide ]; then
  # Same one-command parse as the reference's PATH-HINT-PARSE fence (D/other => empty).
  HINT_PATH=$(printf '%s\n' "$ISSUE_BODY" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/strip-code-spans.sh" | grep -oE '<!--[[:space:]]*pipeline:path-hint=[A-Za-z][[:space:]]*-->' | head -1 | grep -oE '=[A-Za-z]' | tr -d '=' | tr 'a-z' 'A-Z' | grep -x '[ABC]' || true)
  [ "$SUB" = hint ] && echo "HINT_PATH=$HINT_PATH"
fi

if [ "$SUB" = decide ]; then
# BEGIN-PATH-DECIDE
# Required env: MARKER_PATH, HINT_PATH (3c/3d), CLASS_FRESH, CACHED_PATH (freshness check),
#   CURRENT_LABELS (newline-separated), TABLE_PATH (step-4 row that fired, or empty).
# Prints PATH_LETTER=<A|B|C|D> and PATH_SOURCE=<marker|cached|label|table|hint|default>.
_lbl()  { printf '%s\n' "${CURRENT_LABELS:-}" | grep -qx "${*}"; }
_abcd() { printf '%s\n' "${*}" | grep -qx '[ABCD]'; }
PATH_LETTER=B; PATH_SOURCE=default
if _abcd "${MARKER_PATH:-}"; then PATH_LETTER="$MARKER_PATH"; PATH_SOURCE=marker
elif [ "${CLASS_FRESH:-}" = true ] && _abcd "${CACHED_PATH:-}"; then PATH_LETTER="$CACHED_PATH"; PATH_SOURCE=cached
elif _lbl docs-only;  then PATH_LETTER=A; PATH_SOURCE=label
elif _lbl multi-task; then PATH_LETTER=C; PATH_SOURCE=label
elif _lbl quick-fix;  then PATH_LETTER=D; PATH_SOURCE=label
elif _abcd "${TABLE_PATH:-}"; then PATH_LETTER="$TABLE_PATH"; PATH_SOURCE=table
elif printf '%s\n' "${HINT_PATH:-}" | grep -qx '[ABC]'; then PATH_LETTER="$HINT_PATH"; PATH_SOURCE=hint
fi
echo "PATH_LETTER=$PATH_LETTER"
echo "PATH_SOURCE=$PATH_SOURCE"
# END-PATH-DECIDE
fi

if [ "$SUB" = label-apply ]; then
# BEGIN-LABEL-APPLY
# Required env: ISSUE_N (issue number), RECOMMENDED_PATH (A|B|C|D),
#   CURRENT_LABELS (newline-separated label names), REPO (owner/name).
REPO="${REPO:-$PIPELINE_REPO}"
_has_label() { printf '%s\n' "$CURRENT_LABELS" | grep -qx "${*}"; }
_safe_label() {
  # Guardrail: this skill may only edit the three path labels.
  case "${*}" in
    docs-only|multi-task|quick-fix) return 0 ;;
    *) echo "REFUSED: label '${*}' not in allow-set {docs-only|multi-task|quick-fix}" >&2; return 1 ;;
  esac
}
current_a=0; current_c=0; current_d=0
_has_label docs-only  && current_a=1
_has_label multi-task && current_c=1
_has_label quick-fix  && current_d=1
desired_a=0; desired_c=0; desired_d=0
case "$RECOMMENDED_PATH" in A) desired_a=1 ;; C) desired_c=1 ;; D) desired_d=1 ;; esac
# Remove first, add second — avoids any momentary both-labels-present state
# that could trip a hook checking label invariants.
if [ "$current_a" -eq 1 ] && [ "$desired_a" -eq 0 ]; then
  _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label docs-only
fi
if [ "$current_c" -eq 1 ] && [ "$desired_c" -eq 0 ]; then
  _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label multi-task
fi
if [ "$current_d" -eq 1 ] && [ "$desired_d" -eq 0 ]; then
  _safe_label quick-fix  && gh issue edit "$ISSUE_N" --repo "$REPO" --remove-label quick-fix
fi
if [ "$desired_a" -eq 1 ] && [ "$current_a" -eq 0 ]; then
  _safe_label docs-only  && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    docs-only
fi
if [ "$desired_c" -eq 1 ] && [ "$current_c" -eq 0 ]; then
  _safe_label multi-task && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    multi-task
fi
if [ "$desired_d" -eq 1 ] && [ "$current_d" -eq 0 ]; then
  _safe_label quick-fix  && gh issue edit "$ISSUE_N" --repo "$REPO" --add-label    quick-fix
fi
# END-LABEL-APPLY
fi

if [ "$SUB" = verify-post ]; then
  CLASS_COUNT=$(bash "$SELF_DIR/filter-trusted-comments.sh" --json "$N" \
    | jq '[.comments[] | select(.body | contains("## Classification"))] | length')
  echo "CLASS_COUNT=${CLASS_COUNT:-0}"
  [ "${CLASS_COUNT:-0}" -gt 0 ] || exit 1
fi
exit 0
