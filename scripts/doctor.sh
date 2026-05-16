#!/bin/bash
# scripts/doctor.sh — non-mutating consumer-install validator for the pipeline plugin.
#
# Modes:
#   doctor.sh             — run all checks, print CHECK: lines + summary, exit 1 if any fail.
#   doctor.sh --fix labels — seed canonical GitHub labels idempotently via `gh label create --force`.
#
# Each check emits exactly one line:
#   CHECK: <name> status=<pass|fail|warn> detail=<msg>
# Warnings do not cause non-zero exit; fails do.

set -uo pipefail

# Snapshot CLAUDE_PLUGIN_ROOT BEFORE sourcing the resolver so the
# claude_plugin_root check can tell pre-set (pass) from self-resolved (warn).
_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE="${CLAUDE_PLUGIN_ROOT:-}"
RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$RESOLVER_DIR/_resolve-plugin-root.sh" ] \
  && source "$RESOLVER_DIR/_resolve-plugin-root.sh" 2>/dev/null || true

# Canonical label table — single source of truth.
# Each row: <key>|<default-name>|<color>|<description>
# `key` is the stage label name OR the env-override variable suffix (EXCLUDED/LATER/HUMAN/BRAINSTORM).
LABEL_TABLE=(
  "plan-pending|plan-pending|C2E0C6|Plan posted, awaiting review"
  "plan-reviewed|plan-reviewed|BFD4F2|Plan evaluated"
  "plan-approved|plan-approved|0E8A16|Approved, ready for execution"
  "in-progress|in-progress|FBCA04|Currently being implemented"
  "pr-open|pr-open|1D76DB|PR open, awaiting review"
  "merged|merged|6F42C1|PR merged, ready for cleanup"
  "EXCLUDED|excluded|E4E669|Excluded from pipeline"
  "LATER|later|D4C5F9|Deferred"
  "HUMAN|human|F9D0C4|Needs human in the loop"
  "BRAINSTORM|brainstorm|FEF2C0|Non-actionable discussion/exploration"
)

# Resolve the effective label name for a row, honoring PIPELINE_LABELS_<KEY> overrides
# for the four configurable rows.
resolve_label_name() {
  local key="$1" default="$2"
  case "$key" in
    EXCLUDED)   echo "${PIPELINE_LABELS_EXCLUDED:-$default}" ;;
    LATER)      echo "${PIPELINE_LABELS_LATER:-$default}" ;;
    HUMAN)      echo "${PIPELINE_LABELS_HUMAN:-$default}" ;;
    BRAINSTORM) echo "${PIPELINE_LABELS_BRAINSTORM:-$default}" ;;
    *)          echo "$default" ;;
  esac
}

# --------------------------------------------------------------------------
# --fix labels: seed/upsert the canonical labels via `gh label create --force`.
# --------------------------------------------------------------------------
if [ "${1:-}" = "--fix" ] && [ "${2:-}" = "labels" ]; then
  if [ ! -f pipeline.config ]; then
    echo "ERROR: pipeline.config not found in $(pwd)" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  source ./pipeline.config
  if [ -z "${PIPELINE_REPO:-}" ]; then
    echo "ERROR: PIPELINE_REPO is empty in pipeline.config" >&2
    exit 1
  fi
  for row in "${LABEL_TABLE[@]}"; do
    IFS='|' read -r key default color desc <<<"$row"
    name="$(resolve_label_name "$key" "$default")"
    gh label create "$name" --repo "$PIPELINE_REPO" --color "$color" --description "$desc" --force
  done
  echo "Seeded ${#LABEL_TABLE[@]} labels on $PIPELINE_REPO (idempotent — safe to re-run)."
  exit 0
fi

# --------------------------------------------------------------------------
# Check accumulation. Each `record name status detail` appends one CHECK line
# to stdout AND stores the row for the summary table at the end.
# --------------------------------------------------------------------------
CHECK_NAMES=()
CHECK_STATUSES=()
record() {
  local name="$1" status="$2" detail="$3"
  printf 'CHECK: %s status=%s detail=%s\n' "$name" "$status" "$detail"
  CHECK_NAMES+=("$name")
  CHECK_STATUSES+=("$status")
}

# --------------------------------------------------------------------------
# Check: gh_installed (pre-flight — emitted even if pipeline.config is missing).
# --------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  record gh_installed fail "gh CLI not found on PATH"
  echo
  echo "=== Summary ==="
  printf '%-28s %s\n' "gh_installed" "fail"
  exit 1
fi
record gh_installed pass "gh CLI on PATH"

# --------------------------------------------------------------------------
# Check: pipeline_config — file present and PIPELINE_REPO non-empty.
# --------------------------------------------------------------------------
if [ ! -f pipeline.config ]; then
  record pipeline_config fail "pipeline.config not found in $(pwd)"
