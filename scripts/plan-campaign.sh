#!/bin/bash
set -euo pipefail

# plan-campaign.sh (#835) — partition a set of approved issues into "legs" for
# campaign-mode dispatch. A leg is a batch of issues that may run together,
# bounded by per-path-class caps and constrained by dependency order and
# same-leg file conflicts.
#
# Edge source: shells out to scripts/plan-waves.sh --stage=execute --emit-edges
# (a sibling path), parsing each `EDGE #<N> blockers=<csv-or-"-">
# files=<csv-or-"-">` line into per-issue blockers + files maps.
#
# Path class: each issue's labels are fetched via `gh issue view`; docs-only->A,
# quick-fix->D, multi-task->C, else->B. A+D form the AD pool, B+C the BC pool
# for cap accounting.
#
# Input:  issue numbers via argv (space-separated) OR stdin (newline-separated).
# Output (default): one line per leg on stdout:
#            Leg 1: #1, #2 (BC=2 AD=0)
#            Leg 2: #3 (BC=1 AD=0) (serial -- blocked by #1)
#
# Subcommand: `plan-campaign.sh closure <blocked-issue> <issue-set...>` (or
# --closure=<N>) walks the edge map to a fixpoint and prints the closure issue
# numbers (newline-separated).

usage() {
  cat >&2 <<EOF
Usage: $0 [--max-bc=N] [--max-ad=N] <issue-num> [<issue-num> ...]
   or: echo "<num>\\n<num>" | $0 [--max-bc=N] [--max-ad=N]
   or: $0 closure <blocked-issue> <issue-num> [<issue-num> ...]
   or: $0 --closure=<blocked-issue> <issue-num> [<issue-num> ...]
EOF
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAVES="$SCRIPT_DIR/plan-waves.sh"

MAX_BC="${PIPELINE_CAMPAIGN_MAX_BC:-2}"
MAX_AD="${PIPELINE_CAMPAIGN_MAX_AD:-5}"
CLOSURE_TARGET=""

# ---- aggregate-signals subcommand (#863) ----
# Reads `SIGNAL issue=#<N> kind=<...> title="<conventional-commit title>"
# detail="<...>"` records on stdin, dedups by issue number against the open
# (--open=<csv>) and campaign-filed (--filed=<csv>) sets, groups survivors by
# conventional-commit <scope>, and emits one
#   CANDIDATE scope=<scope> issues=#a,#b title="<derived title>" kinds=<csv>
# line per surviving group. Pure read/stdout: no `gh`, no edits.
if [ "${1:-}" = "aggregate-signals" ]; then
  shift
  OPEN_CSV=""
  FILED_CSV=""
  for arg in "$@"; do
    case "$arg" in
      --open=*)  OPEN_CSV="${arg#--open=}" ;;
      --filed=*) FILED_CSV="${arg#--filed=}" ;;
      *) echo "plan-campaign aggregate-signals: unexpected arg: $arg" >&2; exit 1 ;;
    esac
  done

  # Drop-set membership lookup (open ∪ filed), keyed by bare issue number.
  declare -A DROP
  for n in $(printf '%s' "${OPEN_CSV},${FILED_CSV}" | tr ',' ' '); do
    n="${n#\#}"
    [ -n "$n" ] && DROP["$n"]=1
  done

  # Per-scope accumulation (insertion order preserved via SCOPE_ORDER).
  declare -A SC_ISSUES   # scope -> space-separated #N tokens
  declare -A SC_KINDS    # scope -> space-separated kinds
  declare -A SC_TITLE    # scope -> first title seen for the scope
  SCOPE_ORDER=""

  scope_of() {
    # echoes the conventional-commit <scope> token, or empty. Mirrors the
    # regex in find-grouping-candidates.sh so the two stay consistent.
    printf '%s' "$1" | sed -nE 's/^[a-z]+\(([a-z0-9_-]+)\):.*/\1/p'
  }

  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in
      "SIGNAL "*) ;;
      *) continue ;;
    esac

    # Parse fields. issue=#N kind=K title="..." detail="..."
    issue="${line#*issue=}"; issue="${issue%% *}"; issue="${issue#\#}"
    kind="${line#*kind=}"; kind="${kind%% *}"
    title="${line#*title=\"}"; title="${title%%\"*}"

    # Dedup against open ∪ filed sets (issue #0 / empty = "no number yet", never dropped).
    if [ -n "$issue" ] && [ "$issue" != "0" ] && [ -n "${DROP[$issue]+x}" ]; then
      continue
    fi

    scope="$(scope_of "$title")"
    [ -z "$scope" ] && scope="general"

    if [ -z "${SC_TITLE[$scope]+x}" ]; then
      SC_TITLE[$scope]="$title"
      SC_ISSUES[$scope]=""
      SC_KINDS[$scope]=""
      SCOPE_ORDER="$SCOPE_ORDER $scope"
    fi
    if [ -n "$issue" ] && [ "$issue" != "0" ]; then
      SC_ISSUES[$scope]="${SC_ISSUES[$scope]} #$issue"
    fi
    SC_KINDS[$scope]="${SC_KINDS[$scope]} $kind"
  done

  for scope in $SCOPE_ORDER; do
    # De-dup + join issues with commas.
    issues=$(printf '%s\n' ${SC_ISSUES[$scope]} | awk 'NF' | awk '!seen[$0]++' | paste -sd, -)
    # De-dup + join kinds with commas (preserve first-seen order).
    kinds=$(printf '%s\n' ${SC_KINDS[$scope]} | awk 'NF' | awk '!seen[$0]++' | paste -sd, -)
    printf 'CANDIDATE scope=%s issues=%s title="%s" kinds=%s\n' \
      "$scope" "$issues" "${SC_TITLE[$scope]}" "$kinds"
  done
  exit 0
