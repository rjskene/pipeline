#!/bin/bash
set -euo pipefail
# AGENTS.md is the Codex-side entry document. Unlike the superpowers precedent
# (which symlinks AGENTS.md -> CLAUDE.md), pipeline's is a REGULAR FILE: CLAUDE.md
# carries CC-only assertions, so the Codex wrapper adds a Codex preamble (tool-map
# pointer, multi_agent note, hook-trust note) and then LINKS CLAUDE.md.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$REPO_ROOT/AGENTS.md"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

assert "AGENTS.md exists" "[ -e '$AGENTS' ]"
# Must be a REGULAR FILE and explicitly NOT a symlink (diverges from superpowers).
assert "AGENTS.md is a regular file" "[ -f '$AGENTS' ]"
assert "AGENTS.md is NOT a symlink" "[ ! -L '$AGENTS' ]"
# Links CLAUDE.md (the canonical pipeline doc).
assert "AGENTS.md references CLAUDE.md" "grep -q 'CLAUDE.md' '$AGENTS'"
# Codex preamble markers.
assert "preamble mentions multi_agent" "grep -q 'multi_agent' '$AGENTS'"
assert "preamble points at codex-tools (forward-ref to Leg 5)" "grep -q 'codex-tools' '$AGENTS'"
assert "preamble carries a hook-trust note" "grep -qi 'hook.*trust\\|trust.*hook' '$AGENTS'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
