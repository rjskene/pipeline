#!/usr/bin/env bash
# Single-source execute dispatch-spec resolver (issue #1056).
#
# THE root cause of #1056 was TWO sources of truth for the inline execute
# dispatch decision: the #1042/#881 config knobs, and the hand-applied prose in
# skills/fullsend/SKILL.md Step 6 that the orchestrator was expected to apply by
# hand on each dispatch. The two drifted — on a real campaign the orchestrator
# dispatched every PATH B/D execute Agent WITHOUT a `model=`, silently inheriting
# Opus and defeating the entire #1042 cheaper-execute default. There was no
# machine-resolvable mechanism for the inline path (the `--spawn` run-queue
# transport already threads `--model` config-aware via spawn-claude.sh; the
# inline foreground batch — the post-#748/#749/#750 DEFAULT — had no equivalent).
#
# This script IS that mechanism. Given an issue + a path letter (A|B|C|D), it
# emits the FULL dispatch spec — the execute `model=` plus an advisory
# eligibility/scope/reason audit — so skills/fullsend/SKILL.md Step 6 consumes ONE
# emitted spec instead of re-deriving the decision in prose.
# skills/campaign/SKILL.md inherits this by reference (it defers to fullsend's
# `## Campaign mode`).
#
# Emits one token per line on stdout and ALWAYS exits 0 in normal operation (the
# verdict rides the tokens, mirroring scripts/path-b-execute-eligible.sh). Exit 2
# is reserved for a usage error.
#
#   ISSUE=<N>
#   PATH=<A|B|C|D>
#   MODEL=<sonnet|opus|haiku|fable>     # the model= to pass to the execute Agent.
#                                       # ALWAYS a NAMED model (#1186) — `inherit`
#                                       # is NOT a valid emission.
#   ROLES=single                        # #1420: the ONLY dispatch shape
#   SCOPE=<all|low-blast>               # resolved PIPELINE_PATH_B_ELIGIBLE_SCOPE (B only)
#   ELIGIBLE=<low-blast|high-blast>     # advisory passthrough from
#                                       # path-b-execute-eligible.sh (B only)
#   REASON=<token>                      # why MODEL resolved as it did (audit)
#
# REASON tokens: default-sonnet | default-opus | explicit-knob | high-uncertainty
#                | needs-browser | scope-low-blast-gated
#
# #1420 — the #881 two-agent PATH B execute lane is GONE, and with it the SHAPE
# half of this resolver's contract. PATH B used to dispatch TWO sequential agents
# (an always-Opus test-author committing the complete locked failing suite, then a
# cheaper implementer greening it additive-only under an eval-time git invariant),
# and this resolver emitted that pairing as its own boolean key plus
# `ROLES=red:opus,green:<model>`. Calibration runs #11-#13 measured NO cost or
# latency return for the redundancy, so every path now dispatches ONE execute
# agent: `ROLES=single` unconditionally, and the boolean key is REMOVED outright
# rather than pinned to false — a surviving `false` emission would keep every
# downstream parser reading a dead token. Three consequences:
#   - The #881 shape knob is no longer read. A stale value in a consumer's config
#     is SILENTLY ignored, with no WARN: there is nothing left to opt out of, and
#     warning on it would fire on every dispatch of every #1057-era config until
#     the operator edits a file this upgrade does not otherwise require touching.
#   - PATH B's unset-knob default flips sonnet -> `opus` (REASON=default-opus). The
#     Opus test-author was what made a cheap implementer safe; collapsing to one
#     agent without raising its model would have quietly lowered the quality floor
#     rather than merely removing a redundancy. Reversible per-consumer via
#     PIPELINE_PATH_B_MODEL_EXECUTE=sonnet. PATH D is UNCHANGED — it was never a
#     two-agent lane, so it lost nothing to compensate for.
#   - scripts/_trust-profile.sh is no longer sourced: `lean`'s execute half existed
#     only to collapse that pair, which is now the unconditional shape.
#     scripts/resolve-stage-model.sh still sources it for the plan-eval half.
#
# #1186 — `inherit` is RETIRED as an emission. "Inherit the strong safe model"
# was only ever true while the session model WAS the strong safe model; under a
# Fable-ceiling session an unpinned dispatch silently becomes Fable, so every
# carve-out now NAMES the model it always meant (`opus`). The resolver also
# accepts PATH A and PATH C, which previously dispatched with no `model=` at all
# because no knob existed for them.
#
# === Encoded routing rules (the single place the knobs + carve-outs apply) ===
#
#   #1042 model knob — read PIPELINE_PATH_{B,D}_MODEL_EXECUTE. An explicit value
#     (opus|haiku|sonnet) is honored verbatim. Unset/empty ⇒ effective `sonnet`
#     for PATH D; #1420 flipped PATH B's unset default to `opus`
#     (REASON=default-opus) when the split lane's Opus test-author was removed.
#   #1186 PATH A/C model knob — read PIPELINE_PATH_{A,C}_MODEL_EXECUTE.
#     Unset/empty ⇒ effective `opus` (REASON=default-opus — execute's quality
#     ceiling, which is what those dispatches silently assumed they were getting
#     from the session model). An explicit value is honored verbatim
#     (REASON=explicit-knob), consistent with the B/D rule. A/C run NO
#     eligibility predicate and NO W2/needs-browser carve-outs — the default IS
#     already the carve-out target — so they emit neither SCOPE= nor ELIGIBLE=.
#     For PATH C the resolved model applies to EVERY `target=<dir>` leaf dispatch.
#   PIPELINE_PATH_B_ELIGIBLE_SCOPE — default `all`. Under `all`, every non-W2
#     PATH B routes the resolved model even on a high-blast eligibility verdict.
#     Under `low-blast`, the resolved model is passed ONLY when
#     path-b-execute-eligible.sh returns low-blast; high-blast ⇒ pinned `opus`.
#     (Since #1420 flipped the B default to `opus`, this gate only bites a consumer
#     who explicitly opted down to a cheaper model.)
#   W2 always-Opus carve-out — detected via the SAME machinery the existing
#     read-site uses: path-b-execute-eligible.sh's REASON=high-uncertainty token
#     (PATH B), and a DIRECT match of $HIGH_UNCERTAINTY_RE from
#     scripts/_high-uncertainty-match.sh against title+body+labels (PATH D, which
#     never calls the B-only eligibility script). The regex is NEVER redefined
#     here — that was bug #1039.
#   needs-browser PATH-D always-Opus carve-out (#960) — PATH D + the
#     `needs-browser` label ⇒ MODEL=opus. For PATH B, needs-browser surfaces as
#     path-b-execute-eligible.sh's REASON=needs-browser and is treated as a
#     W2-equivalent carve-out (→ Opus), per fullsend's read-site.
#   W3 pr-eval-never-Sonnet — STRUCTURAL: this resolver has NO pr-eval mode and
#     REFUSES any argument that is not a path letter (exit 2), stage words
#     included. It therefore physically cannot emit a model for pr-eval. Since
#     #1186 the independent evaluator is PINNED `opus` via
#     PIPELINE_STAGE_MODEL_PR_EVAL (scripts/resolve-stage-model.sh <N> pr-eval)
#     rather than riding an inherited session model; pr-eval is still NEVER
#     routed through this resolver.
#   #881 two-agent PATH B lane — RETIRED by #1420 (see the note above). No shape
#     knob is read, no shape boolean is emitted, and no trust-profile helper is
#     sourced.