fi

NEW_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --max-bc=*) MAX_BC="${arg#--max-bc=}" ;;
    --max-ad=*) MAX_AD="${arg#--max-ad=}" ;;
    --closure=*) CLOSURE_TARGET="${arg#--closure=}" ;;
    closure)
      CLOSURE_TARGET="__pending__"
      ;;
    *)
      if [ "$CLOSURE_TARGET" = "__pending__" ]; then
        CLOSURE_TARGET="$arg"
      else
        NEW_ARGS+=("$arg")
      fi
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
  echo "plan-campaign: PIPELINE_REPO is not set" >&2
  exit 1
fi

# ---- Recover the edge map from plan-waves.sh --emit-edges. ----
declare -A BLOCKERS   # issue -> space-separated issue numbers
declare -A FILES      # issue -> space-separated file paths

EDGE_OUT=$(bash "$WAVES" --stage=execute --emit-edges "${ISSUES[@]}")
while IFS= read -r line; do
  case "$line" in
    "EDGE #"*) ;;
    *) continue ;;
  esac
  # EDGE #<N> blockers=<csv-or-"-"> files=<csv-or-"-">
  n="${line#EDGE #}"; n="${n%% *}"
  b="${line#*blockers=}"; b="${b%% *}"
  f="${line#*files=}"
  [ "$b" = "-" ] && b=""
  [ "$f" = "-" ] && f=""
  BLOCKERS[$n]=$(echo "$b" | tr ',' ' ')
  FILES[$n]=$(echo "$f" | tr ',' ' ')
done <<< "$EDGE_OUT"

# ---- Path class per issue: docs-only->A, quick-fix->D, multi-task->C, else->B.
declare -A PCLASS
for N in "${ISSUES[@]}"; do
  if ! JSON=$(gh issue view "$N" --repo "$REPO" --json labels 2>/dev/null); then
    echo "plan-campaign: failed to fetch labels for issue #$N" >&2
    exit 1
  fi
  cls="B"
  if echo "$JSON" | jq -e '.labels[] | select(.name == "docs-only")' >/dev/null 2>&1; then
    cls="A"
  elif echo "$JSON" | jq -e '.labels[] | select(.name == "quick-fix")' >/dev/null 2>&1; then
    cls="D"
  elif echo "$JSON" | jq -e '.labels[] | select(.name == "multi-task")' >/dev/null 2>&1; then
    cls="C"
  fi
  PCLASS[$N]="$cls"
done

# Pool of a class: A,D -> AD ; B,C -> BC.
pool_of() {
  case "$1" in
    A|D) echo "AD" ;;
    *)   echo "BC" ;;
  esac
}

# Issues ordered numeric-ascending.
ORDERED=$( { for N in "${ISSUES[@]}"; do echo "$N"; done | sort -n | tr '\n' ' '; } || true)
ORDERED=$(echo "$ORDERED" | sed 's/[[:space:]]*$//')

