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
# claude_plugin_root check can tell pre-set (pass or warn-if-invalid) from self-resolved (pass).
_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE="${CLAUDE_PLUGIN_ROOT:-}"
RESOLVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[ -f "$RESOLVER_DIR/_resolve-plugin-root.sh" ] \
  && source "$RESOLVER_DIR/_resolve-plugin-root.sh" 2>/dev/null || true
# shellcheck disable=SC1091
[ -f "$RESOLVER_DIR/_advisory-text.sh" ] \
  && source "$RESOLVER_DIR/_advisory-text.sh" 2>/dev/null || true

# Load-bearing hooks — basenames whose drift on the consumer side promotes
# the consumer_drift check from warn to fail. These are the hooks the
# pipeline depends on for defense-in-depth (#295): if a consumer has a stale
# local copy that diverges from the plugin's, security-relevant guardrails
# can silently fail. Add to this list whenever a hook becomes load-bearing.
LOAD_BEARING_HOOKS=("enforce-base-branch.py" "enforce-path-c-delegation.py" "block_deletions.py")

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
      while IFS= read -r -d '' f; do
        rel="${f#$PLUGIN_ROOT_FIX/}"
        printf '%s\n' "$rel"
      done < <(find "$PLUGIN_ROOT_FIX/$sub" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 2>/dev/null)
    fi
  done | sort -u > "$fix_allow_tmp"

  # Class 2 consumer-required short-circuit — mirror skill_files_residual logic.
  # SUNSETS with #215 (see scripts/doctor.sh skill_files_residual block).
  fix_required_tmp="$(mktemp)"
  while IFS= read -r rel; do
    case "$rel" in
      *.template) printf '%s\n' "${rel%.template}" >> "$fix_required_tmp" ;;
    esac
  done < "$fix_allow_tmp"
  sort -u -o "$fix_required_tmp" "$fix_required_tmp"

  fix_dup_paths=()
  for sub in skills hooks scripts agents; do
    if [ -d ".claude/$sub" ]; then
      while IFS= read -r -d '' f; do
        rel="${f#.claude/}"
        # Class 2: skip consumer-required rendered scripts entirely.
        if grep -Fxq "$rel" "$fix_required_tmp"; then
          continue
        fi
        if grep -Fxq "$rel" "$fix_allow_tmp"; then
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
      done < <(find ".claude/$sub" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 2>/dev/null)
    fi
  done
  rm -f "$fix_allow_tmp" "$fix_required_tmp"

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
# Pin gh >= 2.0 (#295). `gh pr create --json baseRefName` and related JSON
# flags are unavailable below the 2.0 floor; the pipeline silently degrades
# on older gh, so surface this at audit time rather than at runtime.
_gh_ver_line="$(gh version 2>/dev/null | head -1)"
_gh_ver="$(printf '%s' "$_gh_ver_line" | sed -nE 's/^gh version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
if [ -n "$_gh_ver" ]; then
  _gh_major="${_gh_ver%%.*}"
  if [ "$_gh_major" -lt 2 ] 2>/dev/null; then
    record gh_installed fail "gh version $_gh_ver below the 2.0 floor required for --json baseRefName; upgrade via your package manager"
    echo
    echo "=== Summary ==="
    printf '%-28s %s\n' "gh_installed" "fail"
    exit 1
  fi
fi
record gh_installed pass "gh CLI on PATH${_gh_ver:+ (version $_gh_ver)}"
unset _gh_ver_line _gh_ver _gh_major

# --------------------------------------------------------------------------
# Check: jq_installed (pre-flight — fail-fast like gh_installed).
# jq is a hard runtime dependency for auto-merge-gate.sh, list-release-prs.sh,
# parse-tracker-children.sh, and any check that parses `gh ... --jq` output.
# One clean fail line here is more actionable than five downstream cascades.
# --------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  record jq_installed fail "jq not found on PATH (required by auto-merge-gate.sh, list-release-prs.sh)"
  echo
  echo "=== Summary ==="
  printf '%-28s %s\n' "gh_installed" "pass"
  printf '%-28s %s\n' "jq_installed" "fail"
  exit 1
fi
record jq_installed pass "jq on PATH"

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
    while IFS= read -r -d '' f; do
      rel="${f#$sfr_plugin_root/}"
      printf '%s\n' "$rel"
    done < <(find "$sfr_plugin_root/$sub" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 2>/dev/null)
  fi
done | sort -u > "$sfr_allow_tmp"