else
  if ! bash -n pipeline.config 2>/dev/null; then
    record pipeline_config fail "pipeline.config has syntax errors"
  else
    # shellcheck disable=SC1091
    ( source ./pipeline.config ) >/dev/null 2>&1
    # shellcheck disable=SC1091
    source ./pipeline.config 2>/dev/null
    if [ -z "${PIPELINE_REPO:-}" ]; then
      record pipeline_config fail "PIPELINE_REPO is empty in pipeline.config"
    else
      record pipeline_config pass "$(pwd)/pipeline.config (PIPELINE_REPO=$PIPELINE_REPO)"
    fi
  fi
fi

# Below this point, several checks need PIPELINE_REPO / PIPELINE_BASE_BRANCH.
# If they're missing, the checks degrade to fail/warn with a clear detail
# rather than crashing.
PIPELINE_REPO="${PIPELINE_REPO:-}"
PIPELINE_BASE_BRANCH="${PIPELINE_BASE_BRANCH:-staging}"

# --------------------------------------------------------------------------
# Check: gh_auth
# --------------------------------------------------------------------------
if gh auth status >/dev/null 2>&1; then
  record gh_auth pass "authenticated"
else
  record gh_auth fail "gh CLI is not authenticated (run: gh auth login)"
fi

# --------------------------------------------------------------------------
# Check: gh_repo_reachable
# --------------------------------------------------------------------------
if [ -z "$PIPELINE_REPO" ]; then
  record gh_repo_reachable fail "PIPELINE_REPO not set"
elif gh repo view "$PIPELINE_REPO" --json name >/dev/null 2>&1; then
  record gh_repo_reachable pass "$PIPELINE_REPO"
else
  record gh_repo_reachable fail "$PIPELINE_REPO is not reachable (auth or typo?)"
fi

# --------------------------------------------------------------------------
# Check: labels_exist
# --------------------------------------------------------------------------
expected_labels=()
for row in "${LABEL_TABLE[@]}"; do
  IFS='|' read -r key default _ _ <<<"$row"
  expected_labels+=("$(resolve_label_name "$key" "$default")")
done

if [ -z "$PIPELINE_REPO" ]; then
  record labels_exist fail "PIPELINE_REPO not set"
else
  actual_names="$(gh label list --repo "$PIPELINE_REPO" --json name --limit 100 --jq '.[].name' 2>/dev/null || true)"
  missing=()
  for want in "${expected_labels[@]}"; do
    if ! grep -Fxq "$want" <<<"$actual_names"; then
      missing+=("$want")
    fi
  done
  total="${#expected_labels[@]}"
  if [ "${#missing[@]}" = "0" ]; then
    record labels_exist pass "$total/$total"
  else
    missing_csv="$(IFS=', '; echo "${missing[*]}")"
    record labels_exist fail "missing: $missing_csv"
  fi
fi

# --------------------------------------------------------------------------
# Check: plugin_loaded
# --------------------------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  record plugin_loaded warn "claude CLI not on PATH"
elif claude plugin list 2>/dev/null | grep -q claude-pipeline; then
  record plugin_loaded pass "claude-pipeline is registered"
else
  record plugin_loaded fail "claude-pipeline not in 'claude plugin list'"
fi

# --------------------------------------------------------------------------
# Check: no_residual_subtree — legacy installer left behind .claude-pipeline/ or .pipeline-managed markers.
# --------------------------------------------------------------------------
residual=""
if [ -d .claude-pipeline ]; then
  residual=".claude-pipeline/"
elif compgen -G '.claude/skills/*/.pipeline-managed' >/dev/null 2>&1; then
  residual=".claude/skills/*/.pipeline-managed"
fi
if [ -n "$residual" ]; then
  record no_residual_subtree fail "$residual present — run scripts/migrate-from-subtree.sh"
else
  record no_residual_subtree pass "no legacy subtree artifacts"
fi

# --------------------------------------------------------------------------
# Check: claude_md_residual — delegate to the migration-cleanup-claudemd scanner;
# parse its report file to surface findings as a warn (never a fail).
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCANNER="$SCRIPT_DIR/migration-cleanup-claudemd.sh"
if [ ! -f "$SCANNER" ]; then
  record claude_md_residual warn "migration-cleanup-claudemd.sh not found at $SCANNER"
