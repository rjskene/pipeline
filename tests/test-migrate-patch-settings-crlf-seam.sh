#!/bin/bash
set -uo pipefail

# Issue #1158 — CRLF-jq seam over migrate-from-subtree.sh --patch settings.
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. The
# residual-hook read `jq -r '.hooks // {} | ... | .command // empty'` (L562)
# hands `bash .claude/hooks/log-tool-use.sh\r` to the classify loop, so
# `_ps_bn` becomes `log-tool-use.sh\r`. The exact-line `grep -Fxq "$_ps_bn"`
# against the CR-free list_pipeline_hook_basenames allow-list MISSES,
# `_ps_removed_tmp` stays empty, `_ps_n=0`, and --patch settings prints
# "nothing to remove … no pipeline hook entries" and exits 0 WITHOUT stripping
# the residual hook — a silent, incomplete migration of the documented legacy
# subtree entrypoint.
#
# Model: tests/test-migrate-patch-settings.sh (patch-settings-mixed). A fake jq
# earlier on PATH reproduces the msvcrt CR faithfully on an LF-only host.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$MIGRATE_SH" ]; then
  echo "ERROR: migrate-from-subtree.sh not found at $MIGRATE_SH" >&2
  exit 1
fi

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SCRIPT_DIR/_lib/crlf-jq-seam.sh"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if ! make_crlf_jq_bin "$WORKDIR/bin"; then
  fail_msg "CRLF-seam: fake-jq seam setup failed (non-vacuity guard)"
  echo "  $PASS passed, $FAIL failed"
  exit 1
fi

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/.claude"
SETTINGS="$PROJ/.claude/$(printf 'settings').json"
cat > "$SETTINGS" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [
        {"type": "command", "command": "bash .claude/hooks/log-tool-use.sh"},
        {"type": "command", "command": "./my/consumer-hook.sh"}
      ]}
    ]
  }
}
EOF

(cd "$PROJ" && PATH="$WORKDIR/bin:$PATH" bash "$MIGRATE_SH" --patch settings --assume-yes \
   >"$WORKDIR/out" 2>"$WORKDIR/err")
EXIT=$?
OUT="$(cat "$WORKDIR/out")"

# (a1) --patch settings must NOT short-circuit to the empty "nothing to remove"
# path when a real pipeline hook is present (_ps_n>0 must be taken).
if printf '%s' "$OUT" | grep -qE '(nothing to remove|no pipeline hook)'; then
  fail_msg "CRLF-seam: --patch settings wrongly reported 'nothing to remove' under CRLF jq (exit=$EXIT)"
else
  pass_msg "CRLF-seam: --patch settings did NOT bail to 'nothing to remove'"
fi

# (a2) the residual pipeline hook must actually be stripped from settings.json;
# the consumer-owned hook must survive.
if ! grep -q 'log-tool-use\.sh' "$SETTINGS"; then
  pass_msg "CRLF-seam: residual pipeline hook removed from settings.json"
else
  fail_msg "CRLF-seam: residual pipeline hook still present after --patch settings (silent skip)"
fi
if grep -q 'consumer-hook\.sh' "$SETTINGS"; then
  pass_msg "CRLF-seam: consumer-owned hook preserved"
else
  fail_msg "CRLF-seam: consumer-owned hook lost"
fi

# (b) no stray CR in the emitted diagnostics / removal diff.
if ! printf '%s' "$OUT" | grep -q $'\r'; then
  pass_msg "CRLF-seam: no stray CR in --patch settings stdout"
else
  fail_msg "CRLF-seam: --patch settings stdout carries a stray CR under CRLF jq"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
