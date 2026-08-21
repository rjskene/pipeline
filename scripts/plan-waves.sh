#!/bin/bash
set -euo pipefail

# shellcheck source=scripts/_extract-body-paths.sh
. "$(dirname "${BASH_SOURCE[0]:-$0}")/_extract-body-paths.sh"

# plan-waves.sh — given a list of GitHub issue numbers, fetch each issue's
# metadata and emit a wave plan honoring (1) priority tiers, (2) explicit
# "blocked by #N" / "depends on #N" annotations, and (3) shared-file conflicts
# extracted from issue bodies. Reads $PIPELINE_REPO from the sourced
# pipeline.config (or env).
#
# Input:   issue numbers via argv (space-separated) OR stdin (newline-separated).
# Output:  one line per wave on stdout, verb reflecting --stage (classify|plan|execute):
#            Wave 1: <stage> #A, #B in parallel
#            Wave 2: <stage> #C (serial — shares <file> with #A)
#            Wave 3: <stage> #D (serial — blocked by #C)

usage() {
  cat >&2 <<EOF
Usage: $0 [--stage=classify|plan|execute] <issue-num> [<issue-num> ...]
   or: echo "<num>\\n<num>" | $0 [--stage=classify|plan|execute]
EOF
}

STAGE="execute"
EMIT_EDGES=0
NEW_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --stage=classify|--stage=plan|--stage=execute)
      STAGE="${arg#--stage=}"
      ;;
    --stage=*)
      echo "plan-waves: invalid --stage value: ${arg#--stage=} (expected classify|plan|execute)" >&2
      exit 1
      ;;
    --emit-edges)
      # Additive, opt-in machine-readable mode (#626). When set, the script
      # emits one EDGE line per input issue (in input order) carrying the
      # internally-computed BLOCKERS/FILES edges, then exits 0 BEFORE the
      # wave-building loop. The default human-readable path is untouched.
      EMIT_EDGES=1
      ;;
    *)
      NEW_ARGS+=("$arg")
      ;;
  esac
done
set -- "${NEW_ARGS[@]+"${NEW_ARGS[@]}"}"

ISSUES=()
if [ "$#" -gt 0 ]; then
  ISSUES=("$@")
else
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ISSUES+=("$line")
  done
fi

if [ "${#ISSUES[@]}" -eq 0 ]; then
  usage
  exit 1
fi

REPO="${PIPELINE_REPO:-}"
if [ -z "$REPO" ]; then
  echo "plan-waves: PIPELINE_REPO is not set" >&2
  exit 1
fi

# Per-issue scratch state, indexed by issue number.
declare -A PRIORITY        # P0|P1|P2|P3
declare -A BLOCKERS        # space-separated issue numbers
declare -A FILES           # space-separated file paths

# Path normalization + junk-token rejection (#1230) is provided by the
# shared scripts/_extract-body-paths.sh helper (sourced above) — FILE_PATH_RE,
# FILE_EXT_RE, and bp_normalize_tokens all come from there now, so a shallow
# reference (`plan-issue/SKILL.md`) and its deep counterpart
# (`skills/plan-issue/SKILL.md`) compare equal for conflict detection, and
# prose/cross-repo shapes (`**RED/GREEN`, `rjskene/work-orchestrator`,
# `rjskene/work-orchestrator#1537`) are dropped rather than harvested as file
# paths. See the plan comment on #1230 for the full design-decision writeup,
# and #1239 for the extraction of this logic into the shared helper.