else
  bash "$SCANNER" >/dev/null 2>&1 || true
  CMD_REPORT=".claude/migration-cleanup-report-claudemd.txt"
  if [ ! -s "$CMD_REPORT" ]; then
    record claude_md_residual pass "no residual pipeline state in CLAUDE.md"
  else
    # Count findings: non-empty content lines that look like a finding row.
    # Finding rows are either "<path>:<lineno>:..." entries (paths/cmds passes)
    # or 4-space-indented corroboration lines under section headers.
    finding_count=$(awk '
      /^CLAUDE\.md pipeline-legacy/ { next }
      /^Section headers$/ || /^Legacy paths$/ || /^Deprecated slash commands$/ { next }
      /^-+$/ { next }
      /^[[:space:]]*$/ { next }
      /^  corroborated by:$/ { next }
      /^[^[:space:]].*:[0-9]+:/ { count++; next }
      /^    .+/ { count++; next }
      END { print count + 0 }
    ' "$CMD_REPORT")
    record claude_md_residual warn "$finding_count residual reference(s) in CLAUDE.md (see .claude/migration-cleanup-report-claudemd.txt)"
  fi
fi

# --------------------------------------------------------------------------
# Check: base_branch_local — local branch exists; warn if no upstream tracking.
# --------------------------------------------------------------------------
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  record base_branch_local fail "not a git repository"
elif ! git rev-parse --verify "refs/heads/$PIPELINE_BASE_BRANCH" >/dev/null 2>&1; then
  record base_branch_local fail "branch not found: $PIPELINE_BASE_BRANCH"
elif ! git rev-parse --abbrev-ref "$PIPELINE_BASE_BRANCH@{upstream}" >/dev/null 2>&1; then
  record base_branch_local warn "no upstream configured for $PIPELINE_BASE_BRANCH"
else
  upstream="$(git rev-parse --abbrev-ref "$PIPELINE_BASE_BRANCH@{upstream}" 2>/dev/null)"
  record base_branch_local pass "$PIPELINE_BASE_BRANCH tracks $upstream"
fi

# --------------------------------------------------------------------------
# Check: dev_marketplace_on_main — warn when the registered dev marketplace
# points at a clone whose HEAD is NOT on `main`. Informational, never fails.
# DOCTOR_KNOWN_MARKETPLACES_FILE is a test seam; not advertised in user docs.
# --------------------------------------------------------------------------
KM_FILE="${DOCTOR_KNOWN_MARKETPLACES_FILE:-$HOME/.claude/plugins/known_marketplaces.json}"
if [ ! -f "$KM_FILE" ]; then
  record dev_marketplace_on_main pass "dev marketplace not registered"
else
  MARKETPLACE_PATH="$(python3 -c 'import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("claude-pipeline-dev",{}).get("source",{}).get("path",""))
except Exception:
  pass' "$KM_FILE" 2>/dev/null)"
  if [ -z "$MARKETPLACE_PATH" ]; then
    record dev_marketplace_on_main pass "dev marketplace not registered"
  else
    CLONE_ROOT="$(dirname "$(dirname "$MARKETPLACE_PATH")")"
    if [ ! -d "$CLONE_ROOT" ]; then
      record dev_marketplace_on_main warn "marketplace path does not exist: $MARKETPLACE_PATH"
    elif ! HEAD_BRANCH="$(git -C "$CLONE_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
      record dev_marketplace_on_main warn "marketplace path is not a git clone: $CLONE_ROOT"
    elif [ "$HEAD_BRANCH" = "main" ]; then
      record dev_marketplace_on_main pass "clone on main"
    else
      record dev_marketplace_on_main warn "dev marketplace clone is on $HEAD_BRANCH, not main — installed version may lag main"
    fi
  fi
fi

# --------------------------------------------------------------------------
# Check: claude_plugin_root — env was already set (pass), self-resolved from
# the plugin cache (warn), or empty with no cache (fail). Snapshot captured
# at the top of this script before the resolver source.
# --------------------------------------------------------------------------
if [ -n "${_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE:-}" ]; then
  record claude_plugin_root pass "env pre-set to ${CLAUDE_PLUGIN_ROOT}"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  record claude_plugin_root warn "env was empty; self-resolved to ${CLAUDE_PLUGIN_ROOT}"
else
  record claude_plugin_root fail "CLAUDE_PLUGIN_ROOT empty and no plugin cache found at ~/.claude/plugins/cache/claude-pipeline/pipeline/"
fi

# --------------------------------------------------------------------------
# Summary table + exit code.
# --------------------------------------------------------------------------
echo
echo "=== Summary ==="
any_fail=0
for i in "${!CHECK_NAMES[@]}"; do
  printf '%-28s %s\n' "${CHECK_NAMES[$i]}" "${CHECK_STATUSES[$i]}"
  if [ "${CHECK_STATUSES[$i]}" = "fail" ]; then
    any_fail=1
  fi
done

if [ "$any_fail" = "1" ]; then
  echo
  echo "One or more checks failed."
  exit 1
fi
exit 0
