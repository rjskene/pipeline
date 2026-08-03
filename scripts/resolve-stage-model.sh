#!/usr/bin/env bash
# Single-source per-stage model resolver (issue #1186).
#
# The three QUALITY-CRITICAL dispatched stages — `plan`, `plan-eval`, `pr-eval`
# — carried NO `model=` at all before #1186: they silently INHERITED the
# orchestrator session model. That made the load-bearing W3 property ("pr-eval
# is always Opus") an inheritance SIDE-EFFECT rather than a pin. The moment the
# session model stops being Opus (a Fable-ceiling session), every one of those
# sites silently upshifts — doubling the most expensive lanes and routing the
# security-adjacent W2 carve-out onto the model most likely to return
# `stop_reason: refusal` mid-gate. An auto-merge gate that can refuse mid-verdict
# on exactly the high-uncertainty PRs is a broken gate.
#
# This script replaces the assumption with an explicit pin. It mirrors
# scripts/resolve-execute-dispatch.sh (the #1056 lesson: prose drifts, scripts
# don't): the routing rules are encoded ONCE here and the skill read-sites
# consume the emitted tokens verbatim.
#
# Emits one token per line on stdout and ALWAYS exits 0 in normal operation (the
# verdict rides the tokens). Exit 2 is reserved for a usage error.
#
#   ISSUE=<N>
#   STAGE=<plan|plan-eval|pr-eval>
#   PATH=<A|B|C|D>
#   MODEL=<fable|opus|sonnet|haiku>   # ALWAYS named; `inherit` is NEVER emitted
#   REASON=<default-pin|path-c-fable|follows-producer|high-uncertainty|explicit-knob>
#
# === Encoded routing rules (the single place the stage knobs + carve-outs apply) ===
#
#   pr-eval   -> ${PIPELINE_STAGE_MODEL_PR_EVAL:-opus}. No carve-out lowers it.
#               An explicitly-set knob BELOW the resolved EXECUTE tier is
#               HONORED verbatim (REASON=explicit-knob) but emits a stderr WARN:
#               an operator override is allowed, silence is not. The execute tier
#               for that comparison comes from resolve-execute-dispatch.sh — the
#               SAME single source the execute dispatch consumes.
#   plan      -> PATH C ⇒ ${PIPELINE_PATH_C_MODEL_PLAN:-fable} (cross-unit
#               meshing across leaf worktrees is Fable's documented edge, and a
#               bad split is the pipeline's most expensive failure mode);
#               PATH A/B ⇒ opus (per-unit depth is Opus territory). PATH D is
#               never dispatched through this resolver (its collapsed inline
#               dispatch carries the resolved EXECUTE model) but resolves
#               defensively rather than erroring.
#               W2 high-uncertainty ⇒ opus, REASON=high-uncertainty — overriding
#               BOTH the fable default AND an explicit knob. For PATH C plan
#               that is a deliberate DOWNGRADE: security-vocab issues on Fable
#               risk `stop_reason: refusal` mid-pipeline and Fable's documented
#               review gains explicitly exclude security analysis. The carve-out
#               wins, same precedence as the execute resolver's W2 branch.
#   plan-eval -> tier-max(this issue's resolved plan model,
#               ${PIPELINE_STAGE_MODEL_PLAN_EVAL:-opus}) so the GATE NEVER lands
#               below its PRODUCER (plan approval is an auto-gate with no human
#               behind it in fullsend; equal tier is fine — the evaluator's value
#               is independent context — below is not).
#               REASON=follows-producer when the producer tier decided it,
#               explicit-knob when a set knob did, else default-pin.
#
# Tier order for max/WARN comparisons: haiku(1) < sonnet(2) < opus(3) < fable(4).
# An unrecognized knob token is honored VERBATIM in MODEL= (fail-loud at Agent
# dispatch) and compares as tier 0.
#
# PATH detection mirrors plan-issue Step 3a label precedence — `docs-only`⇒A,
# `quick-fix`⇒D, `multi-task`⇒C, else B — from ONE `gh issue view` fetch, which
# also feeds the W2 match. The high-uncertainty regex is REUSED from
# scripts/_high-uncertainty-match.sh and is NEVER redefined here (bug #1039).
#
# The EXECUTE stage is NOT resolved here: use
# scripts/resolve-execute-dispatch.sh <N> <A|B|C|D>.

set -uo pipefail

usage() {
  echo "Usage: $0 <issue-number> <plan|plan-eval|pr-eval>" >&2
  echo "  Resolves the explicit model pin for a dispatched plan / plan-eval / pr-eval stage." >&2
  echo "  MODEL= is ALWAYS a named model (fable|opus|sonnet|haiku); 'inherit' is never emitted." >&2
  echo "  The execute stage is resolved by scripts/resolve-execute-dispatch.sh <N> <A|B|C|D>." >&2
}

if [ $# -lt 2 ]; then
  usage
  exit 2
fi

N="$1"
STAGE="$2"

case "$STAGE" in
  plan|plan-eval|pr-eval) ;;
  *)
    usage
    exit 2
    ;;
esac

