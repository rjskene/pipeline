#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/release-please-config.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "config file exists" "[ -f '$CFG' ]"
assert "extra-files contains marketplace-dev.json metadata.version" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; ef=c[\"extra-files\"]; paths={(e[\"path\"], e[\"jsonpath\"]) for e in ef if isinstance(e, dict)}; sys.exit(0 if (\".claude-plugin/marketplace-dev.json\",\"\$.metadata.version\") in paths else 1)' 2>/dev/null"
assert "extra-files contains marketplace-dev.json plugins[0].version" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; ef=c[\"extra-files\"]; paths={(e[\"path\"], e[\"jsonpath\"]) for e in ef if isinstance(e, dict)}; sys.exit(0 if (\".claude-plugin/marketplace-dev.json\",\"\$.plugins[0].version\") in paths else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