# ---- closure subcommand: fixpoint walk over the edge map. ----
if [ -n "$CLOSURE_TARGET" ] && [ "$CLOSURE_TARGET" != "__pending__" ]; then
  declare -A IN_CLOSURE
  IN_CLOSURE[$CLOSURE_TARGET]=1
  MAX_ITERS=$(( ${#ISSUES[@]} + 5 ))
  ITER=0
  changed=1
  while [ "$changed" = "1" ]; do
    ITER=$((ITER + 1))
    if [ "$ITER" -gt "$MAX_ITERS" ]; then
      echo "plan-campaign: exceeded max iterations (cycle?)" >&2
      exit 1
    fi
    changed=0
    for N in $ORDERED; do
      [ -n "${IN_CLOSURE[$N]+x}" ] && continue
      add=0
      for B in ${BLOCKERS[$N]:-}; do
        if [ -n "${IN_CLOSURE[$B]+x}" ]; then add=1; break; fi
      done
      if [ "$add" = "0" ]; then
        for F in ${FILES[$N]:-}; do
          for M in $ORDERED; do
            [ -z "${IN_CLOSURE[$M]+x}" ] && continue
            for MF in ${FILES[$M]:-}; do
              if [ "$MF" = "$F" ]; then add=1; break; fi
            done
            [ "$add" = "1" ] && break
          done
          [ "$add" = "1" ] && break
        done
      fi
      if [ "$add" = "1" ]; then
        IN_CLOSURE[$N]=1
        changed=1
      fi
    done
  done
  for N in $ORDERED; do
    [ -n "${IN_CLOSURE[$N]+x}" ] && echo "$N"
  done
  if [ -z "$(echo "$ORDERED" | tr ' ' '\n' | grep -x "$CLOSURE_TARGET" || true)" ]; then
    echo "$CLOSURE_TARGET"
  fi
  exit 0
fi

# ---- Greedy leg partitioning. ----
declare -A PLACED_LEG   # issue -> leg number (1-based)
declare -A REASON       # issue -> reason for single-issue serial leg

PENDING="$ORDERED"
LEG=0
MAX_ITERS=$(( ${#ISSUES[@]} + 5 ))
ITER=0

declare -a LEG_MEMBERS    # leg -> space-separated issue numbers
declare -A LEG_FILES      # leg -> space-separated files claimed

while [ -n "$PENDING" ]; do
  ITER=$((ITER + 1))
  if [ "$ITER" -gt "$MAX_ITERS" ]; then
    echo "plan-campaign: exceeded max iterations (cycle?)" >&2
    exit 1
  fi
  LEG=$((LEG + 1))
  LEG_MEMBERS[$LEG]=""
  LEG_FILES[$LEG]=""
  bc_count=0
  ad_count=0
  NEXT_PENDING=""

  for N in $PENDING; do
    eligible=1
    reason=""

    # (1) cap check
    pool=$(pool_of "${PCLASS[$N]}")
    if [ "$pool" = "BC" ]; then
      if [ "$bc_count" -ge "$MAX_BC" ]; then eligible=0; fi
    else
      if [ "$ad_count" -ge "$MAX_AD" ]; then eligible=0; fi
    fi

    # (2) dependency order
    if [ "$eligible" = "1" ]; then
      for B in ${BLOCKERS[$N]:-}; do
        if [ -z "${PCLASS[$B]+x}" ]; then continue; fi
        if [ -z "${PLACED_LEG[$B]+x}" ] || [ "${PLACED_LEG[$B]}" = "$LEG" ]; then
          eligible=0
          reason="blocked by #$B"
          break
        fi
      done
    fi

    # (3) same-leg file conflict
    if [ "$eligible" = "1" ]; then
      for F in ${FILES[$N]:-}; do
        for G in ${LEG_FILES[$LEG]}; do
          if [ "$F" = "$G" ]; then
            owner=""
            for M in ${LEG_MEMBERS[$LEG]}; do
              for MF in ${FILES[$M]:-}; do
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
      LEG_MEMBERS[$LEG]="${LEG_MEMBERS[$LEG]} $N"
      LEG_FILES[$LEG]="${LEG_FILES[$LEG]} ${FILES[$N]:-}"
      PLACED_LEG[$N]=$LEG
      if [ "$pool" = "BC" ]; then bc_count=$((bc_count + 1)); else ad_count=$((ad_count + 1)); fi
    else
      NEXT_PENDING="$NEXT_PENDING $N"
      REASON[$N]="$reason"
    fi
  done

  LEG_MEMBERS[$LEG]=$(echo "${LEG_MEMBERS[$LEG]}" | sed 's/^[[:space:]]*//')
  NEXT_PENDING=$(echo "$NEXT_PENDING" | sed 's/^[[:space:]]*//')

  if [ -z "${LEG_MEMBERS[$LEG]}" ]; then
    echo "plan-campaign: no eligible issues this iteration -- aborting (cycle?)" >&2
    exit 1
  fi

  PENDING="$NEXT_PENDING"
done

# ---- Emit legs. ----
for K in $(seq 1 "$LEG"); do
  members=${LEG_MEMBERS[$K]}
  list=""
  count=0
  bc=0
  ad=0
  for N in $members; do
    if [ -z "$list" ]; then list="#$N"; else list="$list, #$N"; fi
    count=$((count + 1))
    if [ "$(pool_of "${PCLASS[$N]}")" = "BC" ]; then bc=$((bc + 1)); else ad=$((ad + 1)); fi
  done
  if [ "$count" -ge 2 ]; then
    echo "Leg $K: $list (BC=$bc AD=$ad)"
  else
    only=$members
    r="${REASON[$only]:-}"
    if [ -n "$r" ]; then
      echo "Leg $K: $list (BC=$bc AD=$ad) (serial -- $r)"
    else
      echo "Leg $K: $list (BC=$bc AD=$ad)"
    fi
  fi
done
