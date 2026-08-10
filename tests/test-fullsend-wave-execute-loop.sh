#!/bin/bash
set -euo pipefail

# Prose-grep contract for issue #626, retargeted by #1214: skills/fullsend/SKILL.md
# must restructure its execute stage (Steps 5-7) into a per-wave EXECUTION loop with:
#   (a) a FETCH-ONLY inter-wave base refresh — a single
#       `git -C "$MAIN_REPO" fetch --quiet origin <base>` plus an ALWAYS-explicit
#       `--base` on setup-worktree.sh — so wave N+1's worktrees are cut from
#       `origin/<base>`'s tip and still inherit wave N's merged work, WITHOUT the
#       orchestrator ever checking out or pulling the operator's primary checkout
#       (#1214: the checkout+pull pair strands operator work and is not atomic), and
#   (b) a scoped halt whose dependency closure is computed from the
#       machine-readable `plan-waves.sh --stage=execute --emit-edges` output
#       (NOT from the human-readable `Wave N:` lines, which suppress per-issue
#       reasons for multi-issue waves).
#
# Assertions are scoped to the execute region of SKILL.md (roughly from the
# `5. **Set up worktrees**` anchor through Step 8 / Report). The test guards
# against regressing the Step 5 setup-worktree signature contract owned by
# tests/test-fullsend-skill-setup-worktree-signature.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_PATH="$SCRIPT_DIR/../skills/fullsend/SKILL.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SKILL_PATH" ]; then
  fail_msg "SKILL.md not found at $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

# Locate the execute region. Prefer the per-wave execute-stage section header
# (which introduces the wave loop and the two plan-waves.sh passes); fall back
# to the "5. **Set up worktrees**" anchor when that header is absent (today's
# pristine SKILL) so the RED run still fails for the right reason rather than
# erroring out. The region runs through the end of the file (Report / Stop /
# Constraints live just past Step 7).
STEP5_LINE=$(grep -nE '^5\. \*\*Set up worktrees\*\*' "$SKILL_PATH" | head -1 | cut -d: -f1)
if [ -z "$STEP5_LINE" ]; then
  fail_msg "could not find '5. **Set up worktrees**' anchor in $SKILL_PATH"
  echo "  $TESTS tests: $PASS passed, $FAIL failed"
  exit 1
fi

REGION_START=$(grep -niE '^#+ +Execute the slate WAVE BY WAVE' "$SKILL_PATH" | head -1 | cut -d: -f1)
[ -z "$REGION_START" ] && REGION_START="$STEP5_LINE"

TOTAL_LINES=$(wc -l < "$SKILL_PATH")
EXEC_REGION=$(sed -n "${REGION_START},${TOTAL_LINES}p" "$SKILL_PATH")

# ---------------------------------------------------------------------------
# 1. A literal `plan-waves.sh --stage=execute` invocation (distinct from any
#    --stage=classify pre-think).
# ---------------------------------------------------------------------------
inc
if grep -qF 'plan-waves.sh --stage=execute' <<< "$EXEC_REGION"; then
  pass_msg "execute region invokes plan-waves.sh --stage=execute"
else
  fail_msg "execute region does not invoke 'plan-waves.sh --stage=execute' (distinct from --stage=classify pre-think)"
fi

# ---------------------------------------------------------------------------
# 2. A per-wave loop marker AND a phrase that each wave's worktrees are CUT FROM
#    `origin/<base>`'s tip — and NOT off the CURRENT (local) base tip, which is
#    the pre-#1214 mechanism the explicit `--base` actuation supersedes.
# ---------------------------------------------------------------------------
inc
if grep -qiE 'wave by wave|for each wave|wave N\b' <<< "$EXEC_REGION"; then
  pass_msg "execute region has a per-wave loop marker (wave by wave / for each wave / wave N)"
else
  fail_msg "execute region lacks a per-wave loop marker (expected 'wave by wave' | 'for each wave' | 'wave N')"
fi

inc
if grep -qiE 'cut from \*{0,2}`?origin/<base>' <<< "$EXEC_REGION" \
   && ! grep -qiE 'off the current.*base tip|current local base tip|current local base' <<< "$EXEC_REGION"; then
  pass_msg "execute region states each wave's worktrees are cut from origin/<base>'s tip (local-base-tip phrasing retired)"
else
  fail_msg "execute region must state worktrees are 'cut from origin/<base>'s tip' AND must NOT retain the current-local-base-tip phrasing (#1214)"
fi

