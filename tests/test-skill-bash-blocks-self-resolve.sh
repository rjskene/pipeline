#!/bin/bash
set -uo pipefail

# Contract test (refs #339): every consumer-facing SKILL.md that invokes a
# plugin-shipped script via `bash ${CLAUDE_PLUGIN_ROOT}/...` or
# `python3 ${CLAUDE_PLUGIN_ROOT}/...` inside ANY fenced ```bash``` block MUST
# self-resolve CLAUDE_PLUGIN_ROOT in its ## Boot block (first 30 lines).
#
# Rationale: CLAUDE_PLUGIN_ROOT lives only for the Bash tool's subshell; each
# subsequent Bash tool call is a fresh subshell with no inherited env. The
# orchestrator's boot-block source therefore does NOT propagate. Without an
# in-skill resolver, `bash ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh` collapses to
# `bash /scripts/foo.sh` (empty var) or `bash ./scripts/foo.sh` (the consumer
# project's empty `./scripts/`), 404'ing the plugin helper.
#
# This is a stronger/forward-looking sibling of test-skills-source-resolver.sh:
# - test-skills-source-resolver.sh enforces "every consumer-facing skill sources
#   the resolver in first 30 lines" — line-positional invariant.
# - this test enforces "if you invoke a plugin script via ${CLAUDE_PLUGIN_ROOT}
#   anywhere in the body, the Boot resolver MUST be present" — usage-anchored
#   invariant. Catches the regression class where a skill adds a new plugin
#   script invocation but forgets to also add the Boot resolver.
#
# Skills with no ${CLAUDE_PLUGIN_ROOT}-using bash blocks are exempt from this
# stricter check (defense-in-depth is still encouraged via the line-positional
# test, but not required here).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

SKILLS=(
  "skills/status/SKILL.md"
  "skills/run/SKILL.md"
  "skills/fullsend/SKILL.md"
  "skills/create-issues/SKILL.md"
  "skills/execute-issue-plan/SKILL.md"
  "skills/evaluate-issue-pr/SKILL.md"
  "skills/plan-issue/SKILL.md"
  "skills/classify-issue/SKILL.md"
  "skills/evaluate-issue-plan/SKILL.md"
  "skills/doctor/SKILL.md"
)

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Walk fenced ```bash``` blocks. Within each block, check whether any line
# contains both ${CLAUDE_PLUGIN_ROOT} (literal, since it's a template var ref)
# AND an invocation verb (`bash ` or `python3 `). If so, assert the file's
# first 30 lines source _resolve-plugin-root.sh.
skill_invokes_plugin_script() {
  local file="$1"
  # Match indented fences too: SKILL.md numbered-list items embed ```bash blocks
  # under their list indent. A column-0-only match would silently exempt those.
  awk '
    /^[[:space:]]*```bash[[:space:]]*$/ { in_block = 1; next }
    /^[[:space:]]*```[[:space:]]*$/     { in_block = 0; next }
    in_block && /\$\{CLAUDE_PLUGIN_ROOT(:-[^}]*)?\}/ && /(bash |python3 )/ { found = 1; exit }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

for rel in "${SKILLS[@]}"; do
  F="$REPO_ROOT/$rel"
  if [ ! -f "$F" ]; then
    fail_msg "$rel: file not found"
    continue
  fi
  if skill_invokes_plugin_script "$F"; then
    if head -n 30 "$F" | grep -qE 'source [^ ]*_resolve-plugin-root\.sh'; then
      pass_msg "$rel uses \${CLAUDE_PLUGIN_ROOT} and sources resolver in Boot"
    else
      fail_msg "$rel uses \${CLAUDE_PLUGIN_ROOT} in a bash block but does NOT source resolver in first 30 lines"
    fi
  else
    pass_msg "$rel does not invoke plugin scripts via \${CLAUDE_PLUGIN_ROOT} (exempt)"
  fi
done

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
