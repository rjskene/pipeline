#!/bin/bash
set -euo pipefail

# check-config-drift.sh [CONFIG_EXAMPLE_PATH] [SCAN_DIR ...]
#
# Symmetric static lint over PIPELINE_* declared-vs-referenced symmetry.
#
# Declared set: PIPELINE_* assignments (live or commented) in CONFIG_EXAMPLE_PATH.
#   Pattern: `^\s*#?\s*PIPELINE_[A-Z0-9_]+=`. Both live (`PIPELINE_REPO=...`)
#   and commented-template (`# PIPELINE_PATH_A_SKILLS_EXECUTE=...`) lines count
#   — both document the var to operators.
#
# Referenced set: PIPELINE_* tokens grepped across SCAN_DIR(s).
#   Pattern: `\bPIPELINE_[A-Z0-9_]+\b`. Word-boundary anchors avoid catching
#   prose substrings.
#
# Findings groups:
#   ORPHAN       — declared, never referenced (suspected dead config knob).
#   UNDOCUMENTED — referenced, never declared (drift; needs doc).
#
# Allowlist (default `$REPO_ROOT/tests/config-drift-allowlist.txt`, override
# via `PIPELINE_CONFIG_DRIFT_ALLOWLIST`): one token per line, blank/`#`
# comments ignored. An entry ending in `_` is a concat-prefix wildcard:
# `PIPELINE_EVAL_` suppresses any token whose name begins `PIPELINE_EVAL_`.
#
# Exit 0 when both groups are empty post-allowlist (prints `check-config-drift: ok`
# to stdout). Exit 1 with grouped findings on stderr otherwise.
# Exit 2 on bad invocation (missing config-example / scan dir).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CONFIG_EXAMPLE="${1:-$REPO_ROOT/pipeline.config.example}"
shift || true
if [ "$#" -gt 0 ]; then
  SCAN_DIRS=("$@")
else
  SCAN_DIRS=("$REPO_ROOT/scripts" "$REPO_ROOT/skills" "$REPO_ROOT/hooks" "$REPO_ROOT/tests" "$REPO_ROOT/docs")
fi
ALLOWLIST="${PIPELINE_CONFIG_DRIFT_ALLOWLIST:-$REPO_ROOT/tests/config-drift-allowlist.txt}"

if [ ! -f "$CONFIG_EXAMPLE" ]; then
  echo "check-config-drift: config-example not found: $CONFIG_EXAMPLE" >&2
  exit 2
fi

EXISTING_SCAN_DIRS=()
for d in "${SCAN_DIRS[@]}"; do
  [ -d "$d" ] && EXISTING_SCAN_DIRS+=("$d")
done
if [ "${#EXISTING_SCAN_DIRS[@]}" -eq 0 ]; then
  echo "check-config-drift: no scan dirs found among: ${SCAN_DIRS[*]}" >&2
  exit 2
fi

# --- Declared set ---------------------------------------------------------
DECLARED=$(grep -hE '^\s*#?\s*PIPELINE_[A-Z0-9_]+=' "$CONFIG_EXAMPLE" \
  | sed -E 's/^\s*#?\s*(PIPELINE_[A-Z0-9_]+)=.*/\1/' \
  | sort -u)

# --- Referenced set -------------------------------------------------------
REFERENCED=$(grep -rEohI '\bPIPELINE_[A-Z0-9_]+\b' "${EXISTING_SCAN_DIRS[@]}" 2>/dev/null \
  | sort -u)

# --- Allowlist parser -----------------------------------------------------
ALLOW_EXACT=()
ALLOW_PREFIX=()
if [ -f "$ALLOWLIST" ]; then
  while IFS= read -r raw; do
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
      *_) ALLOW_PREFIX+=("$line") ;;
      *)  ALLOW_EXACT+=("$line") ;;
    esac
  done < "$ALLOWLIST"
fi

is_allowed() {
  local token="$1"
  local k
  for k in "${ALLOW_EXACT[@]+"${ALLOW_EXACT[@]}"}"; do
    [ "$token" = "$k" ] && return 0
  done
  for k in "${ALLOW_PREFIX[@]+"${ALLOW_PREFIX[@]}"}"; do
    case "$token" in
      "$k"*) return 0 ;;
    esac
  done
  return 1
}

# --- Diff -----------------------------------------------------------------
ORPHANS=()
UNDOCUMENTED=()

# ORPHAN = declared \ referenced
while IFS= read -r token; do
  [ -z "$token" ] && continue
  if ! printf '%s\n' "$REFERENCED" | grep -qxF "$token"; then
    is_allowed "$token" || ORPHANS+=("$token")
  fi
done <<<"$DECLARED"

# UNDOCUMENTED = referenced \ declared
while IFS= read -r token; do
  [ -z "$token" ] && continue
  if ! printf '%s\n' "$DECLARED" | grep -qxF "$token"; then
    is_allowed "$token" || UNDOCUMENTED+=("$token")
  fi
done <<<"$REFERENCED"

# --- Report ---------------------------------------------------------------
n_orphan="${#ORPHANS[@]}"
n_undoc="${#UNDOCUMENTED[@]}"

if [ "$n_orphan" -eq 0 ] && [ "$n_undoc" -eq 0 ]; then
  echo "check-config-drift: ok"
  exit 0
fi

{
  if [ "$n_orphan" -gt 0 ]; then
    echo "ORPHAN (declared, unreferenced):"
    for t in "${ORPHANS[@]}"; do echo "  $t"; done
    echo ""
  fi
  if [ "$n_undoc" -gt 0 ]; then
    echo "UNDOCUMENTED (referenced, undeclared):"
    for t in "${UNDOCUMENTED[@]}"; do echo "  $t"; done
    echo ""
  fi
  echo "check-config-drift: $n_orphan orphan(s) / $n_undoc undocumented(s) — see allowlist ${ALLOWLIST#$REPO_ROOT/} to suppress."
} >&2

exit 1
