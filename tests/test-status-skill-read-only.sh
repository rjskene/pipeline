#!/bin/bash
set -uo pipefail
#
# Contract test (issue #763): skills/status/SKILL.md is the renamed, read-only
# successor of the old /pipeline:run skill. It surveys + reports; it must NOT
# dispatch agents, spawn workers, queue runs, or carry merge-orchestration
# wiring — all of that relocated into skills/fullsend/SKILL.md.
#
# Asserts:
#   (a) skills/status/SKILL.md exists
#   (b) frontmatter declares `name: status`
#   (c) the `allowed-tools` line EXCLUDES `Agent`
#   (d) the body carries NO dispatch/transport wiring:
#         - no `Agent(subagent_type=` dispatch
#         - no `spawn-claude` script invocation
#         - no `run-queue` script invocation
#         - no `merge-orchestration` reference

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL="$REPO_ROOT/skills/status/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# (a) File exists.
if [ -f "$SKILL" ]; then
  pass_msg "skills/status/SKILL.md exists"
else
  fail_msg "skills/status/SKILL.md not found at $SKILL"
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

# (b) Frontmatter name: status.
if grep -qE '^name: status[[:space:]]*$' "$SKILL"; then
  pass_msg "frontmatter declares name: status"
else
  fail_msg "frontmatter does not declare 'name: status'"
fi

# (c) allowed-tools excludes Agent.
ALLOWED_LINE=$(grep -E '^allowed-tools:' "$SKILL" | head -1)
if [ -z "$ALLOWED_LINE" ]; then
  fail_msg "no allowed-tools line found"
elif echo "$ALLOWED_LINE" | grep -qE '(^|[[:space:],])Agent([[:space:],]|$)'; then
  fail_msg "allowed-tools must NOT include Agent (line: $ALLOWED_LINE)"
else
  pass_msg "allowed-tools line excludes Agent"
fi

# (d) No dispatch/transport wiring in the body.
if grep -qF 'Agent(subagent_type=' "$SKILL"; then
  fail_msg "body still dispatches via Agent(subagent_type= (read-only skill must not dispatch)"
else
  pass_msg "body has no Agent(subagent_type= dispatch"
fi

# spawn-claude must not be INVOKED as a script (a descriptive prose mention of
# the label-reading helper is fine; an actual `bash ...spawn-claude.sh` call is
# not). Anchor on the invocation form, not the bare word.
if grep -qE 'bash [^|]*spawn-claude\.sh|run-queue\.sh --[^ ]*spawn|spawn-claude\.sh [0-9]' "$SKILL"; then
  fail_msg "body still invokes spawn-claude.sh (transport relocated to fullsend)"
else
  pass_msg "body has no spawn-claude.sh invocation"
fi

if grep -qE 'run-queue\.sh' "$SKILL"; then
  fail_msg "body still references run-queue.sh (transport relocated to fullsend)"
else
  pass_msg "body has no run-queue.sh reference"
fi

if grep -qF 'merge-orchestration' "$SKILL"; then
  fail_msg "body still references merge-orchestration (relocated to fullsend)"
else
  pass_msg "body has no merge-orchestration reference"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
