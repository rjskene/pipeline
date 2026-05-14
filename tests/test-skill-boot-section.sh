#!/bin/bash
set -euo pipefail

# Asserts that every rendered .claude/skills/*/SKILL.md:
#  (1) has a `## Boot` heading whose body references both `source` and
#      `pipeline.config` (so the agent knows to source the project config
#      at session start), and
#  (2) contains no leftover literal `${PIPELINE_*}` envsubst placeholders
#      (plugin-rendered SKILL.md must work without install-time substitution).

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_ROOT="$REPO_ROOT/.claude/skills"

[ -d "$SKILL_ROOT" ] || { echo "FAIL: $SKILL_ROOT missing"; exit 1; }

SKILLS=$(find "$SKILL_ROOT" -maxdepth 2 -name SKILL.md | sort)
[ -n "$SKILLS" ] || { echo "FAIL: no SKILL.md files found under $SKILL_ROOT"; exit 1; }

PASS=0
FAIL=0
FAIL_LINES=()

for skill_md in $SKILLS; do
  rel="${skill_md#$REPO_ROOT/}"

  if grep -q '^## Boot' "$skill_md"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: $rel missing '## Boot' heading")
    continue
  fi

  body=$(awk '/^## Boot/{flag=1; next} flag && /^## /{flag=0} flag' "$skill_md")

  if printf '%s' "$body" | grep -q 'source'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: $rel Boot body must reference 'source'")
  fi

  if printf '%s' "$body" | grep -q 'pipeline.config'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: $rel Boot body must reference 'pipeline.config'")
  fi

  if grep -nE '\$\{PIPELINE_[A-Z0-9_]+\}' "$skill_md" >/dev/null; then
    leftover=$(grep -nE '\$\{PIPELINE_[A-Z0-9_]+\}' "$skill_md" | head -3 | tr '\n' '|')
    FAIL=$((FAIL + 1))
    FAIL_LINES+=("FAIL: $rel still has \${PIPELINE_*} placeholder(s): $leftover")
  else
    PASS=$((PASS + 1))
  fi
done

if [ "$FAIL" -gt 0 ]; then
  printf '%s\n' "${FAIL_LINES[@]}"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

echo "RESULT: $PASS passed, $FAIL failed"
