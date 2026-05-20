#!/bin/bash
# scripts/check-container-assets.sh — detect compose.<mode>.{yml,yaml} assets
# at the project root whose mode is not declared in PIPELINE_EVAL_CONTAINERS
# but whose intent IS witnessed by a .claude/hooks/*.py reading an env var
# the compose file sets (the "marker-env triangle"). Read-only.
#
# Per-asset verdict order:
#   1. opt-out: `# pipeline:manual-only` in first 5 lines       → PASS
#   2. declared: mode appears in PIPELINE_EVAL_CONTAINERS list   → PASS
#   3. full triangle: compose sets KEY, hook reads KEY           → FAIL
#   4. yaml-parse-skipped + no reader-overlap evidence           → WARN (yaml-parse-skipped)
#   5. undeclared, no reader-overlap                             → WARN
#
# Aggregate: any FAIL → fail (rc=1); else any WARN → warn (rc=2); else pass (rc=0).
# Reused by doctor.sh's container_assets_unwired check.

set -uo pipefail

[ -f ./pipeline.config ] && source ./pipeline.config 2>/dev/null

declared=" ${PIPELINE_EVAL_CONTAINERS:-} "

shopt -s nullglob
composes=(compose.*.yml compose.*.yaml)
shopt -u nullglob

if [ "${#composes[@]}" -eq 0 ]; then
  echo "status=pass detail=no compose.<mode>.{yml,yaml} files at repo root"
  exit 0
fi

# --------------------------------------------------------------------------
# parse_env_keys <compose_file>
# Emit the list of environment-block keys (one per line). Probe yq first;
# fall back to a flat-block awk scanner. Returns non-zero AND writes a
# `__YAML_SKIPPED__` sentinel line when both parsers fail to extract a
# non-empty key set in a file that contains a literal `environment:` token.
# --------------------------------------------------------------------------
parse_env_keys() {
  local cf="$1"
  local keys=""

  if command -v yq >/dev/null 2>&1; then
    keys="$(yq eval -o=tsv '.services.*.environment | keys | .[]' "$cf" 2>/dev/null \
            | grep -vE '^(null|---)$' \
            | sort -u || true)"
    if [ -n "$keys" ]; then
      printf '%s\n' "$keys"
      return 0
    fi
  fi

  # Flat awk fallback — assumes a literal `environment:` block followed by
  # `  KEY: value` lines at a deeper indent. Handles the 90% case (one or
  # more services with inline env maps). Returns nothing for YAML shapes
  # using anchors / merges / single-line maps.
  keys="$(awk '
    /^[[:space:]]+environment:[[:space:]]*$/ {
      inenv = 1
      # capture indent of environment: line
      match($0, /^[[:space:]]*/)
      env_indent = RLENGTH
      next
    }
    inenv == 1 {
      # blank line ends nothing in YAML; only a line at <= env_indent ends the block
      if ($0 ~ /^[[:space:]]*$/) { next }
      match($0, /^[[:space:]]*/)
      cur_indent = RLENGTH
      if (cur_indent <= env_indent) { inenv = 0; next }
      # extract KEY token from KEY: ... or KEY = ...
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (match(line, /^[A-Za-z_][A-Za-z0-9_]*/)) {
        key = substr(line, 1, RLENGTH)
        print key
      }
    }
  ' "$cf" | sort -u)"

  if [ -n "$keys" ]; then
    printf '%s\n' "$keys"
    return 0
  fi

  # No keys extracted. If the file contains an `environment:` token, treat
  # this as yaml-parse-skipped (so the caller stays at WARN, not FAIL).
  if grep -qE '^[[:space:]]+environment:' "$cf" 2>/dev/null; then
    echo "__YAML_SKIPPED__"
    return 1
  fi

  return 0
}

# --------------------------------------------------------------------------
# Extract the first services.<name>: key. Best-effort; empty when the file
# uses non-standard indentation or no `services:` block at all. Uses 2-arg
# match() + substr() so the helper is portable to mawk / BWK awk / busybox
# awk (the 3-arg array-capture form is a GNU awk extension).
# --------------------------------------------------------------------------
parse_first_service() {
  local cf="$1"
  awk '
    /^services:[[:space:]]*$/ { inservices = 1; next }
    inservices == 1 {
      if ($0 ~ /^[^[:space:]]/) { inservices = 0; next }
      if (match($0, /^[[:space:]]+[A-Za-z0-9_-]+:/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^[[:space:]]+/, "", s)
        sub(/:$/, "", s)
        print s
        exit
      }
    }
  ' "$cf" 2>/dev/null
}

