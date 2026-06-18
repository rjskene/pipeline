#!/usr/bin/env bash
# Test: evaluate-issue-pr Step 11.2b gates the split-role precondition on the
# issue's PATH letter + the resolved dispatch shape, so it no longer
# unconditionally blocks non-split + ALL PATH-D PRs as `no-red-sha`. (#1076)
#
# THE BUG (#1076): Step 11.2b ran scripts/split-role-gate.sh and required
# SPLIT_ROLE=pass whenever PIPELINE_PATH_B_SPLIT_ROLE was anything but explicit
# =false (default-on per #1057), with NO guard for whether the PR was actually
# dispatched as split-role. Every PATH D quick-fix PR (never split-role, never
# carries a [split-role-red] anchor) was permanently blocked no-red-sha; so were
# single-role PATH B PRs. This forced a manual override-merge of #1066 (PR #1072).
#
# THE FIX (prose-contract change at Step 11.2b):
#  (a) PATH-skip: non-`B` paths (docs-only/multi-task/quick-fix = A/C/D) SKIP the
#      gate — it applies ONLY to PATH B. Fixes the PATH-D permanent block.
#  (b) resolver-shape-skip: PATH B resolves the dispatch shape via
#      resolve-execute-dispatch.sh and SKIPS the gate when SPLIT_ROLE=false
#      (single-role; nothing to protect).
#  (c) invariant-preserved: a genuine split-role PR (SPLIT_ROLE=true) STILL RUNS
#      the gate and no-red-sha STILL blocks (guards against gutting the gate).
#
# Three grep-based prose-assertion regression guards over the Step 11.2b region of
# skills/evaluate-issue-pr/SKILL.md. Pattern mirrors
# tests/test-path-b-default-split-role.sh + tests/test-split-role-green-plan-complete.sh:
# set -euo pipefail, resolve ROOT, guard the file exists, awk-bracket the region,
# grep -qi the required tokens, echo FAIL; exit 1 on miss.

set -euo pipefail

# Resolve ROOT = repo root (parent of the tests/ dir holding this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EVAL_F="$ROOT/skills/evaluate-issue-pr/SKILL.md"

if [ ! -f "$EVAL_F" ]; then
  echo "FAIL: $EVAL_F not found"
  exit 1
fi

# Bracket the Step 11.2b region: from the `2b. **Split-role gate` bullet up to
# (but not including) the next numbered greenlight step `3. **On \`green\`:**`.
step_2b=$(awk '
  /^[[:space:]]*2b\. \*\*Split-role gate/ { capture=1 }
  capture && /^[[:space:]]*3\. \*\*On `green`/ { exit }
  capture { print }
' "$EVAL_F")

if [ -z "$step_2b" ]; then
  echo "FAIL: could not extract Step 11.2b split-role-gate region from $EVAL_F"
  exit 1
fi

# (a) PATH-skip token: the gate applies only to PATH B; non-B paths
#     (docs-only/multi-task/quick-fix = A/C/D) SKIP it. Require `PATH` AND a
#     skip token AND the PATH-D `quick-fix` label name to co-occur.
if ! printf '%s\n' "$step_2b" | grep -qiF 'PATH'; then
  echo "FAIL (a): Step 11.2b missing PATH-skip token 'PATH'"
  echo "  Expected: the gate keys on the issue's PATH letter (only PATH B runs it)."
  exit 1
fi
if ! printf '%s\n' "$step_2b" | grep -qi 'quick-fix'; then
  echo "FAIL (a): Step 11.2b missing 'quick-fix' (PATH D) skip token"
  echo "  Expected: PATH D quick-fix PRs SKIP the gate (the #1076 permanent-block fix)."
  exit 1
fi
if ! printf '%s\n' "$step_2b" | grep -qi 'skip'; then
  echo "FAIL (a): Step 11.2b missing 'skip' token for non-PATH-B paths"
  echo "  Expected: non-B paths SKIP / treat the gate as not-applicable."
  exit 1
fi

# (b) resolver-shape-skip token: PATH B with SPLIT_ROLE=false (single-role) SKIPS
#     the gate, resolved via resolve-execute-dispatch.sh.
if ! printf '%s\n' "$step_2b" | grep -qi 'resolve-execute-dispatch.sh'; then
  echo "FAIL (b): Step 11.2b missing 'resolve-execute-dispatch.sh' resolver token"
  echo "  Expected: PATH B resolves the dispatch shape and skips the gate when SPLIT_ROLE=false."
  exit 1
fi
if ! printf '%s\n' "$step_2b" | grep -qiF 'SPLIT_ROLE=false'; then
  echo "FAIL (b): Step 11.2b missing 'SPLIT_ROLE=false' single-role-skip token"
  echo "  Expected: a single-role PATH B dispatch (SPLIT_ROLE=false) SKIPS the gate."
  exit 1
fi

# (c) invariant-preserved token: a genuine split-role PR (SPLIT_ROLE=true) STILL
#     RUNS the gate and no-red-sha STILL blocks (guards against the edit gutting
#     the gate entirely).
if ! printf '%s\n' "$step_2b" | grep -qiF 'SPLIT_ROLE=true'; then
  echo "FAIL (c): Step 11.2b missing 'SPLIT_ROLE=true' invariant-preserved token"
  echo "  Expected: a genuine split-role dispatch (SPLIT_ROLE=true) still RUNS the gate."
  exit 1
fi
if ! printf '%s\n' "$step_2b" | grep -qi 'no-red-sha'; then
  echo "FAIL (c): Step 11.2b missing 'no-red-sha' block-invariant token"
  echo "  Expected: for a genuine split-role PR, no-red-sha STILL hard-blocks (manual merge)."
  exit 1
fi

echo "PASS: split-role gate path + resolver-shape guard prose contract (#1076)"
