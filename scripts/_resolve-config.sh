#!/bin/bash
# _resolve-config.sh — sourceable helper that self-resolves PIPELINE_* config
# from the project's pipeline.config (issue #1022).
#
# WHY: SKILL `## Boot` blocks `source pipeline.config` into the skill's shell
# scope but do NOT `export` the vars, so a downstream `bash script.sh` subshell
# does not inherit them (e.g. fullsend/SKILL.md passes PIPELINE_REPO inline but
# NOT PIPELINE_BASE_BRANCH — the exact verify-execute-completion.sh:37 first-
# invocation abort under `set -u`). This helper fixes it SCRIPT-side via
# export-on-source, so callers need no change: source it BEFORE the caller's
# `: "${PIPELINE_*:?}"` guards and the vars self-resolve instead of aborting.
#
# REQUIRED-VAR UNION (the early-return predicate): the helper sources config
# when EITHER PIPELINE_REPO OR PIPELINE_BASE_BRANCH is unset/empty. When BOTH
# are already set it returns immediately (idempotent no-op). It never clobbers a
# pre-set value — `set -a; source pipeline.config; set +a` re-assigns from the
# config file, so if a caller has already exported a var the config's value
# WINS over an empty default but a caller that has NOT set the var picks it up;
# to honor the no-clobber contract for callers that DID set the var, the helper
# only sources when at least one var is missing AND it snapshots+restores any
# already-set var around the source. (See the snapshot/restore below.)
#
# RESOLUTION ORDER (mirrors _find_main_repo in create-checkpoint-tag.sh):
#   1. PIPELINE_PROJECT_ROOT env (validated: must hold pipeline.config)
#   2. git rev-parse --show-toplevel
#   3. walk-up from $PWD for a dir holding BOTH pipeline.config AND a .git entry
#      (the combined check rejects the plugin tree's own pipeline.config)
#
# FAIL-CLOSED: when no config is findable the helper leaves vars UNSET — it
# never hard-fails — so each caller's own `:?` guard still fires with its
# original error message. The helper only ADDS a resolution path.
#
# SAFETY:
#   - set -u-safe: all own-input reads use ${VAR:-} so sourcing into a `set -u`
#     host (verify-execute-completion.sh) never trips -u before resolution.
#   - set -e-safe: git calls are `|| true`-guarded (precedent
#     _resolve-plugin-root.sh:94) so sourcing into a `set -e` host
#     (finalize-issue-labels.sh, create-checkpoint-tag.sh) never aborts when
#     $PWD is not a git repo.
# Idempotent. Silent on success.

# Early-return predicate: no-op when BOTH required vars are already set.
if [ -n "${PIPELINE_REPO:-}" ] && [ -n "${PIPELINE_BASE_BRANCH:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# Snapshot any already-set vars so the source can never clobber them (no-clobber
# contract): a caller that exported PIPELINE_REPO but not PIPELINE_BASE_BRANCH
# keeps its value while the missing one is filled from config.
_rc_had_repo="${PIPELINE_REPO:-}"
_rc_had_branch="${PIPELINE_BASE_BRANCH:-}"

# ---- Resolve the project root holding pipeline.config -------------------------
_rc_root=""

# Tier 1: explicit override (validated — must hold pipeline.config).
if [ -n "${PIPELINE_PROJECT_ROOT:-}" ] && [ -f "${PIPELINE_PROJECT_ROOT}/pipeline.config" ]; then
  _rc_root="$PIPELINE_PROJECT_ROOT"
fi

# Tier 2: git toplevel (|| true-guarded for set -e hosts / non-git cwds).
if [ -z "$_rc_root" ] && command -v git >/dev/null 2>&1; then
  _rc_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$_rc_top" ] && [ -f "$_rc_top/pipeline.config" ]; then
    _rc_root="$_rc_top"
  fi
  unset _rc_top
fi

# Tier 3: walk up from $PWD for a dir holding BOTH pipeline.config AND a .git
# entry (file or dir — worktrees use a regular file). The combined check rejects
# a stray .git-less pipeline.config (e.g. a decoy or the plugin tree's own).
if [ -z "$_rc_root" ]; then
  _rc_dir="$PWD"
  while [ -n "$_rc_dir" ] && [ "$_rc_dir" != "/" ]; do
    if [ -f "$_rc_dir/pipeline.config" ] && { [ -d "$_rc_dir/.git" ] || [ -f "$_rc_dir/.git" ]; }; then
      _rc_root="$_rc_dir"
      break
    fi
    _rc_dir="$(dirname "$_rc_dir")"
  done
  unset _rc_dir
fi

# ---- Export-on-source --------------------------------------------------------
# Fail-closed: no root found => leave vars unset; the caller's :? guard fires.
if [ -n "$_rc_root" ] && [ -f "$_rc_root/pipeline.config" ]; then
  # `set -a` exports every var the config assigns so child `bash` subshells
  # inherit them (the core fix for sourced-but-not-exported). The example config
  # already wraps its body in `set -a` / `set +a`, so this is belt-and-braces.
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$_rc_root/pipeline.config" 2>/dev/null || true
  set +a
  # Restore any caller-set value the source may have overwritten (no-clobber).
  [ -n "$_rc_had_repo" ]   && export PIPELINE_REPO="$_rc_had_repo"
  [ -n "$_rc_had_branch" ] && export PIPELINE_BASE_BRANCH="$_rc_had_branch"
fi

unset _rc_root _rc_had_repo _rc_had_branch
return 0 2>/dev/null || exit 0
