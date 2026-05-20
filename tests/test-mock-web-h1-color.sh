#!/usr/bin/env bash
set -euo pipefail
CSS="mock-web-eval/target/style.css"
grep -Eq '^[[:space:]]*h1[[:space:]]*\{[^}]*color:[[:space:]]*#1d4ed8[[:space:]]*;?[^}]*\}' "$CSS" \
  || { echo "FAIL: $CSS missing 'h1 { color: #1d4ed8; }' rule"; exit 1; }
echo "PASS: h1 brand-blue rule present in $CSS"
