#!/bin/bash
set -uo pipefail
#
# Tests that skills/create-issues/SKILL.md documents the shared-scope rule
# for sub-issue titles in multi-issue (tracker) proposals, and that the
# multi-issue proposal example demonstrates uniform `<type>(<scope>):`
# prefixes across all children (with scope matching the tracker's
# `epic(<scope>)`). See Issue #30.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/create-issues/SKILL.md"

PASS=0
FAIL=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  fail_msg "SKILL.md exists at skills/create-issues/SKILL.md"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# Extract the "Issue proposal format" section: lines between the
# `### Issue proposal format` header and the next `### ` header.
section=$(awk '
  /^### Issue proposal format[[:space:]]*$/ { in_section = 1; next }
  in_section && /^### / { exit }
  in_section { print }
' "$SKILL")

if [ -z "$section" ]; then
  fail_msg "Issue proposal format section is non-empty"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# (1) Shared-scope rule is described in the proposal-format section.
if echo "$section" | grep -qiE '(shared|same) scope' && echo "$section" | grep -qi 'tracker'; then
  pass_msg "proposal-format section describes shared-scope-with-tracker rule"
else
  fail_msg "proposal-format section describes shared-scope-with-tracker rule"
fi

# Extract the multi-issue example fenced block — the one containing both
# a `(pending tracker)` line AND `(pending) <sub-issue` (so we don't catch
# the single-issue example).
multi_block=$(echo "$section" | awk '
  /^```/ { in_block = !in_block; if (!in_block) { if (block ~ /\(pending tracker\)/ && block ~ /\(pending\)/) { print block; exit } ; block = "" } ; next }
  in_block { block = block $0 "\n" }
')

if [ -z "$multi_block" ]; then
  fail_msg "multi-issue example fenced block found"
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
else
  pass_msg "multi-issue example fenced block found"
fi

# (2a) Count `(pending)` sub-issue lines (excluding the tracker line) — must be >= 2.
pending_lines=$(echo "$multi_block" | grep -E '^- \(pending\) ' || true)
pending_count=$(echo "$pending_lines" | grep -c . || true)

if [ "$pending_count" -ge 2 ]; then
  pass_msg "multi-issue example has >= 2 (pending) sub-issue lines (found $pending_count)"
else
  fail_msg "multi-issue example has >= 2 (pending) sub-issue lines (found $pending_count)"
fi

# (2b) Every `(pending)` sub-issue line uses a conventional `<type>(<scope>):` prefix.
bad_prefix=$(echo "$pending_lines" | grep -vE '^- \(pending\) [a-z]+\([a-z0-9-]+\): ' || true)
if [ -z "$bad_prefix" ] && [ "$pending_count" -ge 1 ]; then
  pass_msg "every (pending) sub-issue line uses conventional <type>(<scope>): prefix"
else
  fail_msg "every (pending) sub-issue line uses conventional <type>(<scope>): prefix"
  if [ -n "$bad_prefix" ]; then
    echo "    offending lines:"
    echo "$bad_prefix" | sed 's/^/      /'
  fi
fi

# (3) Derive scope from the tracker line: `(pending tracker) epic(<scope>): ...`
tracker_line=$(echo "$multi_block" | grep -E '^- \(pending tracker\) ' | head -n 1)
tracker_scope=$(echo "$tracker_line" | sed -nE 's/^- \(pending tracker\) epic\(([a-z0-9-]+)\):.*/\1/p')

if [ -n "$tracker_scope" ]; then
  pass_msg "tracker line uses epic(<scope>): shape (scope=$tracker_scope)"
else
  fail_msg "tracker line uses epic(<scope>): shape"
fi

# (4) Every sub-issue line shares the tracker scope.
if [ -n "$tracker_scope" ] && [ "$pending_count" -ge 1 ]; then
  mismatched=$(echo "$pending_lines" | grep -vE "^- \(pending\) [a-z]+\(${tracker_scope}\): " || true)
  if [ -z "$mismatched" ]; then
    pass_msg "all sub-issue lines share tracker scope ($tracker_scope)"
  else
    fail_msg "all sub-issue lines share tracker scope ($tracker_scope)"
    echo "    offending lines:"
    echo "$mismatched" | sed 's/^/      /'
  fi
else
  fail_msg "all sub-issue lines share tracker scope (precondition not met)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
