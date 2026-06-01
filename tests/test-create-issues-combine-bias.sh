#!/usr/bin/env bash
set -euo pipefail

# Regression guard for issue #752: the create-issues scope-check (step 3 in
# skills/create-issues/SKILL.md) must carry an explicit, path-agnostic
# "combine bias" — default toward fewer issues when candidate slices touch
# overlapping files / share a plan / hit the same subsystem, and surface the
# file-overlap + "serialize + N× overhead" cost reasoning in the decomposition
# prompt. Pure-prose model-facing instructions: this is a phrase-presence guard
# so a future prose refactor can't silently drop the bias.

FILE="$(dirname "$0")/../skills/create-issues/SKILL.md"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 1
fi

fail=0
assert_has() { grep -qiF "$1" "$FILE" || { echo "MISSING: $1"; fail=1; }; }

# Load-bearing phrases the combine bias requires.
assert_has "combine bias"
assert_has "overlapping files"
assert_has "same subsystem"
assert_has "serialize"
assert_has "overhead"
assert_has "context-window"
assert_has "Path-agnostic"

# Negative assertion: scope-check step 3 must not assign or hint a path.
# Extract the step-3 block (from the "3. **Scope check" line up to the next
# top-level numbered item "4. ").
step3="$(awk '/^3\. \*\*Scope check/{f=1} /^4\. /{f=0} f' "$FILE")"
if [ -z "$step3" ]; then
  echo "VIOLATION: could not locate step 3 (Scope check) block"; fail=1
fi
if printf '%s' "$step3" | grep -qE 'pipeline:path=|PATH [BCD]'; then
  echo "VIOLATION: step 3 assigns/hints a path"; fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: create-issues combine-bias phrases present"
else
  exit 1
fi