# Class 2 (consumer-required): for every plugin file ending in `.template`,
# also recognize the rendered path (with `.template` stripped) as a path
# the consumer is REQUIRED to keep. Plugin skills invoke these as
# `bash .claude/scripts/<name>.sh`, so they are load-bearing in the
# consumer's working tree even though the plugin only ships the template.
# NOTE: this Class 2 workaround will SUNSET once #215 renames plugin
# scripts/*.template → plugin scripts/* (the install-time render gap).
sfr_required_tmp="$(mktemp)"
while IFS= read -r rel; do
  case "$rel" in
    *.template) printf '%s\n' "${rel%.template}" >> "$sfr_required_tmp" ;;
  esac
done < "$sfr_allow_tmp"
sort -u -o "$sfr_required_tmp" "$sfr_required_tmp"

sfr_dup_files=()
sfr_required_files=()
sfr_consumer_files=()
for sub in skills hooks scripts agents; do
  if [ -d ".claude/$sub" ]; then
    while IFS= read -r -d '' f; do
      rel="${f#.claude/}"
      if grep -Fxq "$rel" "$sfr_allow_tmp"; then
        sfr_dup_files+=("$f")
      elif grep -Fxq "$rel" "$sfr_required_tmp"; then
        sfr_required_files+=("$f")
      else
        sfr_consumer_files+=("$f")
      fi
    done < <(find ".claude/$sub" -type f -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 2>/dev/null)
  fi
done
rm -f "$sfr_required_tmp"

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
if [ "${#sfr_required_files[@]}" -gt 0 ]; then
  echo "  Required — rendered from plugin templates:"
  for f in "${sfr_required_files[@]}"; do
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
  # Resolve the active-project plugin root (when available) so the helper
  # diffs against the plugin Claude Code is actually loading for this
  # project — not the highest-version entry in the stable-marketplace cache.
  cd_rows="$(PIPELINE_DIFF_PLUGIN_ROOT_MODE=active-project bash "$CD_HELPER" 2>/dev/null || true)"
  # Mirror the helper's resolution in a subshell so the detail line can
  # self-document which plugin root the rows were classified against.
  cd_active_root="$(
    unset CLAUDE_PLUGIN_ROOT
    # shellcheck disable=SC1091
    PIPELINE_RESOLVE_MODE=active-project \
      source "$SCRIPT_DIR/_resolve-plugin-root.sh" 2>/dev/null || true
    printf '%s' "${CLAUDE_PLUGIN_ROOT:-}"
  )"
  if [ -z "$cd_active_root" ]; then
    cd_active_root="${CLAUDE_PLUGIN_ROOT:-}"
  fi
  cd_total=0
  cd_bug=0
  cd_a=0; cd_b=0; cd_c=0; cd_d=0; cd_e=0; cd_f=0
  cd_load_bearing_drift=0
  cd_load_bearing_names=()
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
      # Load-bearing escalation (#295): drift on any LOAD_BEARING_HOOKS
      # basename promotes A/B/C/E rows from warn to fail. B.bug already
      # fails; D/F have no plugin counterpart so cannot drift in this sense.
      case "$bucket" in
        A|B|C|E)
          _cd_bn="$(basename "$_path")"
          for _lb in "${LOAD_BEARING_HOOKS[@]}"; do
            if [ "$_cd_bn" = "$_lb" ]; then
              cd_load_bearing_drift=$((cd_load_bearing_drift + 1))
              cd_load_bearing_names+=("$_cd_bn")
              break
            fi
          done
          ;;
      esac
    done <<< "$cd_rows"
  fi

  cd_against=""
  if [ -n "$cd_active_root" ]; then
    cd_against=" (against $cd_active_root)"
  fi
  if [ "$cd_bug" -gt 0 ]; then
    record consumer_drift fail "$cd_bug active bug(s) (B.bug): hardcoded literal disagrees with pipeline.config$cd_against"
  elif [ "$cd_load_bearing_drift" -gt 0 ]; then
    _cd_lb_csv="$(IFS=','; echo "${cd_load_bearing_names[*]}")"
    record consumer_drift fail "$cd_load_bearing_drift load-bearing hook(s) drifted ($_cd_lb_csv) — defense-in-depth at risk$cd_against"
    unset _cd_lb_csv
  elif [ $((cd_a + cd_b + cd_c + cd_e)) -gt 0 ]; then
    record consumer_drift warn "$cd_total file(s) drifted (A=$cd_a B=$cd_b C=$cd_c E=$cd_e)$cd_against"
  else
    record consumer_drift pass "no drifted consumer files$cd_against"
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

