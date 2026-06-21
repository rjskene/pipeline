#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# PIPELINE_CI_FIX_LOOP_ENABLED stays DOCUMENTED. #1052 (defaults-in-code) is the
# doc-vs-code reconciliation the #762/#858 KEEP comment anticipated: the knob is now
# COMMENTED in the example (its "true" default is single-sourced at the colon-less
# ${VAR-true} read site), so accept the commented form — only assert it stays documented.
grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_CI_FIX_LOOP_ENABLED=' pipeline.config.example || { echo "missing PIPELINE_CI_FIX_LOOP_ENABLED"; exit 1; }
# RETRY_BUDGET and LOG_LINES were demoted to commented escape-hatches per
# #857/#762 (defaults single-sourced at ${VAR:=2} / ${VAR:=200} read sites);
# accept the commented form, asserting only that the knob stays documented.
grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_CI_FIX_RETRY_BUDGET=' pipeline.config.example || { echo "missing PIPELINE_CI_FIX_RETRY_BUDGET"; exit 1; }
grep -qE '^[[:space:]]*#?[[:space:]]*PIPELINE_CI_FIX_LOG_LINES='    pipeline.config.example || { echo "missing PIPELINE_CI_FIX_LOG_LINES"; exit 1; }
echo "ok"
