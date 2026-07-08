#!/bin/bash
set -uo pipefail

# audit-compliance.sh — dogfood-only Compliance Audit sub-block emitter.
#
# Reads PR commits + files + issue labels via injected JSON files, derives
# the PATH letter, checks for a TDD red→green git signature, prints a
# `## Compliance Audit` table to stdout, and (in non-dry-run mode) posts it
# to the PR via `gh pr comment`.
#
# v0 status: ALL THREE injection flags (--files-json, --commits-json,
# --labels-json) are required. The live `gh pr view` / `gh issue view`
# fallback is deferred to v1 (#418); invoking without the injection flags
# hard-fails with rc=3 rather than silently emitting a misleading audit.
#
# Commit ORDERING is now enforced (#640/#418): the verdict is test-first
# (PASS) / test-after (WEAK) / no-test (SKIP) / no-source (N/A), derived
# from the chronological commit-array order. The #459 merge-commit
# migration preserves per-PR sub-commit history, so red->green ordering is
# observable on already-merged PRs.
#
# Usage: audit-compliance.sh <issue> <pr> [--dry-run]
#                            --files-json F --commits-json F --labels-json F

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

if [ -z "$ISSUE" ] || [ -z "$PR" ]; then
  echo "Usage: audit-compliance.sh <issue> <pr> [--dry-run] [--files-json F] [--commits-json F] [--labels-json F]" >&2
  exit 2
fi

missing=()
[ -z "$FILES_JSON" ]   && missing+=("--files-json")
[ -z "$COMMITS_JSON" ] && missing+=("--commits-json")
[ -z "$LABELS_JSON" ]  && missing+=("--labels-json")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "audit-compliance.sh: v0 requires all three injection flags; missing: ${missing[*]}" >&2
  echo "  Live gh fallback is tracked by #418; pass JSON files for now." >&2
  exit 3
fi

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
done < <(echo "$FILES_BODY" | jq -r '.[]' | tr -d '\r')

# Derive commit ordering. The commits array is in chronological commit order
# (the live load_pr_commits join in compliance-backfill.sh walks
# repos/{repo}/pulls/{n}/commits, which is topo/chrono ordered). Record the
# index of the FIRST commit touching any source file and the FIRST touching
# any test file.
FIRST_SRC_IDX=-1
FIRST_TEST_IDX=-1
idx=0
while IFS= read -r cfiles; do
  [ -z "$cfiles" ] && { idx=$((idx + 1)); continue; }
  shit=0
  thit=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [ "$shit" = "0" ] && _is_source_file "$f"; then shit=1; fi
    if [ "$thit" = "0" ] && _is_test_file "$f"; then thit=1; fi
  done < <(echo "$cfiles" | jq -r '.[]' | tr -d '\r')
  if [ "$shit" = "1" ] && [ "$FIRST_SRC_IDX" = "-1" ]; then FIRST_SRC_IDX=$idx; fi
  if [ "$thit" = "1" ] && [ "$FIRST_TEST_IDX" = "-1" ]; then FIRST_TEST_IDX=$idx; fi
  idx=$((idx + 1))
done < <(echo "$COMMITS_BODY" | jq -c '.[].files')

# Decide TDD verdict + detected-string. PATH A (docs-only) skips the TDD
# expectation entirely; the row is omitted from the table. No source changed
# => N/A. Else classify by commit ordering: test-index <= source-index is
# test-first (PASS); test-index > source-index is test-after (WEAK); no test
# commit at all is SKIP.
EMIT_TDD_ROW=1
TDD_DETECTED="no test files in commits"
TDD_VERDICT="SKIP"
if [ "$PATH_LETTER" = "A" ]; then
  EMIT_TDD_ROW=0
elif [ "$SRC_COUNT" = "0" ]; then
  TDD_DETECTED="n/a (no source changes)"
  TDD_VERDICT="N/A"
elif [ "$FIRST_TEST_IDX" = "-1" ]; then
  TDD_DETECTED="no test files in commits"
  TDD_VERDICT="SKIP"
elif [ "$FIRST_SRC_IDX" = "-1" ] || [ "$FIRST_TEST_IDX" -le "$FIRST_SRC_IDX" ]; then
  TDD_DETECTED="test committed before/with source (test-first)"
  TDD_VERDICT="PASS"
else
  TDD_DETECTED="test committed after source (test-after)"
  TDD_VERDICT="WEAK"
fi

# Compose aggregate. SKIP dominates (non-compliant); WEAK surfaces distinctly
# as a compliant-but-weak signal; otherwise fully compliant.
SKIPPED=()
WEAKED=()
if [ "$EMIT_TDD_ROW" = "1" ] && [ "$TDD_VERDICT" = "SKIP" ]; then
  SKIPPED+=("TDD")
fi
if [ "$EMIT_TDD_ROW" = "1" ] && [ "$TDD_VERDICT" = "WEAK" ]; then
  WEAKED+=("TDD")
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  AGGREGATE="Non-compliant (skipped: $(IFS=, ; echo "${SKIPPED[*]}"))"
elif [ "${#WEAKED[@]}" -gt 0 ]; then
  AGGREGATE="Compliant (weak: $(IFS=, ; echo "${WEAKED[*]}"))"
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
