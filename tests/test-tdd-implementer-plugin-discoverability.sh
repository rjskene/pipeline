#!/bin/bash
set -euo pipefail
# Verifies the tdd-implementer subagent is discoverable via the plugin's
# `agents/` directory ALONE — without a project-local `.claude/agents/`
# rendering. Also verifies the enforce-path-c-delegation hook still
# recognises tdd-implementer dispatches regardless of agent source.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
HOOK_TEMPLATE="$REPO_ROOT/hooks/enforce-path-c-delegation.py.template"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# 1. Plugin source-of-truth: agent file exists at plugin root
assert "agents/tdd-implementer.md exists at plugin root" "[ -f '$REPO_ROOT/agents/tdd-implementer.md' ]"

# 2. Manifest references it explicitly (proxy for plugin-loader discoverability) — RED gate
assert "plugin.json agents[] references tdd-implementer file" \
  "python3 -c 'import json,os,sys; m=json.load(open(\"$MANIFEST\")); a=m.get(\"agents\",[]); sys.exit(0 if any(os.path.basename(p)==\"tdd-implementer.md\" for p in a) else 1)' 2>/dev/null"

# 3. Sandbox simulation: spin up a temp dir with NO .claude/agents/, copy in
# only the plugin manifest + agents/ subtree, and prove the agent file is
# reachable from the plugin root using ONLY paths the plugin loader scans.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/plugin/.claude-plugin" "$SANDBOX/plugin/agents"
cp "$MANIFEST" "$SANDBOX/plugin/.claude-plugin/plugin.json"
cp "$REPO_ROOT/agents/tdd-implementer.md" "$SANDBOX/plugin/agents/tdd-implementer.md"
mkdir -p "$SANDBOX/project"   # consumer project — deliberately NO .claude/agents/
assert "sandbox project has NO .claude/agents/tdd-implementer.md" \
  "[ ! -f '$SANDBOX/project/.claude/agents/tdd-implementer.md' ]"
assert "sandbox plugin agent file resolves via manifest path" \
  "python3 -c 'import json,os,sys; m=json.load(open(\"$SANDBOX/plugin/.claude-plugin/plugin.json\")); a=m.get(\"agents\",[]); sys.exit(1) if not a else sys.exit(0 if os.path.isfile(os.path.normpath(os.path.join(\"$SANDBOX/plugin\",a[0]))) else 1)' 2>/dev/null"
assert "sandbox agent frontmatter has name: tdd-implementer" \
  "grep -qE '^name:[[:space:]]*tdd-implementer\$' '$SANDBOX/plugin/agents/tdd-implementer.md'"

# 4. enforce-path-c-delegation hook still keys off subagent_type string for tdd-implementer
# (matches whether the predicate is `==` or `!=` — both forms reference the agent name)
assert "hook references subagent_type tdd-implementer predicate" \
  "grep -qE 'subagent_type.*tdd-implementer' '$HOOK_TEMPLATE'"
# Pin the exact intact predicate line so a refactor that flips the negation
# (e.g. removes the `!=` guard) is caught even if the substring still matches.
assert "hook predicate intact: subagent_type != tdd-implementer guard present" \
  "grep -qF 'data.get(\"subagent_type\") != \"tdd-implementer\"' '$HOOK_TEMPLATE'"
assert "hook still parses target=<dir> sentinel (delegation logic intact)" \
  "grep -q 'target=' '$HOOK_TEMPLATE'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
