#!/usr/bin/env bash
set -euo pipefail

# Assert mock-web-eval has a Clear button in the echo section that clears
# both the input and the output. Predicate-shaped grep test for issue #525.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HTML="$ROOT/mock-web-eval/target/index.html"
JS="$ROOT/mock-web-eval/target/app.js"

if ! grep -qF 'id="echo-clear"' "$HTML"; then
  echo "FAIL: mock-web-eval/target/index.html does not contain 'id=\"echo-clear\"'" >&2
  exit 1
fi

if ! grep -qF "getElementById('echo-clear')" "$JS"; then
  echo "FAIL: mock-web-eval/target/app.js does not contain a getElementById('echo-clear') handler" >&2
  exit 1
fi

if ! grep -qE "echo-input.*value\s*=\s*''" "$JS" \
   && ! grep -qE "input\.value\s*=\s*''" "$JS"; then
  echo "FAIL: mock-web-eval/target/app.js does not clear #echo-input value" >&2
  exit 1
fi

if ! grep -qE "echo-output.*textContent\s*=\s*''" "$JS" \
   && ! grep -qE "output\.textContent\s*=\s*''" "$JS"; then
  echo "FAIL: mock-web-eval/target/app.js does not clear #echo-output textContent" >&2
  exit 1
fi

echo "PASS: mock-web-eval echo Clear button is present and wired to reset input/output"
