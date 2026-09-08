#!/usr/bin/env bash
set -euo pipefail
# #763: the run→status rename moved the per-path dispatch-routing contract out of
# the old /pipeline:run skill into fullsend's "## Dispatch routing by path tier
# (reference)" section (the read-only /pipeline:status skill dispatches nothing).
SKILL="skills/fullsend/SKILL.md"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL missing"; exit 1; }

STEP6=$(awk '/^[[:space:]]*\*\*For execution \(plan-approved/,/^### Anti-patterns|^## Merge orchestration|^8\. \*\*Merge orchestration/' "$SKILL")
STEP7=$(awk '/^[[:space:]]*\*\*For PR evaluation \(pr-open/,/^[[:space:]]*\*\*For execution \(plan-approved/' "$SKILL")

echo "$STEP6" | grep -q "PATH A" || { echo "FAIL: Step 6 missing PATH A branch"; exit 1; }
echo "$STEP6" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 6 PATH A branch missing Agent(subagent_type=...)"; exit 1; }
echo "$STEP7" | grep -q "PATH A" || { echo "FAIL: Step 7 missing PATH A branch"; exit 1; }
echo "$STEP7" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 7 PATH A branch missing Agent(subagent_type=...)"; exit 1; }

# PATH B and PATH C are now SPLIT (issue #748): PATH B dispatches inline via
# Agent(...) (no spawn-claude.sh), PATH C keeps the spawn/run-queue flow.
# Extract a single path bullet block ("- **PATH X**" up to the next "- **PATH")
# from a step window so the B-inline / C-spawn assertions are path-scoped and
# cannot be masked by another path's text elsewhere in the window.
path_block() {
  echo "$1" | awk -v p="$2" '
    $0 ~ "\\*\\*"p"\\*\\*" {grab=1; print; next}
    grab && /^[[:space:]]*-[[:space:]]*\*\*PATH/ {grab=0}
    grab {print}
  '
}

