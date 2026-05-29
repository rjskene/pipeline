#!/bin/bash
# _resolve-plugin-root.sh — sourceable helper.
#
# Default mode: when CLAUDE_PLUGIN_ROOT is empty/unset (which can happen
# because Claude Code does not consistently export it into the Bash tool's
# subshell), first apply the dogfood local-marketplace tie-break (#625): if the
# current project ($PWD) has the pipeline@claude-pipeline-local install ENABLED
# (per the project settings.local.json enabledPlugins) and an install entry in
# installed_plugins.json, export that install's installPath (a symlink to the
# repo working tree) and stop — this beats any same-version published copy.
# Override the project settings path under test via PIPELINE_PROJECT_SETTINGS_FILE.
# Consumer hosts (no local-marketplace install) fall straight through.
#
# Otherwise scan ~/.claude/plugins/cache/claude-pipeline/pipeline/*/ and
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

if [ "${PIPELINE_USE_LOCAL_PLUGIN:-}" = "true" ] && command -v git >/dev/null 2>&1; then
  _rpr_top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$_rpr_top" ] && [ -f "$_rpr_top/.claude-plugin/plugin.json" ]; then
    _rpr_origin="$(git -C "$_rpr_top" remote get-url origin 2>/dev/null)"
    # Match rjskene/pipeline with optional .git suffix and either https or ssh form.
    if printf '%s' "$_rpr_origin" | grep -Eq '(^|[:/])rjskene/pipeline(\.git)?$'; then
      export CLAUDE_PLUGIN_ROOT="$_rpr_top"
      unset _rpr_top _rpr_origin
      return 0 2>/dev/null || exit 0
    fi
  fi
  unset _rpr_top _rpr_origin
fi

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

# Default-mode dogfood tie-break (#625): when running inside a project that has
# the local-marketplace install (pipeline@claude-pipeline-local) ENABLED, prefer
# its installPath (a symlink to the repo working tree) over any published copy
# the cache scan would otherwise pick. Gated on the local-marketplace key +
# enabledPlugins so consumer hosts (published install only) never enter here.
# Override the project settings path under test via PIPELINE_PROJECT_SETTINGS_FILE.
_rpr_ip_file="${PIPELINE_INSTALLED_PLUGINS_FILE:-${HOME}/.claude/plugins/installed_plugins.json}"
_rpr_settings_file="${PIPELINE_PROJECT_SETTINGS_FILE:-$PWD/.claude/settings.local.json}"
if [ -f "$_rpr_ip_file" ] && command -v python3 >/dev/null 2>&1; then
  _rpr_local="$(
    PIPELINE_RPR_PWD="$PWD" \
    PIPELINE_RPR_IPFILE="$_rpr_ip_file" \
    PIPELINE_RPR_SETTINGS="$_rpr_settings_file" \
    python3 -c '
import json, os, sys
pwd = os.environ.get("PIPELINE_RPR_PWD", "")
# enabledPlugins gate: only proceed if the local-marketplace key is explicitly true.
enabled = False
try:
    with open(os.environ["PIPELINE_RPR_SETTINGS"]) as fh:
        sett = json.load(fh)
    enabled = bool((sett.get("enabledPlugins") or {}).get("pipeline@claude-pipeline-local"))
except Exception:
    enabled = False
if not enabled:
    sys.exit(0)
try:
    with open(os.environ["PIPELINE_RPR_IPFILE"]) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
entries = (data.get("plugins") or {}).get("pipeline@claude-pipeline-local") or []
if not isinstance(entries, list):
    sys.exit(0)
for e in entries:
    if isinstance(e, dict) and e.get("projectPath") == pwd and e.get("installPath"):
        print(e["installPath"])
        break
' 2>/dev/null
  )"
  if [ -n "$_rpr_local" ] && [ -d "$_rpr_local" ]; then
    export CLAUDE_PLUGIN_ROOT="$_rpr_local"
    unset _rpr_ip_file _rpr_settings_file _rpr_local
    return 0 2>/dev/null || exit 0
  fi
  unset _rpr_local
fi
unset _rpr_ip_file _rpr_settings_file

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
