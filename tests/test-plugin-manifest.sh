#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert "manifest file exists" "[ -f '$MANIFEST' ]"
assert "manifest is valid JSON" "python3 -c 'import json; json.load(open(\"$MANIFEST\"))' 2>/dev/null"
assert "name is 'pipeline'" "[ \"\$(python3 -c 'import json; print(json.load(open(\"$MANIFEST\")).get(\"name\",\"\"))' 2>/dev/null)\" = pipeline ]"
assert "version is set" "python3 -c 'import json,sys; v=json.load(open(\"$MANIFEST\")).get(\"version\"); sys.exit(0 if v else 1)' 2>/dev/null"
assert "description is set" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"$MANIFEST\")).get(\"description\") else 1)' 2>/dev/null"
assert "superpowers is a declared dependency" "python3 -c 'import json,sys; d=json.load(open(\"$MANIFEST\")).get(\"dependencies\",[]); names=[x if isinstance(x,str) else x.get(\"name\") for x in d]; sys.exit(0 if \"superpowers\" in names else 1)' 2>/dev/null"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
