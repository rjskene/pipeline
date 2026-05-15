#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace-dev.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "marketplace-dev file exists" "[ -f '$MARKETPLACE' ]"
assert "marketplace-dev is valid JSON" "python3 -c 'import json; json.load(open(\"$MARKETPLACE\"))' 2>/dev/null"
assert "name is 'claude-pipeline-dev'" "[ \"\$(python3 -c 'import json; print(json.load(open(\"$MARKETPLACE\")).get(\"name\",\"\"))' 2>/dev/null)\" = claude-pipeline-dev ]"
assert "owner is an object with name" "python3 -c 'import json,sys; o=json.load(open(\"$MARKETPLACE\")).get(\"owner\"); sys.exit(0 if isinstance(o,dict) and o.get(\"name\") else 1)' 2>/dev/null"
assert "plugins[0].name == 'pipeline'" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"name\")==\"pipeline\" else 1)' 2>/dev/null"
assert "plugins[0].source == './'" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"source\")==\"./\" else 1)' 2>/dev/null"
assert "plugins[0].homepage references this repo" "python3 -c 'import json,sys; h=json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0].get(\"homepage\",\"\"); sys.exit(0 if \"HTS-COLLAB-ORG/claude-pipeline\" in h else 1)' 2>/dev/null"
assert "metadata.version matches SemVer (with optional prerelease)" "python3 -c 'import json,sys,re; v=json.load(open(\"$MARKETPLACE\"))[\"metadata\"][\"version\"]; sys.exit(0 if re.match(r\"^\\d+\\.\\d+\\.\\d+(-[A-Za-z0-9.-]+)?\$\", v) else 1)' 2>/dev/null"
assert "plugins[0].version matches SemVer (with optional prerelease)" "python3 -c 'import json,sys,re; v=json.load(open(\"$MARKETPLACE\"))[\"plugins\"][0][\"version\"]; sys.exit(0 if re.match(r\"^\\d+\\.\\d+\\.\\d+(-[A-Za-z0-9.-]+)?\$\", v) else 1)' 2>/dev/null"
assert "metadata.version == plugins[0].version" "python3 -c 'import json,sys; m=json.load(open(\"$MARKETPLACE\")); sys.exit(0 if m[\"metadata\"][\"version\"]==m[\"plugins\"][0][\"version\"] else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
