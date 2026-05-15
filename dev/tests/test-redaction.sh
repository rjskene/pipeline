#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/dev/self-audit/redact.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Hard-deny: 40-char hex token (matches [A-Za-z0-9]{32,})
out=$(printf '%s\n' "leak: 0123456789abcdef0123456789abcdef01234567" | redact)
assert "drops 40-char hex token line" "[ -z \"\$out\" ]"

# Hard-deny: password keyword
out=$(printf '%s\n' "config: password=hunter2 was set" | redact)
assert "drops 'password=' line" "[ -z \"\$out\" ]"

# Hard-deny: API key keyword
out=$(printf '%s\n' "api_key: foo" | redact)
assert "drops 'api_key:' line" "[ -z \"\$out\" ]"

# Hard-deny: bearer keyword
out=$(printf '%s\n' "Authorization: Bearer abc" | redact)
assert "drops Authorization Bearer line" "[ -z \"\$out\" ]"

# Hard-deny: URL with ?token=
out=$(printf '%s\n' "see https://example.com/x?token=xyz" | redact)
assert "drops URL ?token= line" "[ -z \"\$out\" ]"

# Hard-deny: URL with ?key=
out=$(printf '%s\n' "see https://example.com/x?key=xyz" | redact)
assert "drops URL ?key= line" "[ -z \"\$out\" ]"

# Length cap: prose longer than 200 chars gets truncated with marker.
# Use space-separated short words so the line is benign prose (no 32+
# contiguous alphanumerics that would trip the token hard-deny).
long=$(printf 'word %.0s' {1..60})
long_len=${#long}
out=$(printf '%s\n' "$long" | redact)
assert "long line truncated to <=200 + marker" "echo \"\$out\" | grep -q \"\\.\\.\\.\\[truncated; original \$long_len chars\\]\""
assert "truncated line body <=200 chars before marker" "[ \"\$(echo \"\$out\" | sed 's/\\.\\.\\.\\[truncated.*//' | wc -c)\" -le 201 ]"

# Triple-backtick code-block contents are stripped (only surrounding prose survives)
out=$(printf '%s\n' \
  "before code" \
  '```' \
  "secret_in_block: leak_me" \
  '```' \
  "after code" | redact)
assert "before-code prose passes through" "echo \"\$out\" | grep -q 'before code'"
assert "after-code prose passes through"  "echo \"\$out\" | grep -q 'after code'"
assert "code-block contents stripped"     "! echo \"\$out\" | grep -q 'secret_in_block'"
assert "triple-backticks themselves stripped" "! echo \"\$out\" | grep -q '\`\`\`'"

# Allowed pass-through: plain prose, commit msg, issue number, file path
out=$(printf '%s\n' "fix(scope): see #134 at path/to/file.sh per @rjskene" | redact)
assert "allowed prose passes through" "echo \"\$out\" | grep -q 'fix(scope): see #134'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
