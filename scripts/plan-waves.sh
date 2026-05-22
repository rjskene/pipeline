#!/bin/bash
set -euo pipefail

# plan-waves.sh — given a list of GitHub issue numbers, fetch each issue's
# metadata and emit a wave plan honoring (1) priority tiers, (2) explicit
# "blocked by #N" / "depends on #N" annotations, and (3) shared-file conflicts
# extracted from issue bodies. Reads $PIPELINE_REPO from the sourced
# pipeline.config (or env).
#
# Input:   issue numbers via argv (space-separated) OR stdin (newline-separated).
# Output:  one line per wave on stdout:
#            Wave 1: classify #A, #B in parallel
#            Wave 2: classify #C (serial — shares <file> with #A)
#            Wave 3: classify #D (serial — blocked by #C)

usage() {
  cat >&2 <<EOF
Usage: $0 [--stage=classify|plan|execute] <issue-num> [<issue-num> ...]
   or: echo "<num>\\n<num>" | $0 [--stage=classify|plan|execute]
EOF
}

STAGE="execute"
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

  # Files: backticked tokens that look like paths (contain "/" or end in a
  # known suffix), PLUS any non-empty line under an "## Affected areas" header.
  # Only the `execute` stage runs file-conflict detection; classify/plan stages
  # skip it (the body-substring heuristic over-serializes cross-references).
  if [ "$STAGE" = "execute" ]; then
    FROM_BACKTICKS=$( { echo "$BODY" \
      | grep -oE '`[^`]+`' \
      | tr -d '`' \
      | grep -E '/|\.(md|sh|py|json|yml|yaml|ts|tsx|js|jsx|go)$'; } || true)
    FROM_AFFECTED=$(echo "$BODY" \
      | awk 'BEGIN{IGNORECASE=1; in_block=0}
             /^##[[:space:]]+Affected areas/ {in_block=1; next}
             in_block && /^##/ {in_block=0}
             in_block && NF>0 {print}')
    FLIST=$( { printf '%s\n%s\n' "$FROM_BACKTICKS" "$FROM_AFFECTED" \
      | sed 's/[[:space:]]\+/\n/g' \
      | grep -E '/|\.(md|sh|py|json|yml|yaml|ts|tsx|js|jsx|go)$' \
      | sort -u \
      | tr '\n' ' '; } || true)
    FILES[$N]="${FLIST% }"
  else
    FILES[$N]=""
  fi
done

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
    echo "Wave $W: classify $LIST in parallel"
  else
    # Single issue in wave — append reason (if any) in parens.
    only=$ISSUES_IN_WAVE
    r="${REASON[$only]:-}"
    if [ -n "$r" ]; then
      echo "Wave $W: classify #$only (serial — $r)"
    else
      echo "Wave $W: classify #$only in parallel"
    fi
  fi
done
