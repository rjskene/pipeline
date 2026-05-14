#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAN="$REPO_ROOT/.release-please-manifest.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "manifest file exists" "[ -f '$MAN' ]"
assert "manifest is valid JSON" "python3 -c 'import json; json.load(open(\"$MAN\"))' 2>/dev/null"
assert "manifest has \".\" key" "python3 -c 'import json,sys; m=json.load(open(\"$MAN\")); sys.exit(0 if \".\" in m else 1)' 2>/dev/null"
assert "manifest \".\" version matches plugin.json version" "python3 -c 'import json,sys,re; m=json.load(open(\"$MAN\")); p=json.load(open(\"$REPO_ROOT/.claude-plugin/plugin.json\")); v=m[\".\"]; sys.exit(0 if v==p[\"version\"] and re.match(r\"^\\d+\\.\\d+\\.\\d+\$\", v) else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
