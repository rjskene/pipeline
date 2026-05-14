#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
grep -q '^PIPELINE_CI_FIX_LOOP_ENABLED=' pipeline.config.example || { echo "missing PIPELINE_CI_FIX_LOOP_ENABLED"; exit 1; }
grep -q '^PIPELINE_CI_FIX_RETRY_BUDGET=' pipeline.config.example || { echo "missing PIPELINE_CI_FIX_RETRY_BUDGET"; exit 1; }
grep -q '^PIPELINE_CI_FIX_LOG_LINES='    pipeline.config.example || { echo "missing PIPELINE_CI_FIX_LOG_LINES"; exit 1; }
echo "ok"