# BEGIN container_assets_unwired
# --------------------------------------------------------------------------
# Check: container_assets_unwired — detect compose.<mode>.{yml,yaml} files at
# the project root whose mode is not declared in PIPELINE_EVAL_CONTAINERS but
# whose intent IS witnessed by a .claude/hooks/*.py reading an env var the
# compose file sets (the "marker-env triangle"). Helper:
# scripts/check-container-assets.sh — see ## container_assets_unwired check
# in skills/doctor/SKILL.md for the verdict table.
#   pass — declared OR `# pipeline:manual-only` opt-out in first 5 lines
#   warn — assets present but no marker-triangle / yaml-parse-skipped
#   fail — full triangle: compose sets MARKER, hook reads MARKER, undeclared
# Mirrors the dispatch-layer drift detected by consumer_drift, applied to a
# different surface.
# --------------------------------------------------------------------------
CA_HELPER="$SCRIPT_DIR/check-container-assets.sh"
if [ ! -f "$CA_HELPER" ]; then
  record container_assets_unwired warn "check-container-assets.sh not found at $CA_HELPER"
else
  ca_out="$(bash "$CA_HELPER" 2>&1)"
  ca_rc=$?
  # Final status line shape: `status=<pass|warn|fail> detail=<msg>`. Pick the
  # last status= line (the helper emits exactly one, at the end).
  ca_status_line="$(printf '%s\n' "$ca_out" | grep -E '^status=' | tail -1)"
  ca_status="$(printf '%s' "$ca_status_line" | sed -E 's/^status=([a-z]+).*/\1/')"
  ca_detail="$(printf '%s' "$ca_status_line" | sed -E 's/^status=[a-z]+ detail=//')"
  case "$ca_status" in
    pass|warn|fail)
      record container_assets_unwired "$ca_status" "$ca_detail"
      ;;
    *)
      record container_assets_unwired warn "helper produced no status line (rc=$ca_rc)"
      ;;
  esac
  # Replay per-asset diagnostic lines under the CHECK line (everything but the
  # trailing status= line). Mirrors the consumer_drift summary-table shape.
  ca_diag="$(printf '%s\n' "$ca_out" | grep -vE '^status=' || true)"
  if [ -n "$ca_diag" ]; then
    echo "  === container_assets_unwired report ==="
    printf '%s\n' "$ca_diag"
  fi
fi
# END container_assets_unwired

# --------------------------------------------------------------------------
# Check: preservation_refs — per-file reference report. For every consumer
# .claude/{scripts,hooks}/ file whose basename collides with a plugin-shipped
# file, list each external reference (settings.json / SKILL.md / doc) holding
# the file in place and emit a DELETE / KEEP verdict. Informational only;
# pass when zero files OR every verdict is DELETE; warn when ≥1 KEEP.
# --------------------------------------------------------------------------
PR_HELPER="$SCRIPT_DIR/scan-preservation-refs.sh"
if [ ! -f "$PR_HELPER" ]; then
  record preservation_refs warn "scan-preservation-refs.sh not found at $PR_HELPER"
