# shellcheck shell=bash
# Auto-merge greenlight gate helper.
#
# Source this file; it exposes:
#   auto_merge_should_fire <issue> <pr>
#       - prints exactly one reason token, returns 0 only when token == green.
#       - Tokens: green, block-flag, block-label, block-verdict,
#         block-capability-refused, block-base-mismatch, block-ci,
#         block-mergeable, block-mergestate.
#       - Order: env (MANUAL_MERGE=1) > label (manual-merge on issue) >
#         verdict > block-capability-refused > base-mismatch > CI rollup >
#         mergeable > mergeStateStatus.
#       - block-capability-refused (#1233) fires when
#         $PIPELINE_CAPABILITY_REFUSAL_SOURCES is non-empty AND
#         scripts/check-capability-refusal.sh resolves CAPABILITY_REFUSAL=block
#         for this issue over those sources — a leaf emitted the
#         CAPABILITY-REFUSED: sentinel (#1225's contract) and the work is
#         incomplete. Unset/empty knob is byte-identical to the pre-#1233
#         gate (arm skipped entirely). An unproven clear (REASON=no-sources or
#         no-leaf-output) is deliberately NON-blocking but emits a stderr WARN
#         so the gate never silently claims teeth it does not have.
#       - The gate itself does NOT resolve $PIPELINE_CAPABILITY_REFUSAL_SOURCES
#         (#1246) — it only reads the knob. The call site MUST thread it via
#         the worktree-aware `check-capability-refusal.sh --resolve-sources`
#         mode (pr-eval always runs from a feature worktree, which has no
#         .claude/logs/ of its own), and export it ONLY on SOURCES=resolved.
#       - NO_VERDICT=1 skips ONLY the verdict step (for the /pipeline:hotfix
#         --auto-merge emergency lane, which never produces an evaluator
#         verdict — issue #659). Every other check is unchanged, and the
#         MANUAL_MERGE env + manual-merge label opt-outs still precede it.
#       - block-base-mismatch fires when the PR's baseRefName !=
#         $PIPELINE_BASE_BRANCH — eval-time defense-in-depth for the
#         enforce-base-branch hook (see #295, dev/audits/295-root-cause.md).
#         Next-branch aware (#1148): baseRefName == $PIPELINE_NEXT_BRANCH
#         (default `next`) is ALSO accepted when the PR's issue carries
#         ${PIPELINE_NEXT_LABEL:-next} or the legacy alias
#         `next-major-release`; otherwise a `next` base still blocks.
#   parse_manual_merge_argv <args>...
#       - sets MANUAL_MERGE=1 when --manual-merge appears in argv at any
#         position; prints the remaining args (one per line) to stdout.
#
# Requires: gh (>= 2.0 for mergeStateStatus), jq, $PIPELINE_REPO and
#           $PIPELINE_BASE_BRANCH in env. When $PIPELINE_BASE_BRANCH is empty
#           the gate self-sources pipeline.config (resolved via
#           PIPELINE_PROJECT_ROOT / $(pwd) / git toplevel) to recover it; if it
#           is STILL empty after that, the gate `return 2`s with a diagnostic
#           rather than emitting a spurious block-base-mismatch (issue #801).

