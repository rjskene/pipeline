#!/usr/bin/env bash
# Test: split-role GREEN contract is plan-completeness (not just locked-suite-green),
# while the locked-test additive-only invariant is preserved, and evaluate-issue-pr
# Phase 1 asserts a per-artifact tracked-file check. (#1065)
#
# Four prose-assertion regression guards over three SKILL files:
#  (a) execute-issue-plan Phase (ii) GREEN block co-occurs a plan-completeness token
#      (`all` + `plan task`/`approved-plan task`) AND a non-test-deliverable token
#      (`docs`/`fixtures`/`non-test`) — GREEN finishes every plan task incl. non-test deliverables.
#  (b) Same block STILL retains the locked-test invariant: `[split-role-red]` AND
#      `never modify or delete` (additive-only preserved — guards against loosening the lock).
#  (c) fullsend `SPLIT_ROLE=true` split-dispatch directive co-occurs the plan-completeness
#      token (`all` + `plan task`) AND `additive-only` (invariant retained at the dispatch site).
#  (d) evaluate-issue-pr Phase 1 region co-occurs a per-artifact tracked-file token
#      (`tracked file` AND `artifact path`/`named ... path`).
#
# Pattern mirrors tests/test-execute-issue-plan-base-discipline.sh:
# set -euo pipefail, resolve ROOT, guard each named file exists, awk-bracket the
# relevant section, grep -qi the required tokens, echo FAIL; exit 1 on miss.

set -euo pipefail

# Resolve ROOT = repo root (parent of the tests/ dir holding this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EXEC_F="$ROOT/skills/execute-issue-plan/SKILL.md"
FULLSEND_F="$ROOT/skills/fullsend/SKILL.md"
EVAL_F="$ROOT/skills/evaluate-issue-pr/SKILL.md"

for f in "$EXEC_F" "$FULLSEND_F" "$EVAL_F"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f not found"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# (a) + (b): execute-issue-plan Phase (ii) GREEN block.
# Bracket from the `**Phase (ii) — implementer greens additive-only.**` bullet
# up to (but not including) the next `**Escalation valve.**` bullet.
# ---------------------------------------------------------------------------
phase_ii=$(awk '
  /\*\*Phase \(ii\)/ { capture=1 }
  capture && /\*\*Escalation valve\.\*\*/ { exit }
  capture { print }
' "$EXEC_F")

if [ -z "$phase_ii" ]; then
  echo "FAIL: could not extract Phase (ii) section from $EXEC_F"
  exit 1
fi

# (a) Plan-completeness token: `all` AND (`plan task` OR `approved-plan task`).
if ! printf '%s\n' "$phase_ii" | grep -qi 'all'; then
  echo "FAIL (a): execute-issue-plan Phase (ii) missing plan-completeness scope token 'all'"
  echo "  Expected GREEN told to complete ALL approved-plan tasks (not just green the locked suite)."
  exit 1
fi
if ! printf '%s\n' "$phase_ii" | grep -qiE 'approved-plan task|plan task'; then
  echo "FAIL (a): execute-issue-plan Phase (ii) missing 'plan task'/'approved-plan task' token"
  echo "  Expected GREEN told to complete ALL approved-plan tasks."
  exit 1
fi
# (a) Non-test-deliverable token: docs OR fixtures OR non-test.
if ! printf '%s\n' "$phase_ii" | grep -qiE 'docs|fixtures|non-test'; then
  echo "FAIL (a): execute-issue-plan Phase (ii) missing non-test-deliverable token (docs/fixtures/non-test)"
  echo "  Expected scope to call out non-test deliverables the locked suite does not exercise."
  exit 1
fi

# (b) Locked-test invariant preserved: `[split-role-red]` AND `never modify or delete`.
if ! printf '%s\n' "$phase_ii" | grep -qiF '[split-role-red]'; then
  echo "FAIL (b): execute-issue-plan Phase (ii) no longer retains '[split-role-red]' invariant token"
  exit 1
fi
if ! printf '%s\n' "$phase_ii" | grep -qi 'never modify or delete'; then
  echo "FAIL (b): execute-issue-plan Phase (ii) no longer retains 'never modify or delete' invariant"
  echo "  Widening must NOT loosen the additive-only locked-test rule."
  exit 1
fi

# ---------------------------------------------------------------------------
# (c): fullsend SPLIT_ROLE=true split-dispatch directive.
# Bracket the single line/bullet beginning `**When \`SPLIT_ROLE=true\`**`.
# The marker bears literal backticks; awk matches them with no escaping needed
# inside the regex (backticks are not regex metacharacters).
# Capture from that bullet up to the next top-level `- **` bullet at the same indent.
# ---------------------------------------------------------------------------
split_dispatch=$(awk '
  /\*\*When `SPLIT_ROLE=true`\*\*/ { capture=1; print; next }
  capture && /^[[:space:]]*- \*\*/ { exit }
  capture { print }
' "$FULLSEND_F")

if [ -z "$split_dispatch" ]; then
  echo "FAIL: could not extract SPLIT_ROLE=true split-dispatch directive from $FULLSEND_F"
  exit 1
fi

# (c) Plan-completeness token: `all` AND `plan task`.
if ! printf '%s\n' "$split_dispatch" | grep -qi 'all'; then
  echo "FAIL (c): fullsend SPLIT_ROLE=true directive missing plan-completeness scope token 'all'"
  exit 1
fi
if ! printf '%s\n' "$split_dispatch" | grep -qiE 'approved-plan task|plan task'; then
  echo "FAIL (c): fullsend SPLIT_ROLE=true directive missing 'plan task' token"
  echo "  Expected the green:<model> implementer clause to carry the plan-completeness scope."
  exit 1
fi
# (c) Invariant retained at the dispatch site: `additive-only`.
if ! printf '%s\n' "$split_dispatch" | grep -qi 'additive-only'; then
  echo "FAIL (c): fullsend SPLIT_ROLE=true directive no longer retains 'additive-only' invariant"
  exit 1
fi

# ---------------------------------------------------------------------------
# (d): evaluate-issue-pr Phase 1 plan-compliance region.
# Bracket from `**Phase 1 — Plan compliance.**` up to (not including) `**Phase 2`.
# ---------------------------------------------------------------------------
phase_1=$(awk '
  /\*\*Phase 1 — Plan compliance\.\*\*/ { capture=1 }
  capture && /\*\*Phase 2/ { exit }
  capture { print }
' "$EVAL_F")

if [ -z "$phase_1" ]; then
  echo "FAIL: could not extract Phase 1 plan-compliance section from $EVAL_F"
  exit 1
fi

# (d) Per-artifact tracked-file token: `tracked file` AND (`artifact path` OR `named ... path`).
if ! printf '%s\n' "$phase_1" | grep -qi 'tracked file'; then
  echo "FAIL (d): evaluate-issue-pr Phase 1 missing per-artifact 'tracked file' token"
  echo "  Expected: every plan Task naming a non-test artifact path must produce a tracked file."
  exit 1
fi
if ! printf '%s\n' "$phase_1" | grep -qiE 'artifact path|named .* path'; then
  echo "FAIL (d): evaluate-issue-pr Phase 1 missing 'artifact path'/'named ... path' token"
  echo "  Expected the per-artifact-path check (planned-but-untracked path → missing work → Flagged)."
  exit 1
fi

echo "PASS: split-role GREEN plan-completeness + invariant-preserved + eval tracked-file prose contract"
