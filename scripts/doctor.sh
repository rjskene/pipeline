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
# shellcheck disable=SC1091
[ -f "$RESOLVER_DIR/_advisory-text.sh" ] \
  && source "$RESOLVER_DIR/_advisory-text.sh" 2>/dev/null || true

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
# --fix residual: re-run the three residual-state detectors in remediate
# mode, prompting [y/N] per finding. Honors DOCTOR_FIX_NONINTERACTIVE=1
# (auto-N for every prompt; used by tests to assert the prompt-and-skip path
# without a TTY).
# --------------------------------------------------------------------------
if [ "${1:-}" = "--fix" ] && [ "${2:-}" = "residual" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PLUGIN_ROOT_FIX="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

  # Helper: prompt [y/N]. Honors DOCTOR_FIX_NONINTERACTIVE=1 (auto-N).
  # Returns 1 on EOF/empty-read (caller decides exit code).
  _FIX_EOF=0
  prompt_yn() {
    local msg="$1"
    printf '%s [y/N] ' "$msg"
    if [ "${DOCTOR_FIX_NONINTERACTIVE:-0}" = "1" ]; then
      echo "n"
      REPLY="n"
      return 0
    fi
    if ! IFS= read -r REPLY; then
      _FIX_EOF=1
      REPLY=""
      printf '\n' >&2
      return 1
    fi
    return 0
  }

  any_prompt_eof=0

  # --- skill_files_residual remediation ---
  fix_allow_tmp="$(mktemp)"
  for sub in skills hooks scripts agents; do
    if [ -d "$PLUGIN_ROOT_FIX/$sub" ]; then
      find "$PLUGIN_ROOT_FIX/$sub" -type f -printf '%f\n' 2>/dev/null
    fi
  done | sort -u > "$fix_allow_tmp"

  fix_dup_paths=()
  for sub in skills hooks scripts agents; do
    if [ -d ".claude/$sub" ]; then
      while IFS= read -r -d '' f; do
        bn="$(basename "$f")"
        if grep -Fxq "$bn" "$fix_allow_tmp"; then
          if [ "$sub" = "skills" ]; then
            sd="$(dirname "$f")"
            already=0
            for existing in "${fix_dup_paths[@]:-}"; do
              [ "$existing" = "$sd" ] && already=1 && break
            done
            [ "$already" = "0" ] && fix_dup_paths+=("$sd")
          else
            fix_dup_paths+=("$f")
          fi
        fi
      done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
    fi
  done
  rm -f "$fix_allow_tmp"

  for path in "${fix_dup_paths[@]:-}"; do
    [ -z "$path" ] && continue
    if prompt_yn "Remove duplicate of plugin-shipped file: $path?"; then
      case "$REPLY" in
        y|Y|yes|YES)
          rm -rf "$path"
          echo "  removed: $path"
          ;;
        *)
          echo "  skipped: $path"
          ;;
      esac
    else
      any_prompt_eof=1
      echo "  skipped (no input): $path"
    fi
  done

  # --- settings_residual remediation: ONE prompt for the whole batch. ---
  _sr_settings=".claude/settings.json"
  has_settings_findings=0
  if [ -f "$_sr_settings" ] && command -v jq >/dev/null 2>&1; then
    _sr_known_tmp="$(mktemp)"
    if command -v list_pipeline_hook_basenames >/dev/null 2>&1; then
      list_pipeline_hook_basenames > "$_sr_known_tmp" 2>/dev/null || true
    fi
    while IFS= read -r _sr_cmd; do
      [ -z "$_sr_cmd" ] && continue
      _sr_last_tok="${_sr_cmd##* }"
      _sr_bn="$(basename "$_sr_last_tok")"
      if grep -Fxq "$_sr_bn" "$_sr_known_tmp" 2>/dev/null; then
        has_settings_findings=1
        break
      fi
    done < <(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$_sr_settings" 2>/dev/null || true)
    rm -f "$_sr_known_tmp"
  fi

  if [ "$has_settings_findings" = "1" ]; then
    if prompt_yn "Patch .claude/settings.json (delegate to migrate-from-subtree.sh --patch settings)?"; then
      case "$REPLY" in
        y|Y|yes|YES)
          bash "$PLUGIN_ROOT_FIX/scripts/migrate-from-subtree.sh" --patch settings
          ;;
        *)
          echo "  skipped: settings.json patch"
          ;;
      esac
    else
      any_prompt_eof=1
      echo "  skipped (no input): settings.json patch"
    fi
  fi

  # --- claude_md_residual remediation: surface the report path. ---
  CMD_REPORT=".claude/migration-cleanup-report-claudemd.txt"
  SCANNER="$SCRIPT_DIR/migration-cleanup-claudemd.sh"
  if [ -f "$SCANNER" ]; then
    bash "$SCANNER" >/dev/null 2>&1 || true
  fi
  if [ -s "$CMD_REPORT" ]; then
    if prompt_yn "CLAUDE.md has residual pipeline references — surface the report path for manual review?"; then
      case "$REPLY" in
        y|Y|yes|YES)
          echo "  review manually: $CMD_REPORT"
          echo "  (CLAUDE.md is user-authored prose; no in-place edit will be performed.)"
          ;;
        *)
          echo "  skipped: CLAUDE.md report"
          ;;
      esac
    else
      any_prompt_eof=1
      echo "  skipped (no input): CLAUDE.md report"
    fi
  fi

  if [ "$any_prompt_eof" = "1" ] && [ "$_FIX_EOF" = "1" ]; then
    exit 2
  fi
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