# Step 6 (execution): PATH B inline, PATH C spawn.
STEP6_B=$(path_block "$STEP6" "PATH B")
[ -n "$STEP6_B" ] || { echo "FAIL: Step 6 missing standalone PATH B branch"; exit 1; }
echo "$STEP6_B" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 6 PATH B branch missing inline Agent(subagent_type=...)"; exit 1; }
echo "$STEP6_B" | grep -qF "No spawn-claude.sh" || { echo "FAIL: Step 6 PATH B branch missing 'No spawn-claude.sh' negation"; exit 1; }
# Issue #749: Step 6 (execution) PATH C is now INLINE-by-default — the
# orchestrator fans out Agent(subagent_type='pipeline:tdd-implementer') per
# target=<dir> (#1238 — the bare `tdd-implementer` string does not resolve),
# with spawn-claude.sh/run-queue.sh reachable only under the --spawn fallback.
STEP6_C=$(path_block "$STEP6" "PATH C")
[ -n "$STEP6_C" ] || { echo "FAIL: Step 6 missing standalone PATH C branch"; exit 1; }
echo "$STEP6_C" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 6 PATH C branch missing inline Agent(subagent_type=...) (inline-by-default, #749)"; exit 1; }
echo "$STEP6_C" | grep -qF -- "--spawn" || { echo "FAIL: Step 6 PATH C branch missing --spawn fallback reference (#749)"; exit 1; }
echo "$STEP6_C" | grep -qE "spawn-claude.sh|run-queue.sh" || { echo "FAIL: Step 6 PATH C branch missing legacy spawn-claude.sh/run-queue.sh fallback target (#749)"; exit 1; }

# Step 7 (PR evaluation): PATH B inline, PATH C spawn.
STEP7_B=$(path_block "$STEP7" "PATH B")
[ -n "$STEP7_B" ] || { echo "FAIL: Step 7 missing standalone PATH B branch"; exit 1; }
echo "$STEP7_B" | grep -q "Agent(subagent_type=" || { echo "FAIL: Step 7 PATH B branch missing inline Agent(subagent_type=...)"; exit 1; }
echo "$STEP7_B" | grep -qF "No spawn-claude.sh" || { echo "FAIL: Step 7 PATH B branch missing 'No spawn-claude.sh' negation"; exit 1; }
STEP7_C=$(path_block "$STEP7" "PATH C")
[ -n "$STEP7_C" ] || { echo "FAIL: Step 7 missing standalone PATH C branch"; exit 1; }
echo "$STEP7_C" | grep -q "spawn-claude.sh" || { echo "FAIL: Step 7 PATH C branch missing spawn-claude.sh"; exit 1; }

# PATH D (quick-fix): inline dispatch via the PLUGIN-NAMESPACED
# pipeline:tdd-implementer subagent (#1238 — the bare `tdd-implementer` string
# is not a registered agent type and hard-fails the dispatch), explicitly NOT
# through spawn-claude.sh. Mirrors the A/B/C fixture style: the assertion lives
# inside Step 6's "For execution" window.
echo "$STEP6" | grep -q "PATH D" || { echo "FAIL: Step 6 missing PATH D branch"; exit 1; }
echo "$STEP6" | grep -q "quick-fix" || { echo "FAIL: Step 6 PATH D branch missing quick-fix label reference"; exit 1; }
echo "$STEP6" | grep -qF "Agent(subagent_type='pipeline:tdd-implementer'" \
  || { echo "FAIL: Step 6 PATH D branch missing namespaced Agent(subagent_type='pipeline:tdd-implementer' (#1238)"; exit 1; }
# Defensive (#1238, INVERTED): the namespaced form must be PRESENT and the BARE
# form must be GONE from the Step 6 dispatch window.
echo "$STEP6" | grep -qF "pipeline:tdd-implementer" \
  || { echo "FAIL: Step 6 missing pipeline:tdd-implementer — the bare form does not resolve (#1238)"; exit 1; }
echo "$STEP6" | grep -qF "Agent(subagent_type='tdd-implementer'" \
  && { echo "FAIL: Step 6 still carries the BARE Agent(subagent_type='tdd-implementer' literal (#1238)"; exit 1; } \
  || true
# PATH D explicitly does NOT use spawn-claude.sh — verify the negation
# phrasing is present.
echo "$STEP6" | grep -qF "No spawn-claude.sh" \
  || { echo "FAIL: Step 6 PATH D branch missing 'No spawn-claude.sh' negation"; exit 1; }

# Issue #748 drift guard: PATH B is inline now, so no part of the run skill may
# call a PATH B run a "spawned" one (the D escalation backstop used to). This is
# a NOT-spawn-paired assertion in the #748 anti-masking spirit.
grep -qE "spawned PATH B|spawned B run|PATH B.*spawned (worker|run)" "$SKILL" \
  && { echo "FAIL: run SKILL.md still calls a PATH B run 'spawned' (B is inline now, #748)"; exit 1; } || true

# Issue #896: the #749 conservative 1–2 git-index cap is RETIRED by the per-leaf
# -worktree fix. The routing/Step-6 prose must instead name the per-leaf worktree
# helper and bound concurrency by orchestrator context (max-3 foreground), NOT a
# git-index cap. Phrase-presence guard — pure model-facing prose.
grep -qF "path-c-split-worktree.sh" "$SKILL" \
  || { echo "FAIL: SKILL.md missing the per-leaf-worktree helper 'path-c-split-worktree.sh' (#896)"; exit 1; }
grep -qF "per-leaf worktree" "$SKILL" \
  || { echo "FAIL: SKILL.md missing the 'per-leaf worktree' isolation contract (#896)"; exit 1; }
grep -qE "never share a git index|shared.index race|git-index cap is retired|1–2 (git-index )?cap is retired" "$SKILL" \
  || { echo "FAIL: SKILL.md must explain per-leaf worktrees eliminate the shared git-index race / retire the 1–2 cap (#896)"; exit 1; }

echo "PASS: run SKILL.md dispatch routing"
