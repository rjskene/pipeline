# shellcheck shell=bash
# Resolve a per-container env var with uppercase-wins-with-lowercase-fallback.
# Usage: val=$(_resolve_container_var <mode> <suffix>)
# Suffix is appended after `_<NORM>_` and is NOT case-folded (callers pass
# the canonical suffix verbatim, e.g. COMPOSE_FILE, SERVICE, ENV_FILE,
# PREFLIGHT_CMD, MAX_CONCURRENT).
_resolve_container_var() {
  local mode="$1" suffix="$2"
  local norm_lower norm_upper var_upper var_lower
  norm_lower="$(echo "$mode" | tr '-' '_')"
  norm_upper="$(echo "$norm_lower" | tr '[:lower:]' '[:upper:]')"
  var_upper="PIPELINE_EVAL_CONTAINER_${norm_upper}_${suffix}"
  var_lower="PIPELINE_EVAL_CONTAINER_${norm_lower}_${suffix}"
  printf '%s' "${!var_upper:-${!var_lower:-}}"
}
