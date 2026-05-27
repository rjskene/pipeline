#!/bin/bash
set -euo pipefail

# Tests for scripts/filter-trusted-comments.sh — the shared trust-filter helper.
#
# Two modes:
#   1. Subcommand `is-trusted-author <association>` — low-level primitive.
#      Exit 0 when the association is in the trust set {OWNER,MEMBER,COLLABORATOR},
#      nonzero otherwise. Reused by #548 (attachment fetch) and #549 (hook).
#   2. Default `<N>` — wraps a single `gh issue view <N> --json body,comments`
#      call and emits, to stdout, the issue body plus ONLY comments authored by a
#      trusted association. A machine-readable dropped-author audit goes to stderr.
#
# `gh` is replaced by a PATH-resident shim that replays $SHIM_VIEW_JSON for
# `gh issue view <N> --json body,comments`. No live API calls.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/filter-trusted-comments.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

# ---------------------------------------------------------------------------
# Task 1: is-trusted-author primitive (exit-code contract)
# ---------------------------------------------------------------------------
echo "=== is-trusted-author: trusted associations exit 0 ==="
for assoc in OWNER MEMBER COLLABORATOR; do
  inc
  if bash "$HELPER" is-trusted-author "$assoc" >/dev/null 2>&1; then
    pass_msg "$assoc → exit 0 (trusted)"
  else
    fail_msg "$assoc should be trusted (exit 0) but exited nonzero"
  fi
done

echo "=== is-trusted-author: untrusted associations exit nonzero ==="
for assoc in CONTRIBUTOR NONE FIRST_TIME_CONTRIBUTOR FIRST_TIMER "" lowercase_owner UNKNOWN; do
  inc
  if bash "$HELPER" is-trusted-author "$assoc" >/dev/null 2>&1; then
    fail_msg "'$assoc' should be untrusted (nonzero) but exited 0"
  else
    pass_msg "'$assoc' → nonzero (untrusted)"
  fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Ran $TESTS tests: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
