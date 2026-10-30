#!/bin/bash
set -euo pipefail

# Asserts the #1616 registration contract — the gated log and cost-capture
# hooks ship in the published plugin manifest, and the dogfood
# .claude/settings.json no longer registers them (no double-firing under the
# local-marketplace install, which loads the manifest):
#   (a) .claude-plugin/plugin.json `hooks.PostToolUse` has:
#         - exactly one matcher="*" command `bash ${CLAUDE_PLUGIN_ROOT}/hooks/log-tool-use.sh`
#         - exactly one matcher="Agent" entry carrying both
#           `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/log_subagent.py` and
#           `python3 ${CLAUDE_PLUGIN_ROOT}/hooks/capture_agent_cost.py`
#   (b) manifest `hooks.Stop` carries capture_agent_cost.py in an entry that
#       does NOT also carry enforce-ci-wait.py (strip_guard_hooks keeps any Stop
#       entry with a command lacking enforce-ci-wait.py, so a combined entry
#       would leave enforce-ci-wait.py live under --hooks off), and the
#       enforce-ci-wait.py Stop entry still exists.
#   (c) .claude/settings.json registers none of log-tool-use.sh /
#       log_subagent.py / capture_agent_cost.py under any event.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
SETTINGS="$REPO_ROOT/.claude/settings.json"

python3 - "$MANIFEST" "$SETTINGS" <<'PY'
import json, sys

manifest_path, settings_path = sys.argv[1], sys.argv[2]

PASS = 0
FAIL = 0
def check(name, ok):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS: {name}")
    else:
        FAIL += 1
        print(f"  FAIL: {name}")

with open(manifest_path) as f:
    manifest = json.load(f)
mhooks = manifest.get("hooks", {})
post = mhooks.get("PostToolUse", [])
stop = mhooks.get("Stop", [])

TOOL = "bash ${CLAUDE_PLUGIN_ROOT}/hooks/log-tool-use.sh"
SUB = "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/log_subagent.py"
COST = "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/capture_agent_cost.py"

def cmds(entry):
    return [h.get("command", "") for h in entry.get("hooks", [])]

star = [e for e in post if e.get("matcher") == "*"]
check(
    'manifest PostToolUse has exactly one matcher="*" log-tool-use.sh command',
    sum(cmds(e).count(TOOL) for e in star) == 1,
)
agent = [e for e in post if e.get("matcher") == "Agent"]
check(
    'manifest PostToolUse has exactly one matcher="Agent" entry carrying log_subagent.py + capture_agent_cost.py',
    len([e for e in agent if SUB in cmds(e) and COST in cmds(e)]) == 1,
)

cost_stop = [e for e in stop if any("capture_agent_cost.py" in c for c in cmds(e))]
check("manifest Stop carries a capture_agent_cost.py command", bool(cost_stop))
check(
    "manifest Stop capture_agent_cost.py entry does NOT also carry enforce-ci-wait.py",
    bool(cost_stop) and all(not any("enforce-ci-wait.py" in c for c in cmds(e)) for e in cost_stop),
)
check(
    "manifest Stop still has the enforce-ci-wait.py entry",
    any(any("enforce-ci-wait.py" in c for c in cmds(e)) for e in stop),
)

with open(settings_path) as f:
    settings = json.load(f)
moved = ("log-tool-use.sh", "log_subagent.py", "capture_agent_cost.py")
stray = [
    (event, c)
    for event, entries in settings.get("hooks", {}).items()
    for e in entries
    for c in cmds(e)
    if any(m in c for m in moved)
]
check(
    f".claude/settings.json registers none of {', '.join(moved)} (got {stray!r})",
    not stray,
)

print(f"RESULT: {PASS} passed, {FAIL} failed")
sys.exit(0 if FAIL == 0 else 1)
PY
