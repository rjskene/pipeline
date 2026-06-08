#!/bin/bash
set -euo pipefail
# .codex/config.toml carries a [mcp_servers.playwright] block equivalent to the
# CC .mcp.json playwright server (operators merge it into ~/.codex/config.toml).
# Validate with stdlib tomllib (py3.12) and compare command+args field-by-field
# to .mcp.json so the two configs never drift.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$REPO_ROOT/.codex/config.toml"
MCP="$REPO_ROOT/.mcp.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "codex config.toml exists" "[ -f '$TOML' ]"
assert "config.toml parses with tomllib" "python3 -c 'import tomllib; tomllib.load(open(\"$TOML\",\"rb\"))' 2>/dev/null"
assert ".mcp.json exists" "[ -f '$MCP' ]"

# [mcp_servers.playwright] present with a command.
assert "[mcp_servers.playwright] block present with command" \
  "python3 -c 'import tomllib,sys; t=tomllib.load(open(\"$TOML\",\"rb\")); pw=t.get(\"mcp_servers\",{}).get(\"playwright\"); sys.exit(0 if isinstance(pw,dict) and pw.get(\"command\") else 1)' 2>/dev/null"

# command equals .mcp.json's playwright server (field-by-field, no drift).
# Build the diagnostic message with % formatting and %r so there are no embedded
# quote literals (which break when the program is passed via `python3 -c "$VAR"`).
EQ_PY='
import json,tomllib,sys
toml=tomllib.load(open(sys.argv[1],"rb"))
mcp=json.load(open(sys.argv[2]))
pw_toml=toml.get("mcp_servers",{}).get("playwright",{})
pw_mcp=mcp.get("mcpServers",{}).get("playwright",{})
if pw_toml.get("command")!=pw_mcp.get("command"):
    sys.stderr.write("COMMAND MISMATCH: %r != %r\n" % (pw_toml.get("command"), pw_mcp.get("command"))); sys.exit(1)
if list(pw_toml.get("args",[]))!=list(pw_mcp.get("args",[])):
    sys.stderr.write("ARGS MISMATCH: %r != %r\n" % (pw_toml.get("args"), pw_mcp.get("args"))); sys.exit(1)
sys.exit(0)
'
assert "playwright command matches .mcp.json" \
  "python3 -c \"\$EQ_PY\" '$TOML' '$MCP' 2>/dev/null"

# Belt-and-suspenders: args list non-empty and equal (the EQ_PY check above covers
# equality; this guards against an empty-vs-empty false pass if .mcp.json ever drops args).
assert "playwright args is a non-empty list matching .mcp.json" \
  "python3 -c 'import tomllib,json,sys; t=tomllib.load(open(\"$TOML\",\"rb\")); m=json.load(open(\"$MCP\")); a=t.get(\"mcp_servers\",{}).get(\"playwright\",{}).get(\"args\",[]); b=m.get(\"mcpServers\",{}).get(\"playwright\",{}).get(\"args\",[]); sys.exit(0 if a and list(a)==list(b) else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
