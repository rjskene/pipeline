#!/bin/bash
set -uo pipefail

# Guard against the class of bug fixed in #345 (refactor #315 consolidated
# the mock-web-eval subsystem into mock-web-eval/, leaving pipeline.config
# and pipeline.config.example with stale pre-refactor paths).
#
# Scans pipeline.config.example for the documented mock-web-eval container
# block and asserts every path-bearing value resolves to a real file (or,
# for runtime-written env files, a real parent directory) in the checked-in
# tree. Also checks the live pipeline.config when present (for dogfood
# operators); the file is gitignored, so this branch is a no-op in CI.
#
# Variables checked (per file):
#   PIPELINE_EVAL_CLASSIFIER                                   -> file
#   PIPELINE_EVAL_CONTAINER_<mode>_COMPOSE_FILE                -> file
#   PIPELINE_EVAL_CONTAINER_<mode>_ENV_FILE                    -> parent dir
#   PIPELINE_EVAL_CONTAINER_<mode>_PREFLIGHT_CMD (path arg)    -> file
#
# Skipped (shape-only placeholders, not real paths in this repo):
#   - generic `.claude/scripts/eval-classifier.sh` example (line ~120)
#   - the `WEB_EVAL` block (lines 175-179) — illustrative consumer shape

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$EXAMPLE" ]; then
  echo "ERROR: $EXAMPLE not found" >&2
  exit 1
fi

# Echoes "<kind>|<var>|<path>" per matched assignment. <kind> is one of
# file | dir. Handles both live and commented (# PIPELINE_EVAL_...) forms.
extract_paths() {
  local file="$1"
  awk '
    function clean(v) {
      sub(/^[^=]*=/, "", v)
      sub(/^"/, "", v); sub(/".*$/, "", v)
      sub(/^\047/, "", v); sub(/\047.*$/, "", v)
      return v
    }
    function name_of(line) {
      sub(/^[[:space:]]*#?[[:space:]]*/, "", line)
      split(line, a, "=")
      return a[1]
    }
    /^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CLASSIFIER=/ {
      name = name_of($0)
      val = clean($0)
      if (val != "") print "file|" name "|" val
    }
    /^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CONTAINER_[A-Za-z0-9_]+_COMPOSE_FILE=/ {
      name = name_of($0)
      val = clean($0)
      if (val != "") print "file|" name "|" val
    }
    /^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CONTAINER_[A-Za-z0-9_]+_ENV_FILE=/ {
      name = name_of($0)
      val = clean($0)
      if (val != "") print "dir|" name "|" val
    }
    /^[[:space:]]*#?[[:space:]]*PIPELINE_EVAL_CONTAINER_[A-Za-z0-9_]+_PREFLIGHT_CMD=/ {
      name = name_of($0)
      val = clean($0)
      # Strip leading interpreter + whitespace ("bash ", "sh ", etc.) to
      # recover the script path.
      sub(/^[A-Za-z0-9_\/.-]+[[:space:]]+/, "", val)
      if (val != "") print "file|" name "|" val
    }
  ' "$file"
}

# Skip shape-only placeholders that are documentation, not real paths.
# Both UPPERCASE (post-#336 canonical) and lowercase (pre-#336 back-compat
# fallback, still documented in mock-web-eval/replay/*) are skipped.
is_placeholder() {
  local var="$1" path="$2"
  case "$var" in
    PIPELINE_EVAL_CONTAINER_WEB_EVAL_*) return 0 ;;
    PIPELINE_EVAL_CONTAINER_web_eval_*) return 0 ;;
  esac
  case "$path" in
    .claude/scripts/eval-classifier.sh) return 0 ;;
  esac
  return 1
}

check() {
  local label="$1" kind="$2" var="$3" path="$4"
  inc
  case "$kind" in
    file)
      if [ -f "$ROOT/$path" ]; then
        pass_msg "$label: $var -> $path"
      else
        fail_msg "$label: $var -> $path does not exist"
      fi
      ;;
    dir)
      local parent
      parent="$(dirname "$path")"
      if [ -d "$ROOT/$parent" ]; then
        pass_msg "$label: $var -> $path (parent dir $parent exists)"
      else
        fail_msg "$label: $var -> $path parent dir $parent does not exist"
      fi
      ;;
  esac
}

# Canonical example file (always in git, so always exercised).
while IFS='|' read -r kind var val; do
  [ -z "$var" ] && continue
  if is_placeholder "$var" "$val"; then
    continue
  fi
  check "example" "$kind" "$var" "$val"
done < <(extract_paths "$EXAMPLE")

# Live dogfood pipeline.config (gitignored; only present on dogfood hosts).
if [ -f "$LIVE" ]; then
  while IFS='|' read -r kind var val; do
    [ -z "$var" ] && continue
    if is_placeholder "$var" "$val"; then
      continue
    fi
    check "live" "$kind" "$var" "$val"
  done < <(extract_paths "$LIVE")
fi

# --- Issue #517 scaffolding: inline-default evaluator dispatch vars ---
#
# Assert the new evaluator-isolation + visual-proof config vars are present
# (by name) in pipeline.config.example. PIPELINE_EVAL_ISOLATION uses the
# comment-as-default convention: the only mention of its name should be the
# leading "# PIPELINE_EVAL_ISOLATION=..." documentation line; no uncommented
# assignment may exist (empty = inline default).
check_var_named() {
  local var="$1"
  inc
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${var}=" "$EXAMPLE"; then
    pass_msg "example: $var name appears in pipeline.config.example"
  else
    fail_msg "example: $var name missing from pipeline.config.example"
  fi
}

check_var_named PIPELINE_EVAL_ISOLATION
check_var_named PIPELINE_VISUAL_PROOF_TARGET_DIR
check_var_named PIPELINE_VISUAL_PROOF_PORT_BASE

# PIPELINE_EVAL_ISOLATION: comment-as-default convention — no uncommented
# assignment may exist. Only commented "# PIPELINE_EVAL_ISOLATION=..." lines
# are allowed.
inc
if grep -Eq "^[[:space:]]*PIPELINE_EVAL_ISOLATION=" "$EXAMPLE"; then
  fail_msg "example: PIPELINE_EVAL_ISOLATION has an uncommented assignment (expected comment-as-default only)"
else
  pass_msg "example: PIPELINE_EVAL_ISOLATION uses comment-as-default convention (no uncommented assignment)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
