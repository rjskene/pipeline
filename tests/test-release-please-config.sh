#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/release-please-config.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "config file exists" "[ -f '$CFG' ]"
assert "config is valid JSON" "python3 -c 'import json; json.load(open(\"$CFG\"))' 2>/dev/null"
assert "config declares packages.\".\"" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); sys.exit(0 if \".\" in c.get(\"packages\",{}) else 1)' 2>/dev/null"
assert "packages.\".\" has release-type" "python3 -c 'import json,sys; p=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if p.get(\"release-type\") else 1)' 2>/dev/null"
assert "extra-files bumps plugin.json (jsonpath \$.version)" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/plugin.json\" and e.get(\"jsonpath\") in (\"\$.version\",\"\$[\\\"version\\\"]\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "extra-files bumps marketplace.json metadata.version" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and \"metadata\" in (e.get(\"jsonpath\") or \"\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "extra-files bumps marketplace.json plugins[0].version" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and \"plugins\" in (e.get(\"jsonpath\") or \"\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"

# rc.N-within-minor cadence (#524): feat: must resolve to a patch update pre-1.0 so the prerelease
# strategy iterates -rc.N instead of forcing a minor bump that resets to -rc.1. This requires
# bump-patch-for-minor-pre-major: true while keeping bump-minor-pre-major: true (the latter gates
# only breaking changes). Guards against both the v0.18.0-rc.1 incident and the wrong-knob revision.
assert "bump-patch-for-minor-pre-major is true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); sys.exit(0 if c.get(\"bump-patch-for-minor-pre-major\") is True else 1)' 2>/dev/null"
assert "bump-minor-pre-major is true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); sys.exit(0 if c.get(\"bump-minor-pre-major\") is True else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