# ---------------------------------------------------------------------------
# 3. An inter-wave merge gate phrasing (wait for wave N's PRs to merge before
#    setting up wave N+1).
# ---------------------------------------------------------------------------
inc
if grep -qiE "wait for wave N.?s.*merge before|before setting up wave N\+1|PRs to merge before" <<< "$EXEC_REGION"; then
  pass_msg "execute region has an inter-wave merge gate phrasing"
else
  fail_msg "execute region lacks an inter-wave merge gate (e.g. 'wait for wave N's PRs to merge before setting up wave N+1')"
fi

# ---------------------------------------------------------------------------
# 4. The #1214 fetch-only inter-wave base refresh. The literal
#    `git -C "$MAIN_REPO" fetch --quiet origin` MUST be present, and every
#    primary-checkout-mutating token / LOCAL-HEAD rationale MUST be gone:
#      - `git pull --ff-only --quiet origin`      (the non-atomic pull half)
#      - `git -C "$MAIN_REPO" checkout`           (the ref-mutating checkout half)
#      - "advances the orchestrator's LOCAL base tip"  (the retired mechanism)
#      - "branches off LOCAL HEAD" / "only metadata, not a remote fetch"
#        (the pre-#1214 branch-point rationale that an explicit `--base` supersedes)
#    The surviving rationale is that wave N+1 INHERITS wave N's MERGED WORK —
#    that clause must stay, otherwise the loop's purpose is undocumented.
# ---------------------------------------------------------------------------
inc
if grep -qF 'git -C "$MAIN_REPO" fetch --quiet origin' <<< "$EXEC_REGION" \
   && ! grep -qF 'git pull --ff-only --quiet origin' <<< "$EXEC_REGION"; then
  pass_msg "execute region advances the base with the literal 'git -C \"\$MAIN_REPO\" fetch --quiet origin' and no longer pulls"
else
  fail_msg "execute region must carry 'git -C \"\$MAIN_REPO\" fetch --quiet origin' AND must NOT carry 'git pull --ff-only --quiet origin' (#1214)"
fi

inc
if grep -qF 'git -C "$MAIN_REPO" checkout' <<< "$EXEC_REGION"; then
  fail_msg "execute region still mutates the primary checkout via 'git -C \"\$MAIN_REPO\" checkout' — banned by #1214"
else
  pass_msg "execute region never checks out the orchestrator's primary checkout"
fi

inc
if grep -qiE "inherit.*merged work" <<< "$EXEC_REGION" \
   && ! grep -qiE "advances? the orchestrator.?s local base tip" <<< "$EXEC_REGION"; then
  pass_msg "execute region keeps the 'wave N+1 inherits merged work' rationale without sanctioning the retired LOCAL-base-tip advance"
else
  fail_msg "execute region must keep an 'inherit ... merged work' clause AND must NOT claim it 'advances the orchestrator's LOCAL base tip' (#1214)"
fi

inc
if grep -qiE "branches? off (the )?(main repo.s )?LOCAL HEAD|only metadata, not a remote fetch" <<< "$EXEC_REGION"; then
  fail_msg "execute region still documents the LOCAL-HEAD / metadata-only branch point — superseded by the explicit --base actuation (#1214)"
else
  pass_msg "execute region no longer claims setup-worktree.sh branches off LOCAL HEAD or that --base is metadata-only"
fi

# ---------------------------------------------------------------------------
# 5. The --emit-edges-sourced scoped halt closure.
# ---------------------------------------------------------------------------
inc
if grep -qF -- '--emit-edges' <<< "$EXEC_REGION"; then
  pass_msg "execute region references --emit-edges"
else
  fail_msg "execute region does not reference '--emit-edges'"
fi

inc
if grep -qiE 'EDGE |edge map|machine-readable edges' <<< "$EXEC_REGION"; then
  pass_msg "execute region references the EDGE / edge map / machine-readable edges"
else
  fail_msg "execute region lacks EDGE / 'edge map' / 'machine-readable edges' phrasing"
fi

inc
if grep -qiF 'dependency closure' <<< "$EXEC_REGION"; then
  pass_msg "execute region references a dependency closure"
else
  fail_msg "execute region lacks a 'dependency closure' phrasing"
fi

inc
if grep -qiE 'transitive(ly)?' <<< "$EXEC_REGION"; then
  pass_msg "execute region references transitive/transitively closure walking"
else
  fail_msg "execute region lacks 'transitive' / 'transitively' phrasing"
fi

