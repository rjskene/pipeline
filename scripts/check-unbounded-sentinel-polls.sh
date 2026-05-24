#!/bin/bash
set -euo pipefail

# check-unbounded-sentinel-polls.sh [SKILL_DIR]
#
# Static lint: scan SKILL.md files for the unbounded sentinel-poll shape that
# wedges an executor session forever when the awaited token never appears:
#
#   until   grep ... ; do sleep N ; done
#   while ! grep ... ; do sleep N ; done
#
# (single-line, or spread across the opener + next lines). The sanctioned
# replacement is scripts/wait-for-sentinel.sh, which bounds the wait.
#
# Whitelisted (not flagged): the opener is wrapped in a `timeout ...` call, or
# the line references scripts/wait-for-sentinel.sh (pedagogical example). Other
# bounded shapes (`for i in {1..N}; do ...; break; done`) don't match the
# opener regex and so pass naturally.
#
# Exit 0 when clean, 1 (printing each offending file:line) on violation.
# SKILL_DIR defaults to <repo-root>/skills.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="${1:-$REPO_ROOT/skills}"

if [ ! -d "$SKILL_DIR" ]; then
  echo "check-unbounded-sentinel-polls: scan dir not found: $SKILL_DIR" >&2
  exit 2
fi

# Opener: a line beginning (ignoring leading whitespace / fences) with
# `until grep` or `while ! grep`.
OPENER_RE='(^|[[:space:]])(until|while[[:space:]]+!)[[:space:]]+grep'

violations=0

while IFS= read -r skill; do
  total_lines=$(wc -l <"$skill")
  while IFS=: read -r lineno content; do
    [ -n "${lineno:-}" ] || continue

    # Whitelist: an explicit helper reference (pedagogical example).
    case "$content" in
      *wait-for-sentinel.sh*) continue ;;
    esac

    # Whitelist: the opener is wrapped in a `timeout` command. Require a
    # `timeout` command to appear BEFORE the until/while keyword — a bare
    # "timeout" in a trailing comment or inside the grep search-text must NOT
    # excuse the wedge. We isolate the prefix up to the opener keyword and look
    # for a `timeout ` command token there.
    prefix=$(printf '%s' "$content" | sed -E 's/(^|[[:space:]])(until|while[[:space:]]+!).*$//')
    if printf '%s' "$prefix" | grep -qE '(^|[[:space:]]|[|;&])timeout[[:space:]]'; then
      continue
    fi

    # Build a small window (opener + next 3 lines) to catch multi-line bodies.
    end=$((lineno + 3))
    [ "$end" -gt "$total_lines" ] && end=$total_lines
    window=$(sed -n "${lineno},${end}p" "$skill")

    # The wedge shape is a busy-wait: a loop body that sleeps, closed by done.
    if printf '%s' "$window" | grep -q 'sleep' \
       && printf '%s' "$window" | grep -q 'done'; then
      echo "$skill:$lineno: unbounded sentinel poll (use scripts/wait-for-sentinel.sh)" >&2
      violations=$((violations + 1))
    fi
  done < <(grep -nE "$OPENER_RE" "$skill" || true)
done < <(find "$SKILL_DIR" -name 'SKILL.md' -type f | sort)

if [ "$violations" -gt 0 ]; then
  echo "check-unbounded-sentinel-polls: $violations unbounded sentinel poll(s) found" >&2
  exit 1
fi
exit 0
