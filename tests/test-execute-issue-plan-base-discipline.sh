#!/usr/bin/env bash
# Test: execute-issue-plan SKILL.md Step 9b mandates quoted --base + non-empty guard.
#
# Three assertions:
#  (a) Quoted form --base "$PIPELINE_BASE_BRANCH" appears in Step 9b; unquoted form does not.
#  (b) A non-empty guard `if [ -z "$PIPELINE_BASE_BRANCH" ]; then` precedes `gh pr create \`.
#  (c) Prose cross-references the eval-time defense in evaluate-issue-pr Step 11.

set -euo pipefail

F="skills/execute-issue-plan/SKILL.md"

if [ ! -f "$F" ]; then
  echo "FAIL: $F not found"
  exit 1
fi

# Extract Step 9b region (from "**9b." up to next top-level numbered step or section break).
# We use awk to bracket the section.
section=$(awk '
  /^[[:space:]]*\*\*9b\./ { capture=1 }
  capture { print }
  /^[[:space:]]*10\./ && capture { exit }
' "$F")

if [ -z "$section" ]; then
  echo "FAIL: could not extract Step 9b section from $F"
  exit 1
fi

# (a) Quoted form must appear; unquoted form must not.
if ! printf '%s\n' "$section" | grep -qF -- '--base "$PIPELINE_BASE_BRANCH"'; then
  echo "FAIL: Step 9b missing quoted form: --base \"\$PIPELINE_BASE_BRANCH\""
  exit 1
fi

# Reject the bare unquoted form. Match `--base $PIPELINE_BASE_BRANCH` NOT followed by `"` or `}`,
# and only on lines that don't already contain the quoted form.
if printf '%s\n' "$section" | grep -E '\-\-base[[:space:]]+\$PIPELINE_BASE_BRANCH([[:space:]]|$)' \
     | grep -v '"\$PIPELINE_BASE_BRANCH"' | grep -q .; then
  echo "FAIL: Step 9b still contains unquoted --base \$PIPELINE_BASE_BRANCH"
  printf '%s\n' "$section" | grep -nE '\-\-base[[:space:]]+\$PIPELINE_BASE_BRANCH' >&2 || true
  exit 1
fi

# (b) Non-empty guard must appear on its own line immediately above `gh pr create \`
# Within 4 lines of context. Use grep -B 4 on the file (not the awk-extracted slice
# so we keep accurate line context for -B).
if ! grep -B 4 -E '^[[:space:]]+gh pr create \\' "$F" \
     | grep -qF 'if [ -z "$PIPELINE_BASE_BRANCH" ]; then'; then
  echo "FAIL: Step 9b missing non-empty guard line preceding 'gh pr create \\'"
  echo "Expected (on its own line, within 4 lines above gh pr create):"
  echo '  if [ -z "$PIPELINE_BASE_BRANCH" ]; then echo "FATAL: ..." >&2; exit 1; fi'
  exit 1
fi

# (c) Prose cross-reference: the surrounding prose mentions enforce-base-branch.py absence
# AND references evaluate-issue-pr Step 11 in the same general paragraph block.
if ! printf '%s\n' "$section" | grep -qF 'even when `enforce-base-branch.py` is absent'; then
  if ! printf '%s\n' "$section" | grep -qF 'even when enforce-base-branch.py is absent'; then
    echo "FAIL: Step 9b prose missing 'even when enforce-base-branch.py is absent' rationale"
    exit 1
  fi
fi

if ! printf '%s\n' "$section" | grep -qF 'evaluate-issue-pr'; then
  echo "FAIL: Step 9b prose missing cross-reference to 'evaluate-issue-pr'"
  exit 1
fi

if ! printf '%s\n' "$section" | grep -qF 'Step 11'; then
  echo "FAIL: Step 9b prose missing cross-reference to 'Step 11'"
  exit 1
fi

# Both 'evaluate-issue-pr' and 'Step 11' must appear in the same paragraph
# (i.e., within a contiguous non-empty block).
if ! printf '%s\n' "$section" | awk '
  BEGIN { para=""; found=0 }
  /^[[:space:]]*$/ {
    if (para ~ /evaluate-issue-pr/ && para ~ /Step 11/) { found=1 }
    para=""
    next
  }
  { para = para " " $0 }
  END {
    if (para ~ /evaluate-issue-pr/ && para ~ /Step 11/) { found=1 }
    exit (found ? 0 : 1)
  }
'; then
  echo "FAIL: 'evaluate-issue-pr' and 'Step 11' must appear in the same paragraph"
  exit 1
fi

echo "PASS: execute-issue-plan Step 9b mandates quoted --base + non-empty guard + cross-ref"