else
  pr_rows="$(bash "$PR_HELPER" 2>/dev/null || true)"
  pr_files=0; pr_keeps=0; pr_deletes=0
  if [ -n "$pr_rows" ]; then
    while IFS=$'\t' read -r _type _path _verdict _hint _ignore; do
      [ "$_type" = "VERDICT" ] || continue
      pr_files=$((pr_files + 1))
      case "$_verdict" in
        KEEP)   pr_keeps=$((pr_keeps + 1)) ;;
        DELETE) pr_deletes=$((pr_deletes + 1)) ;;
      esac
    done <<<"$pr_rows"
  fi
  if [ "$pr_files" -eq 0 ]; then
    record preservation_refs pass "no preserved consumer files with plugin counterparts"
  elif [ "$pr_keeps" -eq 0 ]; then
    record preservation_refs pass "$pr_files file(s) classified: 0 KEEP, $pr_deletes DELETE"
  else
    record preservation_refs warn "$pr_files file(s): $pr_keeps KEEP, $pr_deletes DELETE — review report"
  fi
  if [ "$pr_files" -gt 0 ]; then
    echo "  === preservation_refs report ==="
    declare -A _seen_path=()
    _paths=()
    while IFS=$'\t' read -r _type _path _r1 _r2 _r3; do
      [ -z "$_type" ] && continue
      [ -z "$_path" ] && continue
      [ -n "${_seen_path[$_path]:-}" ] && continue
      _seen_path["$_path"]=1
      _paths+=("$_path")
    done <<<"$pr_rows"
    for _p in "${_paths[@]:-}"; do
      [ -n "$_p" ] || continue
      echo "  $_p"
      echo "    References:"
      while IFS=$'\t' read -r _type _path _ref _bucket _snippet; do
        [ "$_type" = "REF" ] || continue
        [ "$_path" = "$_p" ] || continue
        _annot=""
        if command -v advisory_for_ref_source >/dev/null 2>&1; then
          _annot="$(advisory_for_ref_source "$_bucket" 2>/dev/null || true)"
        fi
        if [ -n "$_annot" ]; then
          printf '      - %s  → %s (%s)\n' "$_ref" "$_annot" "$_bucket"
        else
          printf '      - %s  → %s\n' "$_ref" "$_bucket"
        fi
      done <<<"$pr_rows"
      while IFS=$'\t' read -r _type _path _verdict _hint _ignore; do
        [ "$_type" = "VERDICT" ] || continue
        [ "$_path" = "$_p" ] || continue
        printf '    Verdict: %s — %s\n' "$_verdict" "$_hint"
      done <<<"$pr_rows"
      echo
    done
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
# Check: claude_plugin_root — four states based on the pre-resolve snapshot:
#   * env pre-set + valid dir            → pass
#   * env pre-set + path missing/invalid → warn (likely stale config)
#   * env empty   + self-resolved OK     → pass (self-resolve is recommended)
#   * env empty   + no plugin cache      → fail
# Snapshot captured at the top of this script before the resolver source.
# --------------------------------------------------------------------------
if [ -n "${_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE:-}" ]; then
  if [ -d "${_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE}" ]; then
    record claude_plugin_root pass "env pre-set to ${CLAUDE_PLUGIN_ROOT}"
  else
    record claude_plugin_root warn "env points to non-existent path: ${_CLAUDE_PLUGIN_ROOT_PRE_RESOLVE}"
  fi
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  record claude_plugin_root pass "self-resolved from plugin cache: ${CLAUDE_PLUGIN_ROOT}"
else
  record claude_plugin_root fail "CLAUDE_PLUGIN_ROOT empty and no plugin cache found at ~/.claude/plugins/cache/claude-pipeline/pipeline/"
fi

# If a plugin cache exists, independently compute the expected highest-semver
# path and downgrade to warn when the effective CLAUDE_PLUGIN_ROOT disagrees.
# Silent stale resolution (e.g., env pre-set to 0.7.2 while cache contains
# 0.8.0-rc.5) is the worse failure mode; surface it explicitly.
_expected_root=""
_cache_dir="${PIPELINE_PLUGIN_CACHE_DIR:-${HOME}/.claude/plugins/cache/claude-pipeline/pipeline}"
if [ -d "$_cache_dir" ]; then
  _expected_root="$(
    unset CLAUDE_PLUGIN_ROOT
    # shellcheck disable=SC1090
    source "$RESOLVER_DIR/_resolve-plugin-root.sh" 2>/dev/null || true
    printf '%s' "${CLAUDE_PLUGIN_ROOT:-}"
  )"
fi
if [ -n "$_expected_root" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] \
    && [ "$(basename "$CLAUDE_PLUGIN_ROOT")" != "$(basename "$_expected_root")" ]; then
  # Override the just-recorded claude_plugin_root status in place AND emit a
  # second CHECK line so log consumers tailing the stream see the downgrade.
  for _i in "${!CHECK_NAMES[@]}"; do
    if [ "${CHECK_NAMES[$_i]}" = "claude_plugin_root" ]; then
      CHECK_STATUSES[$_i]="warn"
    fi
  done
  printf 'CHECK: %s status=%s detail=%s\n' \
    "claude_plugin_root" "warn" \
    "stale resolution: resolved $(basename "$CLAUDE_PLUGIN_ROOT") != expected highest-semver $(basename "$_expected_root")"
fi
unset _expected_root _cache_dir _i

# --------------------------------------------------------------------------
# Check: base_branch_enforcement — defense-in-depth (#295) for the
# `enforce-base-branch.py` PreToolUse hook. Pass when the hook file exists
# on disk AND at least one PreToolUse Bash matcher (in the plugin manifest
# OR the consumer's .claude/settings.json) invokes it. Fail when the file
# is missing, or when it exists but no matcher is wired.
# --------------------------------------------------------------------------
_bbe_plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
_bbe_hook_path=""
if [ -n "$_bbe_plugin_root" ] && [ -f "$_bbe_plugin_root/hooks/enforce-base-branch.py" ]; then
  _bbe_hook_path="$_bbe_plugin_root/hooks/enforce-base-branch.py"
