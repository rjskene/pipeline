#!/bin/bash
# _resolve-plugin-root.sh — sourceable helper.
#
# Default mode: when CLAUDE_PLUGIN_ROOT is empty/unset (which can happen
# because Claude Code does not consistently export it into the Bash tool's
# subshell), scan ~/.claude/plugins/cache/claude-pipeline/pipeline/*/ and
# export the highest-version directory. Highest `MAJOR.MINOR.PATCH` wins
# across the whole cache; within the same `M.m.p`, stable beats prerelease
# (`-rc.N`), and rc numbers sort numerically.
#
# Active-project mode (PIPELINE_RESOLVE_MODE=active-project): read
# ~/.claude/plugins/installed_plugins.json (override via
# PIPELINE_INSTALLED_PLUGINS_FILE) and pick the installPath of the pipeline@*
# entry whose projectPath matches $PWD. Falls through to the default cache
# scan when no entry matches, when python3 is unavailable, or when the file
# is missing/malformed. This mode is opt-in and only used by callers that
# need the per-project active plugin (notably doctor.sh's consumer_drift
# check), so the default mode's behavior is byte-stable.
#
# Idempotent. Silent on success. No-op when already set or when no cache exists.
#
# NOTE: the plugin cache path is a Claude Code internal. If Anthropic moves it,
# set PIPELINE_PLUGIN_CACHE_DIR to point at the new location.

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

if [ "${PIPELINE_RESOLVE_MODE:-}" = "active-project" ]; then
  _rpr_plugins_file="${PIPELINE_INSTALLED_PLUGINS_FILE:-${HOME}/.claude/plugins/installed_plugins.json}"
  if [ -f "$_rpr_plugins_file" ] && command -v python3 >/dev/null 2>&1; then
    _rpr_active="$(
      PIPELINE_RPR_PWD="$PWD" \
      PIPELINE_RPR_FILE="$_rpr_plugins_file" \
      python3 -c '
import json, os, sys
try:
    with open(os.environ["PIPELINE_RPR_FILE"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
pwd = os.environ.get("PIPELINE_RPR_PWD", "")
plugins = data.get("plugins") or {}
stable, pre = [], []
for key, entries in plugins.items():
    if not key.startswith("pipeline@"):
        continue
    if not isinstance(entries, list):
        continue
    for e in entries:
        if not isinstance(e, dict):
            continue
        if e.get("projectPath") == pwd and e.get("installPath"):
            v = e.get("version", "")
            (pre if "-" in v else stable).append((v, e["installPath"]))
# Defensive tie-break across degenerate same-projectPath entries:
# stable releases beat prereleases (matches existing cache-scan semantics);
# within each group, highest version wins.
def vkey(s):
    parts = []
    for tok in s.replace("-", ".").split("."):
        try:
            parts.append((0, int(tok)))
        except ValueError:
            parts.append((1, tok))
    return parts
pool = stable or pre
if not pool:
    sys.exit(0)
pool.sort(key=lambda t: vkey(t[0]))
print(pool[-1][1])
' 2>/dev/null
    )"
    if [ -n "$_rpr_active" ] && [ -d "$_rpr_active" ]; then
      export CLAUDE_PLUGIN_ROOT="$_rpr_active"
      unset _rpr_plugins_file _rpr_active
      return 0 2>/dev/null || exit 0
    fi
    unset _rpr_active
  fi
  unset _rpr_plugins_file
  # Fall through to cache scan when active-project lookup yields nothing.
fi

_rpr_cache="${PIPELINE_PLUGIN_CACHE_DIR:-${HOME}/.claude/plugins/cache/claude-pipeline/pipeline}"

if [ ! -d "$_rpr_cache" ]; then
  unset _rpr_cache
  return 0 2>/dev/null || exit 0
fi

_rpr_pick() {
  # Emit `<sort-key>\t<basename>` for each cache entry, sort numerically on the
  # 5-field key, then strip the key and pick the tail. Skip dirnames that do not
  # match the expected MAJOR.MINOR.PATCH[-rc.N] shape so a stray dir never wins.
  local d base major minor patch pre_rank pre_num
  local -a rows=()
  for d in "$_rpr_cache"/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    if [[ "$base" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-rc\.([0-9]+))?$ ]]; then
      major="${BASH_REMATCH[1]}"
      minor="${BASH_REMATCH[2]}"
      patch="${BASH_REMATCH[3]}"
      if [ -n "${BASH_REMATCH[4]}" ]; then
        # Prerelease: rank=0 so it sorts BELOW stable (rank=1) at the same MMP
        # under ascending sort + `tail -n 1`. Rank field comes BEFORE the numeric
        # rc index so 0.4.0 (stable, rank=1) outranks 0.4.0-rc.99 (rank=0, num=99)
        # at the same MMP.
        pre_rank=0
        pre_num="${BASH_REMATCH[5]}"
      else
        pre_rank=1
        pre_num=0
      fi
      rows+=("${major}.${minor}.${patch}.${pre_rank}.${pre_num}	${base}")
    fi
  done
  [ "${#rows[@]}" -gt 0 ] || return 0
  printf '%s\n' "${rows[@]}" \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n \
    | tail -n 1 \
    | cut -f2
}

_rpr_latest="$(_rpr_pick)"
if [ -n "$_rpr_latest" ]; then
  export CLAUDE_PLUGIN_ROOT="$_rpr_cache/$_rpr_latest"
fi

unset -f _rpr_pick
unset _rpr_cache _rpr_latest
