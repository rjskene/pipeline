#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/.codex-plugin/plugin.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "codex manifest file exists" "[ -f '$MANIFEST' ]"
assert "codex manifest is valid JSON" "python3 -c 'import json; json.load(open(\"$MANIFEST\"))' 2>/dev/null"
assert "name is 'pipeline'" "[ \"\$(python3 -c 'import json; print(json.load(open(\"$MANIFEST\")).get(\"name\",\"\"))' 2>/dev/null)\" = pipeline ]"
assert "version is set" "python3 -c 'import json,sys; v=json.load(open(\"$MANIFEST\")).get(\"version\"); sys.exit(0 if v else 1)' 2>/dev/null"
assert "description is set" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"$MANIFEST\")).get(\"description\") else 1)' 2>/dev/null"
assert "author is an object with name" "python3 -c 'import json,sys; a=json.load(open(\"$MANIFEST\")).get(\"author\"); sys.exit(0 if isinstance(a,dict) and a.get(\"name\") else 1)' 2>/dev/null"
# Codex needs the explicit skills pointer — the CC manifest deliberately OMITS it
# (CC auto-discovers skills/<name>/SKILL.md). Load-bearing divergence between the two manifests.
assert "skills field equals './skills/'" "[ \"\$(python3 -c 'import json; print(json.load(open(\"$MANIFEST\")).get(\"skills\",\"\"))' 2>/dev/null)\" = ./skills/ ]"
assert "interface is a non-empty object" "python3 -c 'import json,sys; i=json.load(open(\"$MANIFEST\")).get(\"interface\"); sys.exit(0 if isinstance(i,dict) and i else 1)' 2>/dev/null"
assert "skills/ directory exists at plugin root" "[ -d '$REPO_ROOT/skills' ]"
assert "skills/ contains at least one SKILL.md" "[ -n \"\$(find '$REPO_ROOT/skills' -maxdepth 2 -name SKILL.md -print -quit)\" ]"
# Codex manifest does NOT carry CC-only agents/hooks (Codex has no CC hook engine).
assert "codex manifest does NOT declare 'agents'" "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); sys.exit(0 if \"agents\" not in m else 1)' 2>/dev/null"
assert "codex manifest does NOT declare 'hooks'" "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); sys.exit(0 if \"hooks\" not in m else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
