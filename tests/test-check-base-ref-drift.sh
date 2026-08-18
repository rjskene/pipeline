#!/bin/bash
set -uo pipefail

# RED anchor (#1106, split-role PATH B) — failing suite for the Layer-2
# cause-agnostic base-ref drift guard. Authored by the RED test-author; the
# GREEN role implements scripts/check-base-ref-drift.sh + the Layer-1 skill
# directives that green this suite. RED must NOT create the script or edit the
# skills — until they exist this suite is RED for the RIGHT reason:
#   - cases (a)-(d): scripts/check-base-ref-drift.sh is missing.
#   - case  (e):     skills/fullsend/SKILL.md + skills/execute-issue-plan/SKILL.md
#                    lack the `git -C` + `symbolic-ref --short HEAD` directive.
#
# Contract under test — scripts/check-base-ref-drift.sh <base> <expected-sha> [feature-branch...]:
#   Emits EXACTLY ONE token on stdout; ALWAYS exits 0 (the verdict rides the
#   token, mirroring scripts/verify-execute-completion.sh / scripts/split-role-gate.sh):
#     BASE=ok                         local base SHA == expected; no mutation.
#     BASE=recovered                  drifted, but every stray commit in
#                                     origin/<base>..<local-base> is reachable
#                                     from a passed feature branch
#                                     -> `git reset --hard origin/<base>`.
#     BASE=drift-unsafe ORPHANS=<shas> a stray commit is on NO feature branch
#                                     -> NO reset (would orphan work); halt.
#     BASE=error REASON=<...>         bad args / unresolvable ref; no mutation.
#
# #1214 extension — recovery must be HEAD-AWARE. `git reset --hard` moves
# WHATEVER BRANCH HEAD IS ON, which is only the base branch when the caller was
# standing on it. Now that the campaign/wave loop no longer checks the primary
# checkout out onto the base branch before calling this guard, recovery has to
# select its mechanism from HEAD:
#     HEAD is ON <base>   -> git reset --hard origin/<base>   (unchanged path)
#     HEAD is elsewhere   -> git branch -f <base> origin/<base>
#                            (never touches HEAD, the index, or the checked-out
#                            feature branch)
#     neither is legal    -> BASE=error REASON=reset-failed   (fail-open; the
#                            EXISTING token, no new token enters the contract)
# Cases (f) and (g) pin those two new behaviours.
#
# Fixture convention mirrors tests/test-split-role-gate.sh: an isolated mktemp
# repo per case with a real local `origin` remote (so `origin/<base>` resolves),
# trap-cleaned even on failure, with PASS/FAIL counters; this suite only exits
# nonzero on an assertion failure of its OWN, NEVER from the guard's exit code.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$REPO_ROOT/scripts/check-base-ref-drift.sh"

BASE=staging-test           # the simulated PIPELINE_BASE_BRANCH

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# build_repo <name> — fresh repo with $BASE checked out, a single base commit
# B0, and a local `origin` remote whose `origin/$BASE` == B0 (so the guard can
# resolve the canonical base tip). Echoes the repo path; the caller proceeds
# inside it. The guard's natural CWD is the orchestrator's main checkout, so
# every case invokes it from inside the repo via run_guard.
build_repo() {
  local repo="$WORKDIR/$1"
  local origin="$WORKDIR/$1-origin.git"
  mkdir -p "$repo"
  git init -q --bare "$origin"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" checkout -q -b "$BASE"
  echo base0 > "$repo/base.txt"
  git -C "$repo" add base.txt
  git -C "$repo" commit -qm "B0 base"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q origin "$BASE"
  # Track origin/$BASE so `git rev-parse origin/$BASE` resolves.
  git -C "$repo" fetch -q origin
  echo "$repo"
}

# run_guard <repo> <args...> — invoke the guard from inside <repo>; capture
# stdout (single token) into OUT and exit code into CODE. set +e so a nonzero
# exit (which the contract forbids, but we must still observe) never aborts the
# suite. stderr discarded.
run_guard() {
  local repo="$1"; shift
  set +e
  OUT=$( cd "$repo" && bash "$GUARD" "$@" 2>/dev/null )
  CODE=$?
  set -e
}

# sha <repo> <ref> — full SHA of <ref> in <repo>.
sha() { git -C "$1" rev-parse "$2"; }

