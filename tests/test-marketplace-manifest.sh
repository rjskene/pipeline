#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
PLUGIN="$REPO_ROOT/.claude-plugin/plugin.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "marketplace file exists" "[ -f '$MARKETPLACE' ]"
assert "marketplace is valid JSON" "python3 -c 'import json; json.load(open(\"$MARKETPLACE\"))' 2>/dev/null"
assert "marketplace.name is 'claude-pipeline'" "[ \"\$(python3 -c 'import json; print(json.load(open(\"$MARKETPLACE\")).get(\"name\",\"\"))' 2>/dev/null)\" = claude-pipeline ]"
assert "marketplace.owner is an object with name" "python3 -c 'import json,sys; o=json.load(open(\"$MARKETPLACE\")).get(\"owner\"); sys.exit(0 if isinstance(o,dict) and o.get(\"name\") else 1)' 2>/dev/null"
assert "marketplace.plugins is a non-empty array" "python3 -c 'import json,sys; p=json.load(open(\"$MARKETPLACE\")).get(\"plugins\"); sys.exit(0 if isinstance(p,list) and p else 1)' 2>/dev/null"
assert "plugins[0].name matches plugin.json name" "python3 -c 'import json,sys; mp=json.load(open(\"$MARKETPLACE\")); pj=json.load(open(\"$PLUGIN\")); sys.exit(0 if mp[\"plugins\"][0].get(\"name\")==pj.get(\"name\") else 1)' 2>/dev/null"
assert "plugins[0].source is set" "python3 -c 'import json,sys; s=json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"source\"); sys.exit(0 if s else 1)' 2>/dev/null"
assert "plugins[0].description is set" "python3 -c 'import json,sys; d=json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"description\"); sys.exit(0 if d else 1)' 2>/dev/null"
assert "plugins[0].version matches plugin.json version" "python3 -c 'import json,sys; mp=json.load(open(\"$MARKETPLACE\")); pj=json.load(open(\"$PLUGIN\")); sys.exit(0 if mp[\"plugins\"][0].get(\"version\")==pj.get(\"version\") else 1)' 2>/dev/null"
assert "plugins[0].homepage references this repo" "python3 -c 'import json,sys; h=json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"homepage\",\"\"); sys.exit(0 if \"HTS-COLLAB-ORG/claude-pipeline\" in h else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