fi

_bbe_plugin_registered=0
_bbe_plugin_manifest="${_bbe_plugin_root}/.claude-plugin/plugin.json"
if [ -n "$_bbe_plugin_root" ] && [ -f "$_bbe_plugin_manifest" ] && command -v jq >/dev/null 2>&1; then
  if jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command' \
       "$_bbe_plugin_manifest" 2>/dev/null \
       | grep -qF 'enforce-base-branch.py'; then
    _bbe_plugin_registered=1
  fi
fi

_bbe_consumer_registered=0
_bbe_consumer_settings=".claude/settings.json"
if [ -f "$_bbe_consumer_settings" ] && command -v jq >/dev/null 2>&1; then
  if jq -r '.hooks.PreToolUse[]? | select(.matcher=="Bash") | .hooks[]?.command' \
       "$_bbe_consumer_settings" 2>/dev/null \
       | grep -qF 'enforce-base-branch.py'; then
    _bbe_consumer_registered=1
  fi
fi

if [ -z "$_bbe_hook_path" ]; then
  record base_branch_enforcement fail "enforce-base-branch.py not present on disk (expected at \${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py)"
elif [ "$_bbe_plugin_registered" = "1" ]; then
  record base_branch_enforcement pass "wired via plugin manifest PreToolUse Bash matcher"
elif [ "$_bbe_consumer_registered" = "1" ]; then
  record base_branch_enforcement pass "wired via consumer .claude/settings.json PreToolUse Bash matcher"
else
  record base_branch_enforcement fail "hook exists but no PreToolUse Bash matcher invokes it (check plugin manifest or .claude/settings.json)"
fi
unset _bbe_plugin_root _bbe_hook_path _bbe_plugin_registered _bbe_plugin_manifest _bbe_consumer_registered _bbe_consumer_settings

# --------------------------------------------------------------------------
# Check: container_skills_validity (issue #321).
# Pass when PIPELINE_CONTAINER_SKILLS is unset (default 'evaluate-issue-pr'),
# empty (explicit disable), or contains only canonical skill names. Warn
# when an unknown skill name appears. Never fails — misconfig is recoverable
# (spawn-claude.sh still rejects bad dispatches at exit 4); this check
# surfaces typos early.
# --------------------------------------------------------------------------
check_container_skills_validity() {
  local name="container_skills_validity"

  # Distinguish unset from empty using parameter expansion +x.
  if [ -z "${PIPELINE_CONTAINER_SKILLS+x}" ]; then
    record "$name" pass "default (evaluate-issue-pr)"
    return 0
  fi
  if [ -z "$PIPELINE_CONTAINER_SKILLS" ]; then
    record "$name" pass "disabled (explicit empty)"
    return 0
  fi

  # Derive the canonical skill set at runtime from the plugin's skills
  # directory. ${CLAUDE_PLUGIN_ROOT} is resolved by the existing
  # _resolve-plugin-root.sh helper at doctor.sh boot.
  local skills_dir="${CLAUDE_PLUGIN_ROOT:-}/skills"
  if [ ! -d "$skills_dir" ]; then
    # Fallback for dogfood self-runs where the script is invoked from the
    # source repo with CLAUDE_PLUGIN_ROOT unset and no plugin-cache install.
    skills_dir="$(cd "$(dirname "$0")/.." && pwd)/skills"
  fi
  if [ ! -d "$skills_dir" ]; then
    record "$name" warn "cannot resolve skills/ directory; skipping canonical check"
    return 0
  fi
  local canonical
  canonical="$(ls "$skills_dir" 2>/dev/null | tr '\n' ' ')"

  local unknown=""
  local count=0
  for sk in $PIPELINE_CONTAINER_SKILLS; do
    count=$((count + 1))
    if ! printf '%s\n' $canonical | tr ' ' '\n' | grep -qx "$sk"; then
      unknown="$unknown $sk"
    fi
  done
  unknown="${unknown# }"

  if [ -z "$unknown" ]; then
    record "$name" pass "$count skill(s) all canonical"
    return 0
  fi
  record "$name" warn "unknown skill(s): $unknown"
  return 0
}
check_container_skills_validity

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
