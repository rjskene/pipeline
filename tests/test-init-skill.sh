#!/bin/bash
# Contract tests for skills/init/SKILL.md — the /pipeline:init command doc.
# Asserts frontmatter, Boot section, and the scripts/init.sh invocation. Does
# NOT duplicate test-skill-boot-section.sh / test-plugin-skill-discoverability.sh
# (those run repo-wide); this file pins the init-specific shape.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/init/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SKILL" ]; then
  echo "FAIL: $SKILL does not exist"
  exit 1
fi

# Frontmatter: name: init (exact, matches the discoverability regex).
grep -qE '^name:[[:space:]]*init$' "$SKILL" \
  && pass_msg "frontmatter has 'name: init'" \
  || fail_msg "frontmatter missing 'name: init'"

# description carries the Usage hint.
grep -qE '^description:.*Usage: /pipeline:init' "$SKILL" \
  && pass_msg "description includes 'Usage: /pipeline:init'" \
  || fail_msg "description missing 'Usage: /pipeline:init'"

# allowed-tools includes Bash.
grep -qE '^allowed-tools:.*Bash' "$SKILL" \
  && pass_msg "allowed-tools includes Bash" \
  || fail_msg "allowed-tools missing Bash"

# Boot section present, and its body references both source and pipeline.config
# (this is what test-skill-boot-section.sh enforces repo-wide; pinned here too).
grep -qE '^## Boot' "$SKILL" \
  && pass_msg "has '## Boot' heading" \
  || fail_msg "missing '## Boot' heading"

boot_body="$(awk '/^## Boot/{flag=1; next} flag && /^## /{flag=0} flag' "$SKILL")"
printf '%s' "$boot_body" | grep -q 'source' \
  && pass_msg "Boot body references 'source'" \
  || fail_msg "Boot body missing 'source'"
printf '%s' "$boot_body" | grep -q 'pipeline.config' \
  && pass_msg "Boot body references 'pipeline.config'" \
  || fail_msg "Boot body missing 'pipeline.config'"

# Invokes the backing script via the plugin root.
grep -qE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/init\.sh' "$SKILL" \
  && pass_msg "invokes \${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" \
  || fail_msg "does not invoke \${CLAUDE_PLUGIN_ROOT}/scripts/init.sh"

# No leftover ${PIPELINE_*} envsubst placeholders.
if grep -nE '\$\{PIPELINE_[A-Z0-9_]+\}' "$SKILL" >/dev/null; then
  fail_msg "has leftover \${PIPELINE_*} placeholder(s)"
else
  pass_msg "no \${PIPELINE_*} placeholders"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