# ---------------------------------------------------------------------------
# Hard precondition: if the guard is missing, cases (a)-(d) cannot meaningfully
# assert anything — surface that explicitly (RED-for-the-right-reason) but do
# NOT short-circuit the run; case (e) (the skill-directive grep) is independent
# of the script and must still run. We record one failed assertion to keep the
# suite RED and continue.
GUARD_PRESENT=1
if [ ! -f "$GUARD" ]; then
  GUARD_PRESENT=0
  echo "NOTE: $GUARD is missing — expected RED until the GREEN role authors it."
fi

# ===========================================================================
echo "Case (a): no drift -> BASE=ok, base SHA unchanged, exit 0"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "a: guard script missing ($GUARD) — cannot evaluate BASE=ok"
else
  REPO=$(build_repo a)
  EXPECTED=$(sha "$REPO" "$BASE")
  run_guard "$REPO" "$BASE" "$EXPECTED"
  AFTER=$(sha "$REPO" "$BASE")
  if [ "$CODE" -ne 0 ]; then
    fail_msg "a: expected exit 0 (verdict rides the token), got exit $CODE"
  elif [ "$OUT" != "BASE=ok" ]; then
    fail_msg "a: expected token 'BASE=ok', got '$OUT'"
  elif [ "$AFTER" != "$EXPECTED" ]; then
    fail_msg "a: base SHA mutated on a no-drift call ($EXPECTED -> $AFTER)"
  else
    pass_msg "a: BASE=ok, exit 0, base unchanged"
  fi
fi

# ===========================================================================
echo "Case (b): reachable stray -> BASE=recovered, base reset to origin, stray preserved"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "b: guard script missing ($GUARD) — cannot evaluate BASE=recovered"
else
  REPO=$(build_repo b)
  B0=$(sha "$REPO" "$BASE")
  # Feature branch off B0, carrying a stray commit S.
  git -C "$REPO" checkout -q -b feature/x
  echo strayS > "$REPO/stray.txt"
  git -C "$REPO" add stray.txt
  git -C "$REPO" commit -qm "S stray work on feature/x"
  S=$(sha "$REPO" feature/x)
  # Simulate the drift: advance LOCAL $BASE to also contain S (origin/$BASE still B0).
  git -C "$REPO" checkout -q "$BASE"
  git -C "$REPO" merge -q --ff-only feature/x
  EXPECTED=$B0
  run_guard "$REPO" "$BASE" "$EXPECTED" feature/x
  AFTER=$(sha "$REPO" "$BASE")
  ORIGIN=$(sha "$REPO" "origin/$BASE")
  if [ "$CODE" -ne 0 ]; then
    fail_msg "b: expected exit 0, got exit $CODE (out='$OUT')"
  elif [ "$OUT" != "BASE=recovered" ]; then
    fail_msg "b: expected token 'BASE=recovered', got '$OUT'"
  elif [ "$AFTER" != "$ORIGIN" ]; then
    fail_msg "b: base not reset to origin/$BASE (base=$AFTER origin=$ORIGIN, B0=$B0)"
  elif [ "$AFTER" != "$B0" ]; then
    fail_msg "b: base reset to wrong SHA ($AFTER, expected B0=$B0)"
  elif ! git -C "$REPO" merge-base --is-ancestor "$S" feature/x; then
    fail_msg "b: stray commit $S no longer reachable from feature/x (work lost)"
  else
    pass_msg "b: BASE=recovered, base reset to origin/$BASE, stray preserved on feature/x"
  fi
fi

# ===========================================================================
echo "Case (c): orphan stray (on NO feature branch) -> BASE=drift-unsafe ORPHANS=<sha>, no reset"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "c: guard script missing ($GUARD) — cannot evaluate BASE=drift-unsafe"
else
  REPO=$(build_repo c)
  B0=$(sha "$REPO" "$BASE")
  # Commit S2 DIRECTLY onto local $BASE — the orphan, on no feature branch.
  echo orphanS2 > "$REPO/orphan.txt"
  git -C "$REPO" add orphan.txt
  git -C "$REPO" commit -qm "S2 orphan stray on base"
  S2=$(sha "$REPO" "$BASE")
  # An unrelated feature branch off B0 that does NOT contain S2.
  git -C "$REPO" branch feature/y "$B0"
  EXPECTED=$B0
  run_guard "$REPO" "$BASE" "$EXPECTED" feature/y
  AFTER=$(sha "$REPO" "$BASE")
  if [ "$CODE" -ne 0 ]; then
    fail_msg "c: expected exit 0, got exit $CODE (out='$OUT')"
  elif [[ "$OUT" != BASE=drift-unsafe* ]]; then
    fail_msg "c: expected token to start with 'BASE=drift-unsafe', got '$OUT'"
  elif [[ "$OUT" != *ORPHANS=* ]]; then
    fail_msg "c: expected token to carry 'ORPHANS=', got '$OUT'"
  elif ! { [[ "$OUT" == *"$S2"* ]] || [[ "$OUT" == *"$(git -C "$REPO" rev-parse --short "$S2")"* ]]; }; then
    fail_msg "c: expected orphan SHA $S2 (or abbrev) in ORPHANS list, got '$OUT'"
  elif [ "$AFTER" != "$S2" ]; then
    fail_msg "c: base was reset despite an orphan stray (base=$AFTER, expected S2=$S2) — work would be lost"
  else
    pass_msg "c: BASE=drift-unsafe ORPHANS lists $S2, base NOT reset"
  fi
