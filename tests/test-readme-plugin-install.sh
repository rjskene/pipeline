#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
PASS=0; FAIL=0
assert_in()  { if grep -qF "$2" "$README"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert_out() { if grep -qF "$2" "$README"; then echo "  FAIL: $1"; FAIL=$((FAIL+1)); else echo "  PASS: $1"; PASS=$((PASS+1)); fi; }
assert_in  "marketplace add command present"      "/plugin marketplace add HTS-COLLAB-ORG/claude-pipeline"
assert_in  "plugin install uses plugin@marketplace form" "/plugin install pipeline@claude-pipeline"
assert_out "plugin install does not use bare marketplace name" "/plugin install claude-pipeline"
assert_in  "links migration guide"                "docs/migration-from-subtree.md"
assert_out "no git subtree add"                   "git subtree add"
assert_out "no git submodule add"                 "git submodule add"
assert_out "no bare install.sh invocation"        "bash install.sh"
assert_out "no .claude-pipeline install.sh"       "bash .claude-pipeline/install.sh"
assert_out "no .claude-pipeline pipeline.config copy" "cp .claude-pipeline/pipeline.config.example"
assert_out "no bare pipeline.config copy"         "cp pipeline.config.example pipeline.config"
assert_out "no check-subtree-drift in README"     "check-subtree-drift"
assert_out "no resolve-subtree-drift in README"   "resolve-subtree-drift"
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
