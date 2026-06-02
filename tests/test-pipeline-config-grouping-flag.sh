#!/bin/bash
set -uo pipefail
#
# Tests that the PIPELINE_GROUPING_DETECTION_ENABLED opt-out flag introduced
# by issue #62 is declared in pipeline.config.example and documented as a
# disable knob in skills/create-issues/SKILL.md.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLE="$REPO_ROOT/pipeline.config.example"
SKILL="$REPO_ROOT/skills/create-issues/SKILL.md"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# (1) pipeline.config.example documents PIPELINE_GROUPING_DETECTION_ENABLED as a
# discoverable escape-hatch. Per #857/#762 this knob was demoted from a live line
# to a commented escape-hatch (default "true" single-sourced in skill prose), so
# accept the commented form. It must still appear by name.
if grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_GROUPING_DETECTION_ENABLED=' "$EXAMPLE"; then
  pass_msg "pipeline.config.example documents PIPELINE_GROUPING_DETECTION_ENABLED"
else
  fail_msg "pipeline.config.example documents PIPELINE_GROUPING_DETECTION_ENABLED"
fi

# (2) The escape-hatch carries the "true" default value (commented OR live).
if grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_GROUPING_DETECTION_ENABLED="?true"?' "$EXAMPLE"; then
  pass_msg "pipeline.config.example defaults PIPELINE_GROUPING_DETECTION_ENABLED to true"
else
  fail_msg "pipeline.config.example defaults PIPELINE_GROUPING_DETECTION_ENABLED to true"
fi

# (3) SKILL.md documents the disable instruction.
if grep -q 'PIPELINE_GROUPING_DETECTION_ENABLED=false' "$SKILL"; then
  pass_msg "SKILL.md documents PIPELINE_GROUPING_DETECTION_ENABLED=false as a disable knob"
else
  fail_msg "SKILL.md documents PIPELINE_GROUPING_DETECTION_ENABLED=false as a disable knob"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