fi

# ===========================================================================
echo "Case (d1): too few args -> BASE=error REASON=..., exit 0"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "d1: guard script missing ($GUARD) — cannot evaluate BASE=error"
else
  REPO=$(build_repo d1)
  run_guard "$REPO"   # zero args
  if [ "$CODE" -ne 0 ]; then
    fail_msg "d1: expected exit 0 even on bad args, got exit $CODE (out='$OUT')"
  elif [[ "$OUT" != BASE=error* ]]; then
    fail_msg "d1: expected token to start with 'BASE=error', got '$OUT'"
  elif [[ "$OUT" != *REASON=* ]]; then
    fail_msg "d1: expected token to carry 'REASON=', got '$OUT'"
  else
    pass_msg "d1: BASE=error REASON=..., exit 0 on too-few-args"
  fi
fi

# ===========================================================================
echo "Case (d2): unresolvable base ref -> BASE=error REASON=..., exit 0, no mutation"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "d2: guard script missing ($GUARD) — cannot evaluate BASE=error"
else
  REPO=$(build_repo d2)
  BEFORE=$(sha "$REPO" "$BASE")
  EXPECTED=$BEFORE
  run_guard "$REPO" no-such-branch "$EXPECTED"
  AFTER=$(sha "$REPO" "$BASE")
  if [ "$CODE" -ne 0 ]; then
    fail_msg "d2: expected exit 0 on unresolvable ref, got exit $CODE (out='$OUT')"
  elif [[ "$OUT" != BASE=error* ]]; then
    fail_msg "d2: expected token to start with 'BASE=error', got '$OUT'"
  elif [[ "$OUT" != *REASON=* ]]; then
    fail_msg "d2: expected token to carry 'REASON=', got '$OUT'"
  elif [ "$AFTER" != "$BEFORE" ]; then
    fail_msg "d2: ref mutated on an error path ($BEFORE -> $AFTER)"
  else
    pass_msg "d2: BASE=error REASON=..., exit 0, no mutation on unresolvable ref"
  fi
fi

# ===========================================================================
echo "Case (f): recover while HEAD is on a feature branch -> base moved, HEAD + feature branch untouched"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "f: guard script missing ($GUARD) — cannot evaluate HEAD-aware recovery"
else
  REPO=$(build_repo f)
  B0=$(sha "$REPO" "$BASE")
  # Stray commit S lands on local $BASE (origin/$BASE still B0)...
  echo strayS > "$REPO/stray.txt"
  git -C "$REPO" add stray.txt
  git -C "$REPO" commit -qm "S stray work"
  S=$(sha "$REPO" "$BASE")
  # ...and is also reachable from feature/x, so the drift is RECOVERABLE.
  git -C "$REPO" branch feature/x "$S"
  # The caller is NOT standing on the base branch — this is the #1214 shape:
  # the campaign loop no longer checks the primary checkout out onto <base>.
  git -C "$REPO" checkout -q feature/x
  run_guard "$REPO" "$BASE" "$B0" feature/x
  AFTER=$(sha "$REPO" "$BASE")
  ORIGIN=$(sha "$REPO" "origin/$BASE")
  HEAD_REF=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
  FX=$(sha "$REPO" feature/x)
  if [ "$CODE" -ne 0 ]; then
    fail_msg "f: expected exit 0, got exit $CODE (out='$OUT')"
  elif [ "$OUT" != "BASE=recovered" ]; then
    fail_msg "f: expected token 'BASE=recovered', got '$OUT'"
  elif [ "$AFTER" != "$ORIGIN" ]; then
    fail_msg "f: local '$BASE' not moved to origin/$BASE (base=$AFTER origin=$ORIGIN) — reset --hard moved HEAD's branch instead"
  elif [ "$HEAD_REF" != "feature/x" ]; then
    fail_msg "f: HEAD left feature/x (now '$HEAD_REF') — recovery must never move HEAD"
  elif [ "$FX" != "$S" ]; then
    fail_msg "f: feature/x was force-moved ($S -> $FX) — recovery destroyed the checked-out feature branch"
  else
    pass_msg "f: BASE=recovered via a HEAD-aware base move; HEAD and feature/x both intact"
  fi
