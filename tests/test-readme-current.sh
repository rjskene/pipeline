#!/bin/bash
# Lint README.md against the canonical-entry contract established by #397.
# The README has 7 sections (hero+lifecycle strip, Canonical entry points,
# Install + first run, Project layout, Where to look, Prerequisites) in that
# order. Detailed lifecycle prose, the per-command Usage table, the label
# flow line, and the subtree-migration pointer were deliberately retired by
# the rewrite — their content lives in docs/process-maps.md or skill files.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/README.md"
PASS=0; FAIL=0
assert_in()  { if grep -qF "$2" "$README"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }
assert_out() { if grep -qF "$2" "$README"; then echo "  FAIL: $1"; FAIL=$((FAIL+1)); else echo "  PASS: $1"; PASS=$((PASS+1)); fi; }

# Hero + 5-line lifecycle strip at the top
assert_in "hero title present"                      "# Pipeline"
assert_in "hero tagline present"                    "Harness and orchestrator for GitHub-issue-driven CI workflows"
assert_in "5-line lifecycle strip top-of-page"      "create → classify → plan → eval → execute → eval-pr → merge"
assert_in "single pointer to docs/process-maps.md"  "Full process maps in docs/process-maps.md."

# Canonical-entry section + table
assert_in "Canonical entry points heading"          "## Canonical entry points"
assert_in "entry points table lists /pipeline:run"        "/pipeline:run"
assert_in "entry points table lists /pipeline:fullsend"   "/pipeline:fullsend [N ...]"

# Install + first run section
assert_in "Install + first run heading"             "## Install + first run"
assert_in "marketplace add command present"         "/plugin marketplace add rjskene/pipeline"
assert_in "plugin install plugin@marketplace form"  "/plugin install pipeline@claude-pipeline"
assert_in "validate via /pipeline:doctor"           "/pipeline:doctor"
assert_in "first run command shown"                 "/pipeline:run"

# Project layout section
assert_in "Project layout heading"                  "## Project layout"
assert_in "layout tree shows skills/"               "skills/"
assert_in "layout tree shows agents/"               "agents/"
assert_in "layout tree shows pipeline.config"       "pipeline.config"

# Where to look + Prerequisites
assert_in "Where to look heading"                   "## Where to look"
assert_in "Prerequisites heading"                   "## Prerequisites"
assert_in "prereq gh CLI"                           "gh"
assert_in "prereq jq"                               "jq"
assert_in "prereq bash 4+"                          "bash"

# Retired content (must NOT appear — these were intentionally dropped)
assert_out "no per-command Usage table"             "## Usage"
assert_out "no label-flow one-liner"                "Label flow:"
assert_out "no subtree-migration pointer"           "Migrating from a subtree install"
assert_out "no release-PR section heading"          "Release-PR awareness"
assert_out "no install.sh references"               "install.sh"
assert_out "no bare check-subtree-drift in README"  "check-subtree-drift"

# No anchored cross-references into any doc / SKILL file
if grep -qE '\.md#[A-Za-z0-9_-]+' "$README"; then
  echo "  FAIL: README contains anchored cross-references"; FAIL=$((FAIL+1))
else
  echo "  PASS: README contains no anchored cross-references"; PASS=$((PASS+1))
fi

# Line budget — plan target ≤150 (current rewrite is well under)
LINES=$(wc -l < "$README")
if [ "$LINES" -le 150 ]; then
  echo "  PASS: README ≤150 lines (actual: $LINES)"; PASS=$((PASS+1))
else
  echo "  FAIL: README exceeds 150 lines (actual: $LINES)"; FAIL=$((FAIL+1))
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