# Fetch + parse each issue.
for N in "${ISSUES[@]}"; do
  if ! JSON=$(gh issue view "$N" --repo "$REPO" --json number,title,body,labels 2>/dev/null); then
    echo "plan-waves: failed to fetch issue #$N" >&2
    exit 1
  fi

  # Priority — first matching label of P0 > P1 > P2 > P3.
  P="P3"
  for tier in P0 P1 P2 P3; do
    if echo "$JSON" | jq -e --arg t "priority/$tier" '.labels[] | select(.name == $t)' >/dev/null; then
      P="$tier"
      break
    fi
  done
  PRIORITY[$N]="$P"

  BODY=$(echo "$JSON" | jq -r '.body // ""')

  # Blockers: "blocked by #N" or "depends on #N", case-insensitive.
  BLIST=$( { echo "$BODY" \
    | grep -iEo '(blocked by|depends on)[[:space:]]+#[0-9]+' \
    | grep -oE '#[0-9]+' \
    | tr -d '#' \
    | sort -u \
    | tr '\n' ' '; } || true)
  BLOCKERS[$N]="${BLIST% }"

  # Files: only the `execute` stage runs file-conflict detection; classify/plan
  # stages skip it (the body heuristic over-serializes cross-references).
  #
  # UNIFIED A/B/C/D CONFLICT GRAPH (#700): file-conflict detection here reads
  # ONLY the issue body / approved plan comment — it NEVER inspects the path
  # label (`quick-fix`/`docs-only`/`multi-task`). There is NO path-label gate
  # that exempts PATH D (`quick-fix`) issues from serialization. Consequence: a
  # PATH D issue whose declared file paths collide with an in-flight PATH B/C/A
  # issue serializes into a LATER wave exactly like any other issue. fullsend
  # dispatches D inline in the foreground (zero run-queue slots), but that is a
  # DISPATCH-mechanism choice downstream of waving — it does NOT exempt D from
  # wave discipline. Do NOT add a "skip D in conflict detection" branch here:
  # tests/test-plan-waves-unified-graph.sh locks this contract.
  if [ "$STAGE" = "execute" ]; then
    # Path predicate (#811 + #1006): hoisted above both branches so the same
    # predicate guards plan-comment extraction AND body-fallback extraction.
    # A token counts as a file path only when it is a single whitespace-free
    # path-shaped token: either a `dir/file` shape (slash + non-empty non-slash
    # filename segment) OR an anchored known extension. This rejects bare
    # reason-symbols like `data.map`, `next_due`, `sort` that lack a slash and
    # have no known file extension — while catching bare paths like
    # `assets/dashboard/pages/legal.page.js` whether or not they are backticked.
    # FILE_PATH_RE itself is sourced from scripts/_extract-body-paths.sh above.

    # Prefer plan-comment "**Files to change:**" bullets (exact paths from the
    # approved plan) over body-derived backticks (greedy + noisy). Fall back to
    # body detection when no plan comment exists.
    PLAN_FILES=""
    if PLAN_JSON=$(gh issue view "$N" --repo "$REPO" --json comments 2>/dev/null); then
      PLAN_BODY=$(echo "$PLAN_JSON" \
        | jq -r '[.comments[] | select(.body | contains("## Implementation Plan"))] | last | .body // ""')
      if [ -n "$PLAN_BODY" ] && [ "$PLAN_BODY" != "null" ]; then
        # Extract bullets from the **Files to change:** block, then split each
        # bullet on whitespace, strip backticks, and keep only FILE_PATH_RE-
        # matching tokens (#1006), normalized + deduped (#1230). Sourced from
        # the shared helper (#1239). Guard the pipeline so an all-empty result
        # yields "" not a pipefail abort (#730).
        PLAN_FILES=$( { bp_plan_files "$PLAN_BODY" | tr '\n' ' '; } || true)
        PLAN_FILES="${PLAN_FILES% }"
      fi
    fi
    if [ -n "$PLAN_FILES" ]; then
      FILES[$N]="$PLAN_FILES"
    else
      FLIST=$( { bp_body_paths "$BODY" | tr '\n' ' '; } || true)
      FILES[$N]="${FLIST% }"
    fi
  else
    FILES[$N]=""
  fi
done

# --emit-edges (#626): machine-readable edge recovery. Emit one line per input
# issue, in input order, regardless of how issues are later grouped into waves
# (the human-readable path only surfaces per-issue reasons for SINGLE-issue
# waves, so a multi-issue-wave member would otherwise lose its edge). Format:
#   EDGE #<N> blockers=<csv-of-issue-numbers-or-"-"> files=<csv-of-paths-or-"-">
# Empty blockers/files render as "-". Then exit 0 -- no Wave lines are printed.
if [ "$EMIT_EDGES" = "1" ]; then
  for N in "${ISSUES[@]}"; do
    blockers="${BLOCKERS[$N]:-}"
    files="${FILES[$N]:-}"
    if [ -n "$blockers" ]; then
      blockers=$(echo "$blockers" | tr ' ' ',')
    else
      blockers="-"
    fi
    if [ -n "$files" ]; then
      files=$(echo "$files" | tr ' ' ',')
    else
      files="-"
    fi
    echo "EDGE #$N blockers=$blockers files=$files"
  done
  exit 0
fi

# Build waves greedily, high priority tier first, then by issue number ascending.
declare -A PLACED       # issue -> wave number
declare -a WAVES        # wave_index -> space-separated list of issue numbers (ordered)
declare -A WAVE_FILES   # wave_index -> space-separated files claimed
declare -A REASON       # issue -> reason string (or empty)

# Order issues: priority tier high→low, then numeric ascending.
prio_rank() {
  case "$1" in
    P0) echo 0;; P1) echo 1;; P2) echo 2;; *) echo 3;;
  esac
}