# --- Self-resolve config (export-on-source) ---------------------------------
# Same pattern as resolve-execute-dispatch.sh: source the co-located
# _resolve-config.sh so PIPELINE_STAGE_MODEL_PR_EVAL /
# PIPELINE_STAGE_MODEL_PLAN_EVAL / PIPELINE_PATH_C_MODEL_PLAN are available even
# when callers source-but-don't-export them.
_rsm_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
if [ -f "${_rsm_dir}/_resolve-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  source "${_rsm_dir}/_resolve-config.sh"
fi

REPO="${PIPELINE_REPO:-}"

# --- ONE issue fetch: feeds BOTH the path detection and the W2 match ---------
RAW="$(gh issue view "$N" --repo "$REPO" --json title,body,labels 2>/dev/null || true)"
TITLE="$(printf '%s' "$RAW" | jq -r '.title // ""' 2>/dev/null || true)"
BODY="$(printf '%s' "$RAW" | jq -r '.body // ""' 2>/dev/null || true)"
LABELS="$(printf '%s' "$RAW" | jq -r '[.labels[].name] | join(" ")' 2>/dev/null || true)"

# PATH detection — label precedence mirrors plan-issue Step 3a.
PATH_LETTER="B"
if printf '%s\n' "$LABELS" | grep -iqwE 'docs-only'; then
  PATH_LETTER="A"
elif printf '%s\n' "$LABELS" | grep -iqwE 'quick-fix'; then
  PATH_LETTER="D"
elif printf '%s\n' "$LABELS" | grep -iqwE 'multi-task'; then
  PATH_LETTER="C"
fi

# W2 high-uncertainty carve-out — DIRECT match of the shared regex against
# title+body+labels. REUSE the helper; do NOT redefine the regex (bug #1039).
# shellcheck source=scripts/_high-uncertainty-match.sh
. "${_rsm_dir}/_high-uncertainty-match.sh"
W2=0
if printf '%s\n%s\n%s\n' "$TITLE" "$BODY" "$LABELS" | grep -iEq "$HIGH_UNCERTAINTY_RE"; then
  W2=1
fi

# --- Tier ladder -------------------------------------------------------------
tier() {
  case "$1" in
    haiku)  printf '1' ;;
    sonnet) printf '2' ;;
    opus)   printf '3' ;;
    fable)  printf '4' ;;
    *)      printf '0' ;;   # unrecognized token: honored verbatim, tier 0
  esac
}

MODEL=""
REASON=""

# --- plan ---------------------------------------------------------------------
# Sets PLAN_MODEL / PLAN_REASON. Also consumed by the plan-eval branch so the
# gate can follow its producer (the rule is encoded ONCE).
PLAN_MODEL=""
PLAN_REASON=""
resolve_plan() {
  local knob=""
  if [ "$PATH_LETTER" = "C" ]; then
    knob="${PIPELINE_PATH_C_MODEL_PLAN:-}"
    if [ -n "$knob" ]; then
      PLAN_MODEL="$knob"; PLAN_REASON="explicit-knob"
    else
      PLAN_MODEL="fable"; PLAN_REASON="path-c-fable"
    fi
  else
    # PATH A/B (and the defensive PATH D case): the opus quality floor.
    PLAN_MODEL="opus"; PLAN_REASON="default-pin"
  fi
  # W2 refusal-risk carve-out wins over the default AND over an explicit knob.
  if [ "$W2" = "1" ]; then
    PLAN_MODEL="opus"; PLAN_REASON="high-uncertainty"
  fi
}

case "$STAGE" in
  plan)
    resolve_plan
    MODEL="$PLAN_MODEL"; REASON="$PLAN_REASON"
    ;;

  plan-eval)
    # Gate never below producer: tier-max(plan model, plan-eval knob).
    resolve_plan
    GATE_KNOB="${PIPELINE_STAGE_MODEL_PLAN_EVAL:-}"
    if [ -n "$GATE_KNOB" ]; then
      GATE_MODEL="$GATE_KNOB"; GATE_REASON="explicit-knob"
    else
      GATE_MODEL="opus"; GATE_REASON="default-pin"
    fi
    if [ "$(tier "$PLAN_MODEL")" -gt "$(tier "$GATE_MODEL")" ]; then
      MODEL="$PLAN_MODEL"; REASON="follows-producer"
    else
      MODEL="$GATE_MODEL"; REASON="$GATE_REASON"
    fi
    ;;

  pr-eval)
    # W3 as a real pin. No carve-out can lower it; only an explicit operator
    # knob can, and never silently.
    PR_KNOB="${PIPELINE_STAGE_MODEL_PR_EVAL:-}"
    if [ -n "$PR_KNOB" ]; then
      MODEL="$PR_KNOB"; REASON="explicit-knob"
      # Compare against the EXECUTE tier resolved by the same single source the
      # execute dispatch consumes. A gate below its producer is exactly the
      # failure this design exists to prevent — honored, but never silent.
      EXEC_SPEC="$(PIPELINE_REPO="$REPO" bash "${_rsm_dir}/resolve-execute-dispatch.sh" "$N" "$PATH_LETTER" 2>/dev/null || true)"
      EXEC_MODEL="$(printf '%s\n' "$EXEC_SPEC" | sed -n 's/^MODEL=\(.*\)$/\1/p' | head -1)"
      if [ -n "$EXEC_MODEL" ] && [ "$(tier "$MODEL")" -lt "$(tier "$EXEC_MODEL")" ]; then
        echo "WARN: PIPELINE_STAGE_MODEL_PR_EVAL=$MODEL is BELOW the resolved PATH $PATH_LETTER execute tier ($EXEC_MODEL) for issue $N — the pr-eval gate is running under its producer. Override honored; fix the knob or accept a weaker auto-merge gate." >&2
      fi
    else
      MODEL="opus"; REASON="default-pin"
    fi
    ;;
esac

echo "ISSUE=$N"
echo "STAGE=$STAGE"
echo "PATH=$PATH_LETTER"
echo "MODEL=$MODEL"
echo "REASON=$REASON"
exit 0