# BEGIN settings_residual
# --------------------------------------------------------------------------
# Check: settings_residual — scan $PROJECT_ROOT/.claude/settings.json for
# pipeline-owned hook command basenames (sourced from _advisory-text.sh) and
# emit one annotated line per finding plus a single migrate-from-subtree
# summary line. Never a fail — warn or pass only. Falls back to warn when
# jq is not installed (the check is not fatal to the doctor run).
# --------------------------------------------------------------------------
_sr_settings=".claude/settings.json"
if [ ! -f "$_sr_settings" ]; then
  record settings_residual pass "no settings.json"
elif ! command -v jq >/dev/null 2>&1; then
  record settings_residual warn "jq required for settings_residual check"
else
  # Enumerate every command across all hook sections (forward-compatible with
  # future hook types beyond PreToolUse/PostToolUse/Stop).
  _sr_known_tmp="$(mktemp)"
  list_pipeline_hook_basenames > "$_sr_known_tmp" 2>/dev/null || true
  _sr_findings=()
  while IFS= read -r _sr_cmd; do
    [ -z "$_sr_cmd" ] && continue
    # basename of the command's first token (handles "python3 path/to/x.py" by
    # taking the last whitespace-separated token, then basename).
    _sr_last_tok="${_sr_cmd##* }"
    _sr_bn="$(basename "$_sr_last_tok")"
    if grep -Fxq "$_sr_bn" "$_sr_known_tmp"; then
      _sr_findings+=("$_sr_bn")
    fi
  done < <(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$_sr_settings" 2>/dev/null || true)
  rm -f "$_sr_known_tmp"

  _sr_n="${#_sr_findings[@]}"
  if [ "$_sr_n" = "0" ]; then
    record settings_residual pass "no pipeline hook entries"
  else
    if [ "$_sr_n" = "1" ]; then
      _sr_word="entry"
    else
      _sr_word="entries"
    fi
    record settings_residual warn "$_sr_n pipeline hook $_sr_word in .claude/settings.json"
    for _sr_bn in "${_sr_findings[@]}"; do
      echo "  - .claude/hooks/$_sr_bn"
      _sr_adv="$(advisory_for_hook "$_sr_bn" || true)"
      echo "      $_sr_adv"
    done
    echo "  → run: bash \${CLAUDE_PLUGIN_ROOT}/scripts/migrate-from-subtree.sh --patch settings"
  fi
fi
# END settings_residual

# BEGIN skill_files_residual
# --------------------------------------------------------------------------
# Check: skill_files_residual — detect legacy-install residual under consumer
# .claude/{skills,hooks,scripts,agents}/. Builds the plugin-shipped basename
# allow-list at runtime, classifies each consumer file as DUPLICATE or
# CONSUMER_OWNED, and elevates to fail if any duplicate SKILL.md/.sh/.py
# references a stale <owner>/<repo> token near PIPELINE_REPO.
# --------------------------------------------------------------------------
sfr_plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$sfr_plugin_root" ] || [ ! -d "$sfr_plugin_root" ]; then
  _sfr_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  sfr_plugin_root="$(cd "$_sfr_here/.." && pwd)"
fi

sfr_allow_tmp="$(mktemp)"
for sub in skills hooks scripts agents; do
  if [ -d "$sfr_plugin_root/$sub" ]; then
    find "$sfr_plugin_root/$sub" -type f -printf '%f\n' 2>/dev/null
  fi
done | sort -u > "$sfr_allow_tmp"

sfr_dup_files=()
sfr_consumer_files=()
for sub in skills hooks scripts agents; do
  if [ -d ".claude/$sub" ]; then
    while IFS= read -r -d '' f; do
      bn="$(basename "$f")"
      if grep -Fxq "$bn" "$sfr_allow_tmp"; then
        sfr_dup_files+=("$f")
      else
        sfr_consumer_files+=("$f")
      fi
    done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
  fi
done

sfr_stale_findings=()
for f in "${sfr_dup_files[@]:-}"; do
  [ -z "$f" ] && continue
  case "$f" in
    *.md|*.sh|*.py) ;;
    *) continue ;;
  esac
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    [ "$tok" = "\$PIPELINE_REPO" ] && continue
    if [ "$tok" != "$PIPELINE_REPO" ]; then
      sfr_stale_findings+=("$f|$tok")
    fi
  done < <(
    grep -hoE -- '--repo +[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$f" 2>/dev/null \
      | sed -E 's/^--repo +//'
    grep -hoE '"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"' "$f" 2>/dev/null \
      | sed -E 's/^"//; s/"$//'
    grep -hoE "'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+'" "$f" 2>/dev/null \
      | sed -E "s/^'//; s/'$//"
  )