# Process tiers high→low. Within a tier, run a greedy fill-waves loop until
# all issues in that tier are placed. Issues of a lower tier start in a fresh
# wave (cannot join a wave that contains a higher-tier issue, even if there's
# no file conflict — keeps priority semantics strict).
WAVE=0
MAX_ITERS=$(( ${#ISSUES[@]} + 5 ))

for TIER in P0 P1 P2 P3; do
  TIER_ISSUES=$( { for N in "${ISSUES[@]}"; do
    if [ "${PRIORITY[$N]}" = "$TIER" ]; then echo "$N"; fi
  done | sort -n | tr '\n' ' '; } || true)
  TIER_ISSUES=$(echo "$TIER_ISSUES" | sed 's/[[:space:]]*$//')
  if [ -z "$TIER_ISSUES" ]; then continue; fi

  PENDING=$TIER_ISSUES
  ITER=0
  while [ -n "$PENDING" ] && [ "$ITER" -lt "$MAX_ITERS" ]; do
    ITER=$((ITER + 1))
    WAVE=$((WAVE + 1))
    WAVES[$WAVE]=""
    WAVE_FILES[$WAVE]=""
    NEXT_PENDING=""

    for N in $PENDING; do
      eligible=1
      reason=""

      for B in ${BLOCKERS[$N]}; do
        # Dangling blocker: $B is not in the input set (no PRIORITY entry) →
        # treat as already satisfied. Otherwise: defer if not yet placed OR
        # placed in the current wave.
        if [ -z "${PRIORITY[$B]+x}" ]; then
          continue
        fi
        if [ -z "${PLACED[$B]+x}" ] || [ "${PLACED[$B]}" = "$WAVE" ]; then
          eligible=0
          reason="blocked by #$B"
          break
        fi
      done

      if [ "$eligible" = "1" ]; then
        for F in ${FILES[$N]}; do
          for G in ${WAVE_FILES[$WAVE]}; do
            if [ "$F" = "$G" ]; then
              owner=""
              for M in ${WAVES[$WAVE]}; do
                for MF in ${FILES[$M]}; do
                  if [ "$MF" = "$F" ]; then owner="$M"; break; fi
                done
                [ -n "$owner" ] && break
              done
              eligible=0
              reason="shares $F with #$owner"
              break
            fi
          done
          [ "$eligible" = "0" ] && break
        done
      fi

      if [ "$eligible" = "1" ]; then
        WAVES[$WAVE]="${WAVES[$WAVE]} $N"
        WAVE_FILES[$WAVE]="${WAVE_FILES[$WAVE]} ${FILES[$N]}"
        PLACED[$N]=$WAVE
        # Preserve any reason that caused earlier deferral; do not clear.
      else
        NEXT_PENDING="$NEXT_PENDING $N"
        REASON[$N]="$reason"
      fi
    done

    WAVES[$WAVE]=$(echo "${WAVES[$WAVE]}" | sed 's/^[[:space:]]*//')
    WAVE_FILES[$WAVE]=$(echo "${WAVE_FILES[$WAVE]}" | sed 's/^[[:space:]]*//')
    NEXT_PENDING=$(echo "$NEXT_PENDING" | sed 's/^[[:space:]]*//')

    if [ -z "${WAVES[$WAVE]}" ]; then
      echo "plan-waves: no eligible issues this iteration — aborting (cycle?)" >&2
      exit 1
    fi

    PENDING=$NEXT_PENDING
  done

  if [ "$ITER" -ge "$MAX_ITERS" ] && [ -n "$PENDING" ]; then
    echo "plan-waves: exceeded max iterations in tier $TIER: $PENDING" >&2
    exit 1
  fi
done

# Final wave count is current $WAVE.
LAST_WAVE=$WAVE

# Emit waves.
for W in $(seq 1 "$LAST_WAVE"); do
  ISSUES_IN_WAVE=${WAVES[$W]}
  # Build comma-separated "#N" list preserving placement order.
  LIST=""
  COUNT=0
  for N in $ISSUES_IN_WAVE; do
    if [ -z "$LIST" ]; then
      LIST="#$N"
    else
      LIST="$LIST, #$N"
    fi
    COUNT=$((COUNT + 1))
  done

  if [ "$COUNT" -ge 2 ]; then
    echo "Wave $W: $STAGE $LIST in parallel"
  else
    # Single issue in wave — append reason (if any) in parens.
    only=$ISSUES_IN_WAVE
    r="${REASON[$only]:-}"
    if [ -n "$r" ]; then
      echo "Wave $W: $STAGE #$only (serial — $r)"
    else
      echo "Wave $W: $STAGE #$only in parallel"
    fi
  fi
done