fi

# ===========================================================================
echo "Case (g): base ref cannot be moved -> BASE=error REASON=reset-failed, no mutation"
inc
if [ "$GUARD_PRESENT" -eq 0 ]; then
  fail_msg "g: guard script missing ($GUARD) — cannot evaluate the fail-open path"
else
  REPO=$(build_repo g)
  B0=$(sha "$REPO" "$BASE")
  echo strayS > "$REPO/stray.txt"
  git -C "$REPO" add stray.txt
  git -C "$REPO" commit -qm "S stray work"
  S=$(sha "$REPO" "$BASE")
  git -C "$REPO" branch feature/x "$S"
  git -C "$REPO" checkout -q feature/x
  # $BASE is additionally checked out in a LINKED worktree, so `git branch -f`
  # refuses it (rc=128). Neither recovery mechanism is legal: the guard must
  # fail OPEN on the existing token rather than claim a recovery it did not do.
  git -C "$REPO" worktree add -q "$WORKDIR/g-linked" "$BASE"
  run_guard "$REPO" "$BASE" "$B0" feature/x
  AFTER=$(sha "$REPO" "$BASE")
  HEAD_REF=$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
  if [ "$CODE" -ne 0 ]; then
    fail_msg "g: expected exit 0 (fail-open), got exit $CODE (out='$OUT')"
  elif [ "$OUT" != "BASE=error REASON=reset-failed" ]; then
    fail_msg "g: expected exactly 'BASE=error REASON=reset-failed', got '$OUT' (a false recovery claim)"
  elif [ "$AFTER" != "$S" ]; then
    fail_msg "g: '$BASE' mutated on the fail-open path ($S -> $AFTER)"
  elif [ "$HEAD_REF" != "feature/x" ]; then
    fail_msg "g: HEAD left feature/x (now '$HEAD_REF') on the fail-open path"
  else
    pass_msg "g: BASE=error REASON=reset-failed, exit 0, nothing mutated"
  fi
fi

# ===========================================================================
# Case (e): dispatch-contract grep test (Layer-1). Assert BOTH skill files carry
# the Layer-1 directive — a literal `git -C` occurrence AND a
# `symbolic-ref --short HEAD` branch-assert occurrence — so a dispatched agent
# anchors every git command at the worktree and asserts the branch before any
# commit (the #1106 root-cause fix). Static named-file grep only (mirrors
# tests/test-fullsend-split-role-dispatch.sh): never a whole-repo grep, never a
# version-literal compare, per CLAUDE.md release-hygiene.
echo "Case (e): both skill files carry the git -C + symbolic-ref --short HEAD dispatch directive"
FULLSEND="$REPO_ROOT/skills/fullsend/SKILL.md"
EXECUTE="$REPO_ROOT/skills/execute-issue-plan/SKILL.md"

# (e1) fullsend/SKILL.md
inc
if [ ! -f "$FULLSEND" ]; then
  fail_msg "e1: $FULLSEND not found"
elif ! grep -qF 'git -C' "$FULLSEND"; then
  fail_msg "e1: skills/fullsend/SKILL.md lacks the literal 'git -C' dispatch directive"
elif ! grep -qF 'symbolic-ref --short HEAD' "$FULLSEND"; then
  fail_msg "e1: skills/fullsend/SKILL.md lacks the 'symbolic-ref --short HEAD' branch-assert directive"
else
  pass_msg "e1: skills/fullsend/SKILL.md carries git -C + symbolic-ref --short HEAD"
fi

# (e2) execute-issue-plan/SKILL.md
inc
if [ ! -f "$EXECUTE" ]; then
  fail_msg "e2: $EXECUTE not found"
elif ! grep -qF 'git -C' "$EXECUTE"; then
  fail_msg "e2: skills/execute-issue-plan/SKILL.md lacks the literal 'git -C' dispatch directive"
elif ! grep -qF 'symbolic-ref --short HEAD' "$EXECUTE"; then
  fail_msg "e2: skills/execute-issue-plan/SKILL.md lacks the 'symbolic-ref --short HEAD' branch-assert directive"
else
  pass_msg "e2: skills/execute-issue-plan/SKILL.md carries git -C + symbolic-ref --short HEAD"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
