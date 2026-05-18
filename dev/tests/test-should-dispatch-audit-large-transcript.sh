#!/usr/bin/env bash
# Regression test for #265: should-dispatch-audit.sh must not exit 141
# (SIGPIPE under `set -o pipefail`) when scanning a large transcript.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
HELPER="$REPO/dev/self-audit/should-dispatch-audit.sh"

PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

OUT="$TMP/audits"; mkdir -p "$OUT"
PROJ="$TMP/projects/repo-hash"; mkdir -p "$PROJ"

# Seed index with an older timestamp so the mtime-newer branch is taken.
printf '{"timestamp":"2026-05-17T12:00:00Z","digest":"inner-x.md","merged_prs":0}\n' > "$OUT/index.jsonl"

# Build a large synthetic transcript that comfortably exceeds the Linux
# pipe buffer (~64 KB). 200k sessionId-bearing lines (~10–15 MB total)
# guarantees `head -1` will close the pipe before `grep` finishes writing.
BIG="$PROJ/big.jsonl"
python3 -c '
import sys
f = open(sys.argv[1], "w")
for i in range(200000):
    f.write("{\"type\":\"user\",\"uuid\":\"u" + str(i) + "\",\"sessionId\":\"big-session-xyz\"}\n")
f.close()
' "$BIG"
touch -d '2026-05-17T13:00:00Z' "$BIG"

# Capture stdout, stderr, and exit code separately so a SIGPIPE (141) with
# empty stdout (the bug) is distinguishable from a clean dispatch (the fix).
rc=0
out=$(AUDIT_OUT_DIR="$OUT" AUDIT_CLAUDE_PROJECTS_DIR="$TMP/projects" \
      bash "$HELPER" 2>"$TMP/err") || rc=$?

assert "helper exits 0 (no SIGPIPE 141)" "[ \"\$rc\" = \"0\" ]"
assert "stdout is non-empty"             "[ -n \"\$out\" ]"
assert "dispatch line names the big transcript and its sessionId" \
  "echo \"\$out\" | grep -qE '^dispatch:.*big\\.jsonl:big-session-xyz\$'"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