set -uo pipefail

usage() {
  echo "Usage: $0 <issue-number> <A|B|C|D>" >&2
  echo "  Resolves the inline execute dispatch spec for a PATH A/B/C/D issue." >&2
  echo "  pr-eval (and every other stage word) is NEVER routed here (W3) — use" >&2
  echo "  scripts/resolve-stage-model.sh <N> <plan|plan-eval|pr-eval> instead." >&2
}

if [ $# -lt 2 ]; then
  usage
  exit 2
fi

N="$1"
PATH_LETTER="$2"

# W3 structural guard: accept ONLY a path letter. Stage words (pr-eval/plan/
# plan-eval) and anything else are refused — the resolver physically cannot
# resolve a model for the independent evaluator.
case "$PATH_LETTER" in
  A|B|C|D) ;;
  *)
    usage
    exit 2
    ;;
esac

# --- Self-resolve config (export-on-source) ---------------------------------
# Same pattern as verify-execute-completion.sh: source the co-located
# _resolve-config.sh so PIPELINE_PATH_{A,B,C,D}_MODEL_EXECUTE /
# PIPELINE_PATH_B_ELIGIBLE_SCOPE are available even when callers
# source-but-don't-export them.
_red_dir="$(dirname "${BASH_SOURCE[0]:-$0}")"
if [ -f "${_red_dir}/_resolve-config.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  source "${_red_dir}/_resolve-config.sh"
fi

# #1420: scripts/_trust-profile.sh is deliberately NOT sourced here. Its execute
# half only ever collapsed the #881 two-agent pair, which is now the unconditional
# shape, so a read would be a knob with no effect. scripts/resolve-stage-model.sh
# still sources it for the surviving plan-eval half.

REPO="${PIPELINE_REPO:-}"

# --- Resolve knobs (#1042 / #1420 defaults) ---------------------------------
SCOPE="${PIPELINE_PATH_B_ELIGIBLE_SCOPE:-all}"

case "$PATH_LETTER" in
  A) KNOB="${PIPELINE_PATH_A_MODEL_EXECUTE:-}" ;;
  B) KNOB="${PIPELINE_PATH_B_MODEL_EXECUTE:-}" ;;
  C) KNOB="${PIPELINE_PATH_C_MODEL_EXECUTE:-}" ;;
  *) KNOB="${PIPELINE_PATH_D_MODEL_EXECUTE:-}" ;;
