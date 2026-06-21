#!/usr/bin/env bash
# Test: the split-role GREEN-implementer contract requires running the FULL local
# suite green (not just the locked `[split-role-red]` files) BEFORE `gh pr create`,
# so a green-introduced break in a non-locked test is caught locally, not in CI. (#1108)
#
# Root cause (#1098 gap 1): the green-role contract directed greening "the suite
# test-by-test" + completing non-test deliverables, but never made running the FULL
# local suite green before PR a mandatory terminal step of the green role. The
# directive must be hardened in BOTH the execute-issue-plan skill body Phase (ii)
# block AND the fullsend green dispatch prompt(s) (a dispatched general-purpose green
# agent may never load skills/execute-issue-plan/SKILL.md, so the dispatch-site prompt
# is the binding contract).
#
# Three prose-assertion regression guards, one per REAL edit site, each requiring BOTH
# a full-suite token AND a pre-PR/not-just-locked token in the bracketed region:
#  (a) execute-issue-plan Phase (ii) GREEN block.
#  (b) fullsend `Inline execute dispatch prompt contract (mandatory)` paragraph.
#  (c) fullsend resolver-driven `When SPLIT_ROLE=true (PATH B only)` bullet.
#
# Each region is bracketed by a STABLE heading/marker (not a line number) so #1106's
# concurrent edits to these files cannot misalign the guard.
#
# Pattern mirrors tests/test-split-role-green-plan-complete.sh:
# set -euo pipefail, resolve ROOT, guard each named file exists, awk-bracket the
# relevant region, grep -qiE the required tokens, echo FAIL; exit 1 on miss.
#
# NOTE: this guard deliberately does NOT reuse the reference test's `split_dispatch`
# awk — that matches the FIRST `**When SPLIT_ROLE=true**` occurrence (the resolver
# code-block window) and exits before reaching the `(PATH B only)` bullet, which is
# the wrong window for this directive.

set -euo pipefail

# Resolve ROOT = repo root (parent of the tests/ dir holding this script).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

EXEC_F="$ROOT/skills/execute-issue-plan/SKILL.md"
FULLSEND_F="$ROOT/skills/fullsend/SKILL.md"

for f in "$EXEC_F" "$FULLSEND_F"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f not found"
    exit 1
  fi
done

# Two token families — each guarded region must contain BOTH.
#  - full-suite token: the directive names the FULL (local/test) suite.
#  - pre-PR / not-just-locked token: it runs before the PR (gh pr create) and is
#    distinguished from greening only the locked `[split-role-red]` files.
FULL_SUITE_RE='full (local )?(test )?suite'
PRE_PR_RE='before .*(pr|gh pr create)|not just the locked'

# Assert BOTH token families are present in a bracketed region.
#   $1 = region label (a|b|c), $2 = human description, $3 = region text
assert_full_suite_pre_pr() {
  local label="$1" desc="$2" region="$3"
  if [ -z "$region" ]; then
    echo "FAIL ($label): could not extract $desc region"
    exit 1
  fi
  if ! printf '%s\n' "$region" | grep -qiE "$FULL_SUITE_RE"; then
    echo "FAIL ($label): $desc missing full-suite token (/$FULL_SUITE_RE/)"
    echo "  Expected GREEN told to run the FULL local suite green before PR — not just the locked files."
    exit 1
  fi
  if ! printf '%s\n' "$region" | grep -qiE "$PRE_PR_RE"; then
    echo "FAIL ($label): $desc missing pre-PR / not-just-locked token (/$PRE_PR_RE/)"
    echo "  Expected the full-suite run framed as before \`gh pr create\` / not just the locked \`[split-role-red]\` files."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# (a) execute-issue-plan Phase (ii) GREEN block [edit site 1].
# Bracket from the `**Phase (ii)` bullet up to (but not including) the next
# `**Escalation valve.**` bullet (identical bracketing to the reference test).
# ---------------------------------------------------------------------------
region_a=$(awk '
  /\*\*Phase \(ii\)/ { capture=1 }
  capture && /\*\*Escalation valve\.\*\*/ { exit }
  capture { print }
' "$EXEC_F")

assert_full_suite_pre_pr "a" "execute-issue-plan Phase (ii) GREEN block" "$region_a"

# ---------------------------------------------------------------------------
# (b) fullsend `Inline execute dispatch prompt contract (mandatory)` paragraph
# [edit site 2]. Bracket from that marker up to (but not including) the next
# `### ` heading (the `### Triage on agent-stalled wakes` heading is INDENTED,
# so match `### ` WITHOUT a `^` anchor to terminate the region tightly).
# This is the binding green DISPATCH prompt the prior plan tested NOWHERE.
# ---------------------------------------------------------------------------
region_b=$(awk '
  /\*\*Inline execute dispatch prompt contract \(mandatory\)\.\*\*/ { capture=1 }
  capture && /### / { exit }
  capture { print }
' "$FULLSEND_F")

assert_full_suite_pre_pr "b" "fullsend Inline-execute-dispatch-prompt-contract paragraph" "$region_b"

# ---------------------------------------------------------------------------
# (c) fullsend resolver-driven `When SPLIT_ROLE=true (PATH B only)` bullet
# [edit site 3]. The `(PATH B only)` suffix uniquely disambiguates this bullet
# from the earlier `**When SPLIT_ROLE=true**` resolver-code-block occurrence.
# Bracket from that marker up to (but not including) the next `- **` bullet.
# ---------------------------------------------------------------------------
region_c=$(awk '
  /\*\*When `SPLIT_ROLE=true`\*\* \(PATH B only\)/ { capture=1; print; next }
  capture && /^[[:space:]]*- \*\*/ { exit }
  capture { print }
' "$FULLSEND_F")

assert_full_suite_pre_pr "c" "fullsend resolver-driven 'When SPLIT_ROLE=true (PATH B only)' bullet" "$region_c"

echo "PASS: split-role GREEN full-suite-before-PR directive present at all three edit sites (a/b/c)"
