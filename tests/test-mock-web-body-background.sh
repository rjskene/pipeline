#!/usr/bin/env bash
set -euo pipefail
CSS="mock-web-eval/target/style.css"
grep -Eq '^[[:space:]]*body[[:space:]]*\{[[:space:]]*background:[[:space:]]*#fef3c7[[:space:]]*;?[[:space:]]*\}' "$CSS" \
  || { echo "FAIL: $CSS missing 'body { background: #fef3c7; }' rule"; exit 1; }
echo "PASS: body soft-yellow background rule present in $CSS"