esac
# #1042: unset/empty ⇒ effective sonnet for D (the shipped opt-out default).
# #1186: unset/empty ⇒ effective opus for A/C (the execute quality ceiling those
# dispatches previously assumed they inherited from the session model).
# #1420: unset/empty ⇒ effective opus for B too. B's sonnet default was safe only
# because the split lane paired it with an always-Opus test-author; with one agent
# the resolved model IS the quality floor, so B joins A/C at the ceiling. An
# explicit knob still wins on every path (REASON=explicit-knob), which is the
# documented way back to a cheap PATH B execute.
if [ -n "$KNOB" ]; then
  RESOLVED_KNOB="$KNOB"
  KNOB_REASON="explicit-knob"
elif [ "$PATH_LETTER" = "D" ]; then
  RESOLVED_KNOB="sonnet"
  KNOB_REASON="default-sonnet"
else
  RESOLVED_KNOB="opus"
  KNOB_REASON="default-opus"
fi

# --- Defaults the emit() block fills in (overridden by the branches below) ---
MODEL=""
REASON=""
ELIGIBLE=""        # B-only advisory; left empty for D

emit() {
  echo "ISSUE=$N"
  echo "PATH=$PATH_LETTER"
  echo "MODEL=$MODEL"
  # #1420: ROLES is a constant. It is still EMITTED (unlike the retired shape
  # boolean, which is dropped outright) so a consumer reading the shape gets an
  # explicit `single` rather than silence it would have to interpret.
  echo "ROLES=single"
  if [ "$PATH_LETTER" = "B" ]; then
    echo "SCOPE=$SCOPE"
    [ -n "$ELIGIBLE" ] && echo "ELIGIBLE=$ELIGIBLE"
  fi
  echo "REASON=$REASON"
  exit 0
}

if [ "$PATH_LETTER" = "A" ] || [ "$PATH_LETTER" = "C" ]; then
  # === PATH A / PATH C (#1186) ===============================================
  # No eligibility predicate and no carve-outs: the DEFAULT is already the opus
  # ceiling those carve-outs exist to reach, so there is nothing to force. An
  # explicit cheaper knob is an operator override, honored verbatim (same rule
  # as B/D `explicit-knob`). For PATH C the resolved model applies to EVERY
  # `target=<dir>` leaf dispatch.
  MODEL="$RESOLVED_KNOB"; REASON="$KNOB_REASON"
