#!/bin/bash
set -uo pipefail

# audit-compliance.sh — dogfood-only Compliance Audit sub-block emitter.
#
# Reads PR commits + files + issue labels, derives PATH letter, checks for a
# TDD red→green git signature, prints a `## Compliance Audit` table to stdout,
# and (in non-dry-run mode) posts it to the PR via `gh pr comment`.
#
# Squash-merge before push can hide red→green history — v0 accepts this
# misreport. Strict commit-ordering enforcement is tracked in #418.
#
# Usage: audit-compliance.sh <issue> <pr> [--dry-run]
#                            [--files-json F] [--commits-json F] [--labels-json F]

ISSUE=""
PR=""
DRY_RUN=0
FILES_JSON=""
COMMITS_JSON=""
LABELS_JSON=""

positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --files-json) FILES_JSON="$2"; shift 2 ;;
    --commits-json) COMMITS_JSON="$2"; shift 2 ;;
    --labels-json) LABELS_JSON="$2"; shift 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done

ISSUE="${positional[0]:-}"
PR="${positional[1]:-}"

# Source/test classification — kept as top-of-file vars so v1 (#418) can swap them.
SRC_EXT_RE='\.(py|ts|tsx|js|jsx|sh|go|rs|rb)$'
TEST_PATH_RE='(test|spec|^tests/|^spec/)'

_is_source_file() {
  local f="$1"
  if printf '%s' "$f" | grep -Eq "$SRC_EXT_RE"; then
    if printf '%s' "$f" | grep -Eq "$TEST_PATH_RE"; then
      return 1
    fi
    return 0
  fi
  return 1
}

_is_test_file() {
  local f="$1"
  if printf '%s' "$f" | grep -Eq "$SRC_EXT_RE"; then
    if printf '%s' "$f" | grep -Eq "$TEST_PATH_RE"; then
      return 0
    fi
  fi
  return 1
}

# --- Read injected JSON (v0: only injection path is implemented; live gh
# fallback is wired in a follow-up task once injection contract is stable).
LABELS_BODY="$(cat "$LABELS_JSON")"
FILES_BODY="$(cat "$FILES_JSON")"
COMMITS_BODY="$(cat "$COMMITS_JSON")"

# Derive PATH letter from labels.
PATH_LETTER="B"
if echo "$LABELS_BODY" | jq -e '.[] | select(.name=="docs-only")' >/dev/null 2>&1; then
  PATH_LETTER="A"
elif echo "$LABELS_BODY" | jq -e '.[] | select(.name=="quick-fix")' >/dev/null 2>&1; then
  PATH_LETTER="D"
elif echo "$LABELS_BODY" | jq -e '.[] | select(.name=="multi-task")' >/dev/null 2>&1; then
  PATH_LETTER="C"
fi

# Count source files in PR.
SRC_COUNT=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if _is_source_file "$f"; then
    SRC_COUNT=$((SRC_COUNT + 1))
  fi
done < <(echo "$FILES_BODY" | jq -r '.[]')

# Count commits touching at least one test file.
TEST_COMMIT_COUNT=0
while IFS= read -r cfiles; do
  [ -z "$cfiles" ] && continue
  hit=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if _is_test_file "$f"; then hit=1; break; fi
  done < <(echo "$cfiles" | jq -r '.[]')
  if [ "$hit" = "1" ]; then
    TEST_COMMIT_COUNT=$((TEST_COMMIT_COUNT + 1))
  fi
done < <(echo "$COMMITS_BODY" | jq -c '.[].files')

# Decide TDD verdict + detected-string. PATH A (docs-only) skips the TDD
# expectation entirely; the row is omitted from the table.
EMIT_TDD_ROW=1
TDD_DETECTED="no test files in commits"
TDD_VERDICT="SKIP"
if [ "$PATH_LETTER" = "A" ]; then
  EMIT_TDD_ROW=0
elif [ "$TEST_COMMIT_COUNT" -gt 0 ]; then
  TDD_DETECTED="test file committed before/with source"
  TDD_VERDICT="PASS"
fi

# Compose aggregate.
SKIPPED=()
if [ "$EMIT_TDD_ROW" = "1" ] && [ "$TDD_VERDICT" = "SKIP" ]; then
  SKIPPED+=("TDD")
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  AGGREGATE="Non-compliant (skipped: $(IFS=, ; echo "${SKIPPED[*]}"))"
else
  AGGREGATE="Compliant"
fi

# Render table.
ROWS=""
if [ "$EMIT_TDD_ROW" = "1" ]; then
  ROWS+="| TDD   | yes (PATH ${PATH_LETTER}) | ${TDD_DETECTED} | ${TDD_VERDICT} |"$'\n'
fi

TABLE="$(cat <<EOF
## Compliance Audit

| Skill | Expected | Detected | Verdict |
| ----- | -------- | -------- | ------- |
${ROWS}
Aggregate: ${AGGREGATE}
EOF
)"

echo "$TABLE"

if [ "$DRY_RUN" = "0" ]; then
  echo "$TABLE" | gh pr comment "$PR" --body-file -
fi
