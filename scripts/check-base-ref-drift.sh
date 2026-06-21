#!/usr/bin/env bash
# check-base-ref-drift.sh <base-branch> <expected-sha> [feature-branch...]
#
# Layer-2 cause-agnostic base-ref drift guard (#1106).
# Compares the local base-branch SHA to <expected-sha> (snapshotted by the
# orchestrator before dispatch) and emits ONE token on stdout; ALWAYS exits 0
# (the verdict rides the token, mirroring verify-execute-completion.sh /
# split-role-gate.sh):
#
#   BASE=ok                       local base SHA == expected; no mutation.
#   BASE=recovered                drifted, but every stray commit in
#                                 origin/<base>..<local-base> is reachable
#                                 from at least one passed feature branch ->
#                                 git reset --hard origin/<base>.
#   BASE=drift-unsafe ORPHANS=<shas>
#                                 a stray commit is on NO feature branch ->
#                                 do NOT reset (would orphan committed work);
#                                 scoped halt + report.
#   BASE=error REASON=<...>       bad args / unresolvable ref; no mutation.
#                                 Fail-open: orchestrator relays advisory
#                                 without halting.
#
# Reachability predicate: stray commit C is safe iff
#   git merge-base --is-ancestor C <feature-branch>
# is true for SOME passed feature branch. ALL stray commits in
# origin/<base>..<local-base> must be safe for BASE=recovered; any orphan ->
# drift-unsafe.
#
# Never exits nonzero. Any internal failure path emits BASE=error REASON=<...>
# and exits 0 (fail-open advisory).

set -uo pipefail

# ---------------------------------------------------------------------------
# Arg validation

if [ "${#}" -lt 2 ]; then
  echo "BASE=error REASON=bad-args"
  exit 0
fi

BASE_BRANCH="$1"
EXPECTED_SHA="$2"
shift 2
FEATURE_BRANCHES=("$@")

# ---------------------------------------------------------------------------
# Resolve local and origin SHAs

LOCAL=$(git rev-parse --verify "$BASE_BRANCH" 2>/dev/null || true)
if [ -z "$LOCAL" ]; then
  echo "BASE=error REASON=unresolvable-base"
  exit 0
fi

ORIGIN=$(git rev-parse --verify "origin/$BASE_BRANCH" 2>/dev/null || true)
if [ -z "$ORIGIN" ]; then
  echo "BASE=error REASON=unresolvable-origin"
  exit 0
fi

# ---------------------------------------------------------------------------
# No drift

if [ "$LOCAL" = "$EXPECTED_SHA" ]; then
  echo "BASE=ok"
  exit 0
fi

# ---------------------------------------------------------------------------
# Drift detected: enumerate stray commits in origin/<base>..<local>

STRAYS=()
while IFS= read -r sha; do
  [ -n "$sha" ] && STRAYS+=("$sha")
done < <(git rev-list "origin/${BASE_BRANCH}..${LOCAL}" 2>/dev/null || true)

if [ "${#STRAYS[@]}" -eq 0 ]; then
  # local is behind origin — no stray commits from our side; not our drift
  echo "BASE=ok"
  exit 0
fi

# ---------------------------------------------------------------------------
# Reachability check: classify each stray as safe (reachable from a feature
# branch) or orphan (reachable from no feature branch).

ORPHANS=()
for C in "${STRAYS[@]}"; do
  SAFE=0
  for FB in "${FEATURE_BRANCHES[@]}"; do
    if git merge-base --is-ancestor "$C" "$FB" 2>/dev/null; then
      SAFE=1
      break
    fi
  done
  if [ "$SAFE" -eq 0 ]; then
    ORPHANS+=("$C")
  fi
done

# ---------------------------------------------------------------------------
# Act on verdict

if [ "${#ORPHANS[@]}" -gt 0 ]; then
  ORPHAN_LIST="${ORPHANS[*]}"
  echo "BASE=drift-unsafe ORPHANS=${ORPHAN_LIST// /,}"
  exit 0
fi

# Every stray is reachable from a feature branch — safe to recover.
git reset --hard "origin/${BASE_BRANCH}" >/dev/null 2>&1 || {
  echo "BASE=error REASON=reset-failed"
  exit 0
}
echo "BASE=recovered"
exit 0
