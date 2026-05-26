#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/release-please-config.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "config file exists" "[ -f '$CFG' ]"
assert "config is valid JSON" "python3 -c 'import json; json.load(open(\"$CFG\"))' 2>/dev/null"
assert "packages[\".\"].prerelease is true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if c.get(\"prerelease\") is True else 1)' 2>/dev/null"
assert "packages[\".\"].prerelease-type is \"rc\"" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\"))[\"packages\"][\".\"]; sys.exit(0 if c.get(\"prerelease-type\")==\"rc\" else 1)' 2>/dev/null"
# rc.N cadence config invariant (#524): release-please's version calculator cannot be invoked
# hermetically (it reads the GitHub API, not local git), so assert the config shape that implies
# rc.N accumulation within a minor — prerelease true (rc channel) AND bump-patch-for-minor-pre-major
# true (feats resolve to patch updates the prerelease strategy iterates as -rc.N).
assert "rc-cadence config invariant: prerelease true + bump-patch-for-minor-pre-major true" "python3 -c 'import json,sys; c=json.load(open(\"$CFG\")); p=c[\"packages\"][\".\"]; sys.exit(0 if (p.get(\"prerelease\") is True and c.get(\"bump-patch-for-minor-pre-major\") is True) else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
