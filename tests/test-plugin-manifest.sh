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
# Soft dependency on superpowers — documented in CLAUDE.md, NOT a manifest dep.
# A hard dep here causes install failures when superpowers is installed from a
# different marketplace (e.g., superpowers@claude-plugins-official). Pipeline
# skills check at call-site and fall back to inline behavior if absent.
assert "manifest does NOT declare hard 'dependencies' (soft dep only)" "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); d=m.get(\"dependencies\"); sys.exit(0 if (d is None or d==[] or d=={}) else 1)' 2>/dev/null"
assert "manifest declares an 'agents' field (array)" "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); a=m.get(\"agents\"); sys.exit(0 if isinstance(a,list) and a else 1)' 2>/dev/null"
assert "agents[0] points at an existing file under plugin root" "python3 -c 'import json,os,sys; m=json.load(open(\"$MANIFEST\")); p=m.get(\"agents\",[None])[0]; sys.exit(0 if p and os.path.isfile(os.path.join(\"$REPO_ROOT\",p)) else 1)' 2>/dev/null"
assert "referenced agent file has name: tdd-implementer" "python3 -c 'import json,os,sys,re; m=json.load(open(\"$MANIFEST\")); p=m.get(\"agents\",[None])[0]; t=open(os.path.join(\"$REPO_ROOT\",p)).read() if p else \"\"; sys.exit(0 if re.search(r\"(?m)^name:\\s*tdd-implementer\\s*\$\", t) else 1)' 2>/dev/null"
assert "hooks is an object" "python3 -c 'import json,sys; h=json.load(open(\"$MANIFEST\")).get(\"hooks\"); sys.exit(0 if isinstance(h,dict) else 1)' 2>/dev/null"
assert "hooks.PreToolUse is a non-empty array" "python3 -c 'import json,sys; h=json.load(open(\"$MANIFEST\")).get(\"hooks\",{}).get(\"PreToolUse\"); sys.exit(0 if isinstance(h,list) and h else 1)' 2>/dev/null"
assert "hooks.PostToolUse is absent (consumer install ships no log-* hooks)" "python3 -c 'import json,sys; h=json.load(open(\"$MANIFEST\")).get(\"hooks\",{}); sys.exit(0 if \"PostToolUse\" not in h else 1)' 2>/dev/null"
# Skills are auto-discovered from ${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md;
# the manifest must NOT enumerate them (presence of a top-level `skills` field
# would indicate explicit registration — wrong path).
assert "manifest does NOT declare a top-level 'skills' field (auto-discovery)" "python3 -c 'import json,sys; m=json.load(open(\"$MANIFEST\")); sys.exit(0 if \"skills\" not in m else 1)' 2>/dev/null"
assert "skills/ directory exists at plugin root" "[ -d '$REPO_ROOT/skills' ]"
assert "skills/ contains at least one SKILL.md (auto-discovery surface non-empty)" "[ -n \"\$(find '$REPO_ROOT/skills' -maxdepth 2 -name SKILL.md -print -quit)\" ]"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