auto_merge_should_fire() {
  local issue="$1" pr="$2"

  if ! command -v jq >/dev/null 2>&1; then
    echo "[auto-merge-gate] ERROR: jq is required but not on PATH" >&2
    return 2
  fi

  if [ "${MANUAL_MERGE:-0}" = "1" ]; then
    echo block-flag
    return 1
  fi

  if gh issue view "$issue" --repo "$PIPELINE_REPO" --json labels \
       --jq '.labels[].name' 2>/dev/null | grep -qx manual-merge; then
    echo block-label
    return 1
  fi

  if [ "${NO_VERDICT:-0}" != "1" ]; then
    local verdict
    verdict=$(gh pr view "$pr" --repo "$PIPELINE_REPO" --json comments \
      --jq '[.comments[] | select(.body | contains("## Evaluation"))] | last | .body' \
      2>/dev/null \
      | grep -oE '\*\*Verdict:\*\* (Approved|Flagged[^[:space:]]*|Revise|Reject)' \
      | head -1 | awk '{print $2}')
    if [ "$verdict" != "Approved" ]; then
      echo block-verdict
      return 1
    fi
  fi

  # Capability-refusal sentinel (issue #1233): a leaf that emitted the
  # CAPABILITY-REFUSED: sentinel (#1225's contract) means the WORK is
  # incomplete — more fundamental than a base/CI/merge-state property, but
  # still after the two operator opt-outs and the human evaluator verdict
  # above (which is what makes the within-issue-history block self-clearing
  # via Step 11.4's manual-merge auto-apply). Runs ONLY when the caller
  # threaded $PIPELINE_CAPABILITY_REFUSAL_SOURCES — unset/empty is
  # byte-identical to the pre-#1233 gate.
  if [ -n "${PIPELINE_CAPABILITY_REFUSAL_SOURCES:-}" ]; then
    local _amg_cr_dir _amg_cr_line _amg_cr_verdict _amg_cr_reason _amg_cr_scanned _amg_cr_with_output
    _amg_cr_dir="$(dirname "${BASH_SOURCE[0]}")"
    _amg_cr_line=$(bash "$_amg_cr_dir/check-capability-refusal.sh" "$issue" 2>/dev/null)
    _amg_cr_verdict=$(printf '%s\n' "$_amg_cr_line" | grep -oE 'CAPABILITY_REFUSAL=[a-z]+' | cut -d= -f2)
    _amg_cr_reason=$(printf '%s\n' "$_amg_cr_line" | grep -oE 'REASON=[a-z-]+' | cut -d= -f2)
    if [ "$_amg_cr_verdict" = "block" ]; then
      echo block-capability-refused
      return 1
    fi
    if [ "$_amg_cr_reason" = "no-sources" ] || [ "$_amg_cr_reason" = "no-leaf-output" ]; then
      _amg_cr_scanned=$(printf '%s\n' "$_amg_cr_line" | grep -oE 'SCANNED=[0-9]+' | cut -d= -f2)
      _amg_cr_with_output=$(printf '%s\n' "$_amg_cr_line" | grep -oE 'WITH_OUTPUT=[0-9]+' | cut -d= -f2)
      echo "[auto-merge-gate] WARN: capability-refusal check unproven (REASON=${_amg_cr_reason} SCANNED=${_amg_cr_scanned} WITH_OUTPUT=${_amg_cr_with_output}) SOURCES=${PIPELINE_CAPABILITY_REFUSAL_SOURCES}" >&2
    fi
  fi

  # Defense-in-depth (issue #295): refuse to merge when the PR's baseRefName
  # diverges from $PIPELINE_BASE_BRANCH. The enforce-base-branch PreToolUse
  # hook covers gh pr create + gh pr edit --base at write time, but it has
  # bypassed in production (stale rendered spawn-claude.sh, consumer
  # settings.json shadowing) — see dev/audits/295-root-cause.md. This
  # eval-time check is the load-bearing zero-data-loss gate.
  # Self-source pipeline.config when the base branch is not in env (issue #801).
  # Callers source config in one bash step and run the gate in a separate
  # subshell; a non-exported PIPELINE_BASE_BRANCH is then empty here and made
  # the base check spuriously emit block-base-mismatch. Resolve the project
  # root (NOT this script's dir — it is sourced from the plugin cache, whose
  # parent is not the consumer root) and source the config to recover it.
  if [ -z "${PIPELINE_BASE_BRANCH:-}" ]; then
    local _amg_root _amg_cfg
    _amg_root="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
    _amg_cfg="$_amg_root/pipeline.config"
    if [ ! -f "$_amg_cfg" ]; then
      _amg_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$_amg_root" ] && _amg_cfg="$_amg_root/pipeline.config"
    fi
    # shellcheck disable=SC1090
    [ -f "$_amg_cfg" ] && source "$_amg_cfg"
  fi
  # Fail-safe (issue #801): an empty base after the recovery attempt is a hard
  # config error, NOT a real base divergence — never let it masquerade as
  # block-base-mismatch. Diagnosable, fail-closed (mirrors the missing-jq path).
  if [ -z "${PIPELINE_BASE_BRANCH:-}" ]; then
    echo "[auto-merge-gate] ERROR: PIPELINE_BASE_BRANCH is empty (pipeline.config not found/sourced); cannot evaluate base — set PIPELINE_BASE_BRANCH or run from the project root" >&2
    return 2
  fi

  local base
  base=$(gh pr view "$pr" --repo "$PIPELINE_REPO" --json baseRefName \
    --jq .baseRefName 2>/dev/null)
  if [ -z "$base" ]; then
    echo block-base-mismatch
    return 1
  fi
  if [ "$base" != "$PIPELINE_BASE_BRANCH" ]; then
    # Next-branch aware acceptance (#1148): a PR targeting
    # $PIPELINE_NEXT_BRANCH (default `next`) is a valid base ONLY when the
    # PR's issue is next-routed — carries ${PIPELINE_NEXT_LABEL:-next} or
    # the legacy alias `next-major-release` (see #1128 execute-side
    # routing). This mirrors setup-worktree.sh's next-branch actuation so
    # the autonomous greenlight gate does not block every next-routed PR.
    # A PR targeting `next` for a NON-next issue still block-base-mismatch.
    local next_branch="${PIPELINE_NEXT_BRANCH:-next}"
    if [ "$base" = "$next_branch" ]; then
      local next_label="${PIPELINE_NEXT_LABEL:-next}"
      local issue_labels
      issue_labels=$(gh issue view "$issue" --repo "$PIPELINE_REPO" --json labels \
        --jq '[.labels[].name]' 2>/dev/null)
      if ! printf '%s' "$issue_labels" | jq -e --arg l "$next_label" \
           'index($l) != null or index("next-major-release") != null' >/dev/null 2>&1; then
        echo block-base-mismatch
        return 1
      fi
    else
      echo block-base-mismatch
      return 1
    fi
  fi

  local rollup mergeable mergestate
  rollup=$(gh pr view "$pr" --repo "$PIPELINE_REPO" \
    --json statusCheckRollup,mergeable,mergeStateStatus 2>/dev/null)
  if ! echo "$rollup" | jq -e '.statusCheckRollup | length == 0 or (group_by(.name) | all(last.conclusion == "SUCCESS"))' >/dev/null 2>&1; then
    echo block-ci
    return 1
  fi
  mergeable=$(echo "$rollup" | jq -r '.mergeable' 2>/dev/null | tr -d '\r')
  if [ "$mergeable" != "MERGEABLE" ]; then
    echo block-mergeable
    return 1
  fi
  mergestate=$(echo "$rollup" | jq -r '.mergeStateStatus' 2>/dev/null | tr -d '\r')
  if [ "$mergestate" != "CLEAN" ]; then
    echo block-mergestate
    return 1
  fi

  echo green
  return 0
}

parse_manual_merge_argv() {
  # Loop-based parser: --manual-merge may appear anywhere in argv.
  # Cannot collide with issue numbers because those are bare integers.
  MANUAL_MERGE="${MANUAL_MERGE:-0}"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --manual-merge) MANUAL_MERGE=1 ;;
      *) printf '%s\n' "$arg" ;;
    esac
  done
}