inc
if grep -qiE 'computed from( this)? the?( \*\*)?(--?emit-edges|emitted)( \*\*)? edges|NOT( \*\*not\*\*)? from the human-readable .?Wave N' <<< "$EXEC_REGION"; then
  pass_msg "execute region states the closure is computed from the emitted edges, NOT the human-readable Wave N lines"
else
  fail_msg "execute region lacks a 'closure computed from emitted edges, NOT human-readable Wave N lines' statement"
fi

inc
if grep -qiE 'multi-issue waves? (print|emit|suppress|have).*(no per-issue reason|reason)' <<< "$EXEC_REGION"; then
  pass_msg "execute region explains multi-issue waves suppress per-issue reasons"
else
  fail_msg "execute region lacks the 'multi-issue waves print no per-issue reasons' rationale"
fi

inc
if grep -qiE 'independent later-wave issues.*(outside the closure)?.*(may|can) still proceed|outside the closure.*may still proceed|may still proceed off the current merged base' <<< "$EXEC_REGION"; then
  pass_msg "execute region states independent later-wave issues (outside closure) may still proceed off the merged base"
else
  fail_msg "execute region lacks 'independent later-wave issues outside the closure may still proceed off the current merged base'"
fi

# transient-block discrimination: distinguish block-ci/pending (defer to 6b
# CI-fix loop) from human-needed hard blocks.
inc
if grep -qF 'block-ci' <<< "$EXEC_REGION" \
   && grep -qiE '\bpending\b' <<< "$EXEC_REGION" \
   && grep -qiE 'CI-fix loop|Step 6b' <<< "$EXEC_REGION"; then
  pass_msg "execute region defers block-ci / pending to the Step 6b CI-fix loop"
else
  fail_msg "execute region lacks transient-block discrimination (block-ci/pending defer to the Step 6b CI-fix loop)"
fi

inc
if grep -qF 'block-mergestate' <<< "$EXEC_REGION" \
   && grep -qF 'block-verdict' <<< "$EXEC_REGION" \
   && grep -qF 'block-mergeable' <<< "$EXEC_REGION" \
   && grep -qF 'block-base-mismatch' <<< "$EXEC_REGION"; then
  pass_msg "execute region names the hard-block tokens (block-mergestate/block-verdict/block-mergeable/block-base-mismatch)"
else
  fail_msg "execute region does not name all hard-block tokens (block-mergestate, block-verdict, block-mergeable, block-base-mismatch)"
fi

# ---------------------------------------------------------------------------
# 6. Self-mutation callout: takes effect only after merge+pull; no
#    live-mutation risk because execution happens in a worktree.
# ---------------------------------------------------------------------------
inc
if grep -qiE 'self-mutation|live-mutation' <<< "$EXEC_REGION" \
   && grep -qiE 'after (the |this )?(PR )?merges?|only( takes effect)? after merge' <<< "$EXEC_REGION" \
   && grep -qiE 'worktree' <<< "$EXEC_REGION"; then
  pass_msg "execute region has a self-mutation callout (takes effect after merge+pull; no live-mutation risk in a worktree)"
else
  fail_msg "execute region lacks the self-mutation callout (effect only after merge+pull; no live-mutation risk; worktree-isolated)"
fi

# ---------------------------------------------------------------------------
# 7. Step 5 setup-worktree signature anchor preserved (guard against
#    regressing tests/test-fullsend-skill-setup-worktree-signature.sh).
# ---------------------------------------------------------------------------
inc
if grep -qE 'feature/<[^>]+>' <<< "$EXEC_REGION"; then
  pass_msg "execute region preserves the feature/<slug> branch shape token"
else
  fail_msg "execute region dropped the feature/<slug> branch shape token"
fi

inc
if grep -qE 'setup-worktree\.sh[[:space:]]+(--base[[:space:]]+[^[:space:]]+[[:space:]]+)?feature/[a-z0-9-]+[[:space:]]+[0-9]+' <<< "$EXEC_REGION"; then
  pass_msg "execute region preserves a worked two-arg setup-worktree.sh example"
else
  fail_msg "execute region dropped the worked two-arg setup-worktree.sh example (feature/<slug> <integer>)"
fi

inc
if grep -qiE '[Dd]o NOT invoke.*only the issue number|[Dd]o not invoke.*only the issue' <<< "$EXEC_REGION"; then
  pass_msg "execute region preserves the 'Do NOT invoke with only the issue number' callout"
else
  fail_msg "execute region dropped the 'Do NOT invoke with only the issue number' callout"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
