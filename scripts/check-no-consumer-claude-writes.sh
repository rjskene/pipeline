#!/bin/bash
# check-no-consumer-claude-writes — source-tree lint that enforces the plugin
# boundary: nothing in pipeline source should reference the consumer-project
# install-style namespaces (skills, scripts, hooks, agents subdirs, plus the
# settings file). Exit 0 on clean, 1 on violation. See
# tests/no-consumer-claude-writes.allow for the (shrinking) legacy exemptions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW_FILE="$REPO_ROOT/tests/no-consumer-claude-writes.allow"
FORBIDDEN_RE='\.claude/(skills|scripts|hooks|agents)/|\.claude/settings\.json'

# Load allow-list into an associative array. Strip `# ...` comments and skip
# blank lines. Keys are repo-relative paths (whole-file exemption).
declare -A ALLOW
if [ -f "$ALLOW_FILE" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    ALLOW["$line"]=1
  done < "$ALLOW_FILE"
fi

cd "$REPO_ROOT"

# Build the file list:
#   1) Everything under scripts/, hooks/, agents/, .claude-plugin/ (install-style
#      source artifacts). Generated Python bytecode (hooks/__pycache__/*.pyc) is
#      EXCLUDED — it is compiled output, not source, and its binary content
#      embeds the forbidden control-file path literals from the compiled hook,
#      which would false-positive the scan. Python materializes these `.pyc`
#      files whenever a hook is imported at runtime, so they appear in any live
#      worktree even though they are gitignored.
#   2) Any *.template at repo root or up to depth 3, excluding tests/, docs/,
#      .claude/, .git/, and node_modules/ (description, not installation).
FILES=$(
  {
    find scripts hooks agents .claude-plugin -type f \
      -not -path '*/__pycache__/*' -not -name '*.pyc' 2>/dev/null || true
    find . -maxdepth 3 -name '*.template' \
      -not -path './.claude/*' \
      -not -path './tests/*' \
      -not -path './docs/*' \
      -not -path './.git/*' \
      -not -path './node_modules/*' 2>/dev/null || true
  } | sed 's|^\./||' | sort -u
)

violations=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -n "${ALLOW[$f]:-}" ] && continue
  [ -f "$f" ] || continue
  if matches=$(grep -nE "$FORBIDDEN_RE" "$f" 2>/dev/null); then
    while IFS= read -r m; do
      violations+="VIOLATION: $f:$m"$'\n'
    done <<< "$matches"
  fi
done <<< "$FILES"

if [ -n "$violations" ]; then
  printf '%s' "$violations" >&2
  exit 1
fi

echo "check-no-consumer-claude-writes: ok"
exit 0