elif [ "$PATH_LETTER" = "B" ]; then
  # === PATH B ================================================================
  # Run the eligibility predicate (the SAME machinery the read-site uses). It
  # carries the W2 high-uncertainty signal (REASON=high-uncertainty) and the
  # needs-browser signal (REASON=needs-browser) — we do NOT redefine the regex.
  ELIG_LINE="$(PIPELINE_REPO="$REPO" bash "${_red_dir}/path-b-execute-eligible.sh" "$N" 2>/dev/null | grep -E '^ELIGIBLE=' | head -1 || true)"
  ELIGIBLE="$(printf '%s' "$ELIG_LINE" | sed -n 's/.*ELIGIBLE=\([a-z-]*\).*/\1/p')"
  ELIG_REASON="$(printf '%s' "$ELIG_LINE" | sed -n 's/.*REASON=\([a-z-]*\).*/\1/p')"
  [ -n "$ELIGIBLE" ] || ELIGIBLE="high-blast"   # fail-closed if predicate silent

  # W2 high-uncertainty OR needs-browser ⇒ always Opus (the protected carve-out).
  if [ "$ELIG_REASON" = "high-uncertainty" ]; then
    MODEL="opus"; REASON="high-uncertainty"
  elif [ "$ELIG_REASON" = "needs-browser" ]; then
    MODEL="opus"; REASON="needs-browser"
  elif [ "$SCOPE" = "low-blast" ] && [ "$ELIGIBLE" != "low-blast" ]; then
    # scope=low-blast restricts the resolved model to low-blast verdicts only;
    # a high-blast verdict PINS opus (the pre-#1042 conservative lane — named,
    # not inherited, since #1186).
    MODEL="opus"; REASON="scope-low-blast-gated"
  else
    # scope=all (default) OR scope=low-blast with a low-blast verdict ⇒ resolved
    # knob applies (opus default since #1420, or an explicit cheaper value honored verbatim).
    MODEL="$RESOLVED_KNOB"; REASON="$KNOB_REASON"
  fi
else
  # === PATH D ================================================================
  # No eligibility predicate (all D is in-lane by construction). Two carve-outs:
  # needs-browser label ⇒ pinned Opus (#960); W2 vocab ⇒ Opus.
  RAW="$(gh issue view "$N" --repo "$REPO" --json title,body,labels 2>/dev/null || true)"
  TITLE="$(printf '%s' "$RAW" | jq -r '.title // ""' 2>/dev/null || true)"
  BODY="$(printf '%s' "$RAW" | jq -r '.body // ""' 2>/dev/null || true)"
  LABELS="$(printf '%s' "$RAW" | jq -r '[.labels[].name] | join(" ")' 2>/dev/null || true)"

  # needs-browser carve-out (#960) — the LABEL is the primary signal.
  if printf '%s\n' "$LABELS" | grep -iqwE 'needs-browser'; then
    MODEL="opus"; REASON="needs-browser"
  else
    # W2 high-uncertainty — DIRECT match of the shared regex (PATH D never calls
    # the B-only eligibility script). REUSE _high-uncertainty-match.sh; do NOT
    # redefine the regex (bug #1039).
    # shellcheck source=scripts/_high-uncertainty-match.sh
    . "${_red_dir}/_high-uncertainty-match.sh"
    # #1381: strip backticked path-shaped tokens first — a listed filename such
    # as `docs/security-model.md` is a file reference, not a risk claim, so
    # merely naming it must not buy an opus execute.
    # CAPTURE first, then match with a here-string: the producer must finish
    # writing before `grep -q` can exit, or SIGPIPE + `pipefail` silently voids
    # the carve-out on a large body.
    HU_TEXT="$(printf '%s\n%s\n%s\n' "$TITLE" "$BODY" "$LABELS" | hu_strip_path_tokens)"
    if grep -iEq "$HIGH_UNCERTAINTY_RE" <<<"$HU_TEXT"; then
      MODEL="opus"; REASON="high-uncertainty"
    else
      MODEL="$RESOLVED_KNOB"; REASON="$KNOB_REASON"
    fi
  fi
fi

emit