fails=0
warns=0
asset_count=0

for cf in "${composes[@]}"; do
  asset_count=$((asset_count + 1))
  mode="${cf#compose.}"
  mode="${mode%.yml}"
  mode="${mode%.yaml}"

  # 1. Opt-out scan — first 5 lines only.
  if head -n5 "$cf" 2>/dev/null | grep -qE '^[[:space:]]*#[[:space:]]*pipeline:manual-only'; then
    echo "  $cf (mode: $mode) — PASS (explicit opt-out: # pipeline:manual-only)"
    continue
  fi

  # 2. Declared check (word-boundary match against space-padded list).
  if printf '%s' "$declared" | tr ' ' '\n' | grep -qx "$mode"; then
    echo "  $cf (mode: $mode) — PASS (declared in PIPELINE_EVAL_CONTAINERS)"
    continue
  fi

  # 3. Parse compose-set env keys.
  yaml_skipped=0
  raw_keys="$(parse_env_keys "$cf")"
  parse_rc=$?
  if [ "$parse_rc" -ne 0 ] || printf '%s\n' "$raw_keys" | grep -qx '__YAML_SKIPPED__'; then
    yaml_skipped=1
    raw_keys=""
  fi

  # Filter out plugin-internal PIPELINE_* keys.
  filtered_keys="$(printf '%s\n' "$raw_keys" \
                    | grep -vE '^PIPELINE_' \
                    | grep -vE '^[[:space:]]*$' \
                    || true)"

  # 4. Scan .claude/hooks/*.py for a quoted-literal match of any compose-set
  # key. The triangle requires overlap: a hook that reads an unrelated env
  # var does NOT complete the triangle.
  reader_files=""
  reader_marker=""
  if [ -n "$filtered_keys" ] && [ -d .claude/hooks ]; then
    while IFS= read -r mk; do
      [ -z "$mk" ] && continue
      while IFS= read -r hf; do
        [ -f "$hf" ] || continue
        if grep -qE "['\"]${mk}['\"]" "$hf" 2>/dev/null; then
          reader_files="$hf"
          reader_marker="$mk"
          break 2
        fi
      done < <(find .claude/hooks -name '*.py' 2>/dev/null)
    done <<< "$filtered_keys"
  fi

  # 5. Verdict.
  if [ -n "$reader_files" ]; then
    # Full triangle complete — FAIL with suggested snippet.
    echo "  $cf (mode: $mode) — FAIL (undeclared compose asset with full marker-triangle)"
    echo "    Marker env var set by compose: $reader_marker"
    echo "    Marker reader: $reader_files"
    svc="$(parse_first_service "$cf")"
    [ -n "$svc" ] && echo "    Service:    $svc"
    dfile="Dockerfile.$mode"
    [ -f "$dfile" ] && echo "    Dockerfile: $dfile"
    efile=".env.$mode"
    [ -f "$efile" ] && echo "    Env file:   $efile"
    upper="$(printf '%s' "$mode" | tr '[:lower:]-' '[:upper:]_')"
    echo "    Suggested pipeline.config additions:"
    echo "      PIPELINE_EVAL_CONTAINERS=\"$mode\""
    echo "      PIPELINE_EVAL_CONTAINER_${upper}_COMPOSE_FILE=\"$cf\""
    [ -n "$svc" ]   && echo "      PIPELINE_EVAL_CONTAINER_${upper}_SERVICE=\"$svc\""
    [ -f "$efile" ] && echo "      PIPELINE_EVAL_CONTAINER_${upper}_ENV_FILE=\"$efile\""
    fails=$((fails + 1))
  elif [ "$yaml_skipped" = "1" ]; then
    # YAML environment block unparseable. Never escalate to FAIL without
    # confirmed marker-set evidence.
    echo "  $cf (mode: $mode) — WARN (undeclared; note=yaml-parse-skipped)"
    warns=$((warns + 1))
  else
    # Undeclared, no triangle overlap.
    echo "  $cf (mode: $mode) — WARN (undeclared; no marker-reader hook found)"
    warns=$((warns + 1))
  fi
done

if [ "$fails" -gt 0 ]; then
  echo "status=fail detail=$fails compose asset(s) with intent-evidence not in PIPELINE_EVAL_CONTAINERS"
  exit 1
elif [ "$warns" -gt 0 ]; then
  echo "status=warn detail=$warns compose asset(s) undeclared (no marker-triangle)"
  exit 2
fi

echo "status=pass detail=$asset_count compose asset(s) properly declared or opted-out"
exit 0