done

rm -f "$sfr_allow_tmp"

sfr_dup_count="${#sfr_dup_files[@]}"
sfr_stale_count="${#sfr_stale_findings[@]}"

if [ "$sfr_stale_count" -gt 0 ]; then
  record skill_files_residual fail "$sfr_stale_count stale-repo reference(s) in legacy install"
elif [ "$sfr_dup_count" -gt 0 ]; then
  record skill_files_residual warn "$sfr_dup_count duplicate(s) of plugin-shipped files"
else
  record skill_files_residual pass "no plugin-basename duplicates"
fi

if [ "$sfr_stale_count" -gt 0 ]; then
  echo "  Critical: stale legacy-install references:"
  for entry in "${sfr_stale_findings[@]}"; do
    f="${entry%%|*}"
    tok="${entry#*|}"
    echo "  - $f: targets $tok (current PIPELINE_REPO=$PIPELINE_REPO)"
  done
fi
if [ "$sfr_dup_count" -gt 0 ]; then
  echo "  Duplicates of plugin-owned files (run scripts/migrate-from-subtree.sh):"
  for f in "${sfr_dup_files[@]}"; do
    echo "  - $f"
  done
fi
if [ "${#sfr_consumer_files[@]}" -gt 0 ]; then
  echo "  Preserved — consumer-owned:"
  for f in "${sfr_consumer_files[@]}"; do
    echo "  - $f"
  done
fi
if [ "$sfr_dup_count" -gt 0 ] || [ "$sfr_stale_count" -gt 0 ]; then
  echo "  → run: bash \${CLAUDE_PLUGIN_ROOT:-.}/scripts/migrate-from-subtree.sh"
fi
# END skill_files_residual

# BEGIN consumer_drift
# --------------------------------------------------------------------------
# Check: consumer_drift — for every consumer .claude/{scripts,hooks,agents}/
# file whose basename collides with a plugin-shipped file, classify drift into
# one of six buckets (A/B/B.bug/C/D/E/F) using scripts/diff-consumer-files.sh.
# B.bug rows (hardcoded literal disagrees with pipeline.config) escalate to
# fail; A/B/C/E rows warn; pass when only D/F/no rows.
# --------------------------------------------------------------------------
CD_HELPER="$SCRIPT_DIR/diff-consumer-files.sh"
if [ ! -x "$CD_HELPER" ] && [ ! -f "$CD_HELPER" ]; then
  record consumer_drift warn "diff-consumer-files.sh not found at $CD_HELPER"
else
  cd_rows="$(bash "$CD_HELPER" 2>/dev/null || true)"
  cd_total=0
  cd_bug=0
  cd_a=0; cd_b=0; cd_c=0; cd_d=0; cd_e=0; cd_f=0
  if [ -n "$cd_rows" ]; then
    while IFS=$'\t' read -r _path bucket _llc _plc _diff _action; do
      [ -z "$bucket" ] && continue
      cd_total=$((cd_total + 1))
      case "$bucket" in
        A)     cd_a=$((cd_a + 1)) ;;
        B)     cd_b=$((cd_b + 1)) ;;
        B.bug) cd_bug=$((cd_bug + 1)) ;;
        C)     cd_c=$((cd_c + 1)) ;;
        D)     cd_d=$((cd_d + 1)) ;;
        E)     cd_e=$((cd_e + 1)) ;;
        F)     cd_f=$((cd_f + 1)) ;;
      esac
    done <<< "$cd_rows"
  fi

  if [ "$cd_bug" -gt 0 ]; then
    record consumer_drift fail "$cd_bug active bug(s) (B.bug): hardcoded literal disagrees with pipeline.config"
  elif [ $((cd_a + cd_b + cd_c + cd_e)) -gt 0 ]; then
    record consumer_drift warn "$cd_total file(s) drifted (A=$cd_a B=$cd_b C=$cd_c E=$cd_e)"
  else
    record consumer_drift pass "no drifted consumer files"
  fi

  if [ "$cd_total" -gt 0 ]; then
    echo "  === consumer_drift summary ==="
    echo "  bucket  path                                                       local  plugin  diff  action"
    echo "  ------  ----                                                       -----  ------  ----  ------"
    while IFS=$'\t' read -r path bucket llc plc diff action; do
      [ -z "$bucket" ] && continue
      printf '  %-6s  %-58s  %5s  %6s  %4s  %s\n' \
        "$bucket" "$path" "$llc" "$plc" "$diff" "$action"
    done <<< "$cd_rows"
  fi
fi
# END consumer_drift

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
