#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/release-please-config.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "config file exists" "[ -f '$CFG' ]"
assert "config is valid JSON" "python3 -c 'import json; json.load(open(\"$CFG\"))' 2>/dev/null"

# New contract: RC machinery removed from packages["."]
assert "packages[\".\"].prerelease key is absent" "python3 -c 'import json,sys; p=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if \"prerelease\" not in p else 1)' 2>/dev/null"
assert "packages[\".\"].prerelease-type key is absent" "python3 -c 'import json,sys; p=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if \"prerelease-type\" not in p else 1)' 2>/dev/null"

# Conservative pre-1.0 bump policy MUST remain at top level
assert "bump-minor-pre-major is true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); sys.exit(0 if c.get(\"bump-minor-pre-major\") is True else 1)' 2>/dev/null"
assert "bump-patch-for-minor-pre-major is true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); sys.exit(0 if c.get(\"bump-patch-for-minor-pre-major\") is True else 1)' 2>/dev/null"

# Structural invariants from packages["."]
assert "packages[\".\"].release-type is simple" "python3 -c 'import json,sys; p=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if p.get(\"release-type\")==\"simple\" else 1)' 2>/dev/null"
assert "extra-files bumps plugin.json (\$.version)" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/plugin.json\" and e.get(\"jsonpath\")==\"\$.version\" for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "extra-files bumps marketplace.json metadata.version" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and e.get(\"jsonpath\")==\"\$.metadata.version\" for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "extra-files bumps marketplace.json plugins[0].version" "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and e.get(\"jsonpath\")==\"\$.plugins[0].version\" for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
