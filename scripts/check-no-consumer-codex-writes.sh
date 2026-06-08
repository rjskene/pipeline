#!/bin/bash
# check-no-consumer-codex-writes — source-tree lint that enforces the plugin
# boundary on the Codex harness: nothing in pipeline source should reference the
# consumer's per-user Codex namespace (the hooks/prompts/agents subdirs and the
# user config TOML under ~/.codex, plus the $CODEX_HOME equivalents). The Codex
# twin of check-no-consumer-claude-writes.sh.
#
# Unlike Claude Code's consumer-PROJECT .claude/{skills,hooks,...} surface,
# Codex's per-user surface is ~/.codex/ / $CODEX_HOME. The repo-local .codex/
# (the committed manifest bundle — Leg 2/3) is the pipeline's OWN artifact and
# is therefore NOT forbidden, exactly as the CC lint scans scripts//hooks/ but
# exempts the plugin's own .claude-plugin/.
#
# Exit 0 on clean, 1 on violation. See tests/no-consumer-codex-writes.allow for
# the documented exemptions (each carries a justification comment).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW_FILE="$REPO_ROOT/tests/no-consumer-codex-writes.allow"
# Match consumer Codex namespaces. Two alternations:
#   1. ~/.codex/ (optionally with a leading $HOME-relative ~/ or bare .codex/)
#      followed by a per-user subdir (hooks|prompts|agents) OR the user config
#      file (config.toml) OR the hook-discovery manifest (hooks.json).
#   2. $CODEX_HOME / ${CODEX_HOME} expansion followed by the same subdirs.
# repo-local .codex/ is exempted structurally by the FILES scan set (it is never
# included), so a reference to the committed manifest under tests/ or .codex/ is
# not scanned; a reference under scripts/hooks/agents IS (those are install-style
# source). The leading boundary class keeps `mycodex/...`-style substrings clear.
FORBIDDEN_RE='(^|[^A-Za-z0-9_./])~?/?\.codex/(hooks|prompts|agents)/|\.codex/config\.toml|\.codex/hooks\.json|\$\{?CODEX_HOME\}?/(hooks|prompts|agents)/'

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
#   1) Everything under scripts/, hooks/, agents/, .codex-plugin/ (install-style
#      source artifacts). .codex-plugin/ may be absent until Leg 3 lands —
#      `find ... 2>/dev/null || true` tolerates it.
#   2) Any *.template at repo root or up to depth 3, excluding tests/, docs/,
#      .codex/, .claude/, .git/, and node_modules/ (description, not installation).
FILES=$(
  {
    find scripts hooks agents .codex-plugin -type f 2>/dev/null || true
    find . -maxdepth 3 -name '*.template' \
      -not -path './.codex/*' \
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

echo "check-no-consumer-codex-writes: ok"
exit 0
