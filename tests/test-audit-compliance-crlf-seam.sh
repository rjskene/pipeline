#!/bin/bash
set -uo pipefail

# Issue #1158 — CRLF-jq seam over audit-compliance.sh.
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. The two
# raw file-path reads — `echo "$FILES_BODY" | jq -r '.[]'` (L109) and the inner
# `echo "$cfiles" | jq -r '.[]'` (L127, fed the per-commit `jq -c '.[].files'`
# array from L131) — hand `scripts/foo.sh\r` to `_is_source_file`, whose
# end-anchored SRC_EXT_RE (L62, `\.(sh|py|...)$`) then MISSES because the CR sits
# after the extension. SRC_COUNT collapses to 0, the source-change indices go to
# -1, and the TDD verdict flips from PATH-B test-first PASS to
# "N/A (no source changes)" → Aggregate is no longer Compliant.
#
# Model: tests/test-audit-compliance-path-b-test-then-source.sh (same fixtures:
# files ["tests/test-foo.sh","scripts/foo.sh"], test-first commits, empty labels).
# A fake jq earlier on PATH reproduces the msvcrt CR faithfully on an LF-only host.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/audit-compliance.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$SCRIPT" ]; then
  fail_msg "script exists at scripts/audit-compliance.sh"
  echo "PASS=$PASS FAIL=$FAIL"
  exit 1
fi

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SCRIPT_DIR/_lib/crlf-jq-seam.sh"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

FILES_JSON="$TMPDIR/files.json"
COMMITS_JSON="$TMPDIR/commits.json"
LABELS_JSON="$TMPDIR/labels.json"

cat > "$FILES_JSON" <<'EOF'
["tests/test-foo.sh", "scripts/foo.sh"]
EOF
cat > "$COMMITS_JSON" <<'EOF'
[
  {"oid":"aaa111","files":["tests/test-foo.sh"]},
  {"oid":"bbb222","files":["scripts/foo.sh"]}
]
EOF
cat > "$LABELS_JSON" <<'EOF'
[]
EOF

if make_crlf_jq_bin "$TMPDIR/bin"; then
  OUT="$(PATH="$TMPDIR/bin:$PATH" bash "$SCRIPT" 999 999 --dry-run \
    --files-json "$FILES_JSON" \
    --commits-json "$COMMITS_JSON" \
    --labels-json "$LABELS_JSON" 2>&1)"

  if echo "$OUT" | grep -qF "| TDD   | yes (PATH B) | test committed before/with source (test-first) | PASS |"; then
    pass_msg "CRLF-seam: PATH B PASS TDD row survives Windows CRLF jq"
  else
    fail_msg "CRLF-seam: PATH B PASS TDD row missing (SRC_COUNT zeroed by CR on jq -r file paths)"
    echo "$OUT" | sed 's/^/    /'
  fi

  if echo "$OUT" | grep -qF "Aggregate: Compliant"; then
    pass_msg "CRLF-seam: Aggregate: Compliant"
  else
    fail_msg "CRLF-seam: Aggregate is not Compliant under CRLF jq"
  fi

  if ! printf '%s' "$OUT" | grep -q $'\r'; then
    pass_msg "CRLF-seam: no stray CR in audit output"
  else
    fail_msg "CRLF-seam: audit output carries a stray CR under CRLF jq"
  fi
else
  fail_msg "CRLF-seam: fake-jq seam setup failed (non-vacuity guard)"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
