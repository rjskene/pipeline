#!/bin/bash
set -euo pipefail

# Tests for scripts/filter-trusted-comments.sh — the shared trust-filter helper.
#
# Three modes:
#   1. Subcommand `is-trusted-author <association>` — low-level primitive.
#      Exit 0 when the association is in the trust set {OWNER,MEMBER,COLLABORATOR},
#      nonzero otherwise. Reused by #548 (attachment fetch) and #549 (hook).
#   2. Default `<N>` — wraps a single `gh issue view <N> --json body,comments`
#      call and emits, to stdout, the issue body plus ONLY comments authored by a
#      trusted association. A machine-readable dropped-author audit goes to stderr.
#   3. `--json <N>` (#1315) — same single fetch; stdout is a compact
#      `{"comments":[…]}` of ONLY trusted-author comments with the GraphQL field
#      names preserved (the stdin shape scripts/select-plan-comment.sh expects).
#      Same stderr audit as default mode.
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
# Task 2: default mode — filter comments + emit dropped-author audit
# ---------------------------------------------------------------------------
# Stage a PATH-resident `gh` shim that replays $SHIM_VIEW_JSON verbatim for
# `gh issue view <N> --json body,comments`. Any other invocation is an error.
stage_shim() {
  local bin="$ROOT_TMP/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GH'
#!/bin/bash
# Strip flags we don't care about; match on the subcommand.
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  printf '%s' "${SHIM_VIEW_JSON:-}"
  exit 0
fi
echo "shim: unhandled gh invocation: $*" >&2
exit 99
GH
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}
stage_shim
export PIPELINE_REPO="rjskene/pipeline"

# Run the helper in default mode, capturing stdout and stderr to separate files.
OUT_F="$ROOT_TMP/out"; ERR_F="$ROOT_TMP/err"
run_default() {
  : > "$OUT_F"; : > "$ERR_F"
  bash "$HELPER" "$1" >"$OUT_F" 2>"$ERR_F"
}

echo "=== default mode: mixed tier — trusted kept, untrusted bytes dropped ==="
inc
export SHIM_VIEW_JSON='{
  "body": "ISSUE_BODY_MARKER spec from operator",
  "comments": [
    {"body": "TRUSTED_OWNER_BYTES",   "author": {"login": "alice"},   "authorAssociation": "OWNER"},
    {"body": "UNTRUSTED_NONE_BYTES",  "author": {"login": "mallory"}, "authorAssociation": "NONE"},
    {"body": "TRUSTED_MEMBER_BYTES",  "author": {"login": "bob"},     "authorAssociation": "MEMBER"},
    {"body": "UNTRUSTED_CONTRIB_BYTES","author": {"login": "eve"},    "authorAssociation": "CONTRIBUTOR"}
  ]
}'
run_default 999 || true
out=$(cat "$OUT_F"); err=$(cat "$ERR_F")
if   ! grep -q "ISSUE_BODY_MARKER"   <<<"$out"; then fail_msg "issue body missing from stdout"
elif ! grep -q "TRUSTED_OWNER_BYTES" <<<"$out"; then fail_msg "OWNER comment missing from stdout"
elif ! grep -q "TRUSTED_MEMBER_BYTES"<<<"$out"; then fail_msg "MEMBER comment missing from stdout"
elif   grep -q "UNTRUSTED_NONE_BYTES"  <<<"$out"; then fail_msg "NONE comment bytes leaked to stdout"
elif   grep -q "UNTRUSTED_CONTRIB_BYTES"<<<"$out"; then fail_msg "CONTRIBUTOR comment bytes leaked to stdout"
else pass_msg "trusted body+comments kept; untrusted bytes never reach stdout"
fi

echo "=== default mode: dropped-author audit on stderr (count + @logins) ==="
inc
if   ! grep -q "ignored 2" <<<"$err"; then fail_msg "audit count wrong; stderr: $err"
elif ! grep -q "@mallory"  <<<"$err"; then fail_msg "audit missing @mallory; stderr: $err"
elif ! grep -q "@eve"      <<<"$err"; then fail_msg "audit missing @eve; stderr: $err"
else pass_msg "stderr audit lists count + untrusted @logins"
fi

echo "=== default mode: all-trusted → 'ignored 0' audit ==="
inc
export SHIM_VIEW_JSON='{"body":"BODY","comments":[{"body":"X","author":{"login":"alice"},"authorAssociation":"OWNER"}]}'
run_default 1 || true
if grep -q "ignored 0" "$ERR_F"; then pass_msg "all-trusted emits 'ignored 0' audit"
else fail_msg "expected 'ignored 0'; stderr: $(cat "$ERR_F")"; fi

echo "=== default mode: empty comments → body only + 'ignored 0' ==="
inc
export SHIM_VIEW_JSON='{"body":"ONLY_BODY_MARKER","comments":[]}'
run_default 2 || true
if grep -q "ONLY_BODY_MARKER" "$OUT_F" && grep -q "ignored 0" "$ERR_F"; then
  pass_msg "empty-comments emits body + 'ignored 0'"
else
  fail_msg "stdout: $(cat "$OUT_F") | stderr: $(cat "$ERR_F")"
fi

echo "=== default mode: no issue arg → nonzero usage error ==="
inc
if bash "$HELPER" >/dev/null 2>&1; then
  fail_msg "no-arg invocation should fail with usage error"
else
  pass_msg "no-arg → nonzero usage error"
fi

# ---------------------------------------------------------------------------
# Task 3 (#1315): `--json <N>` mode — the same single fetch, but stdout is a
# compact `{"comments":[…]}` document holding ONLY trusted-author comments,
# whole comment objects passed through so the GraphQL field names (`body`,
# `createdAt`, `author.login`, `authorAssociation`) survive for downstream jq
# and for scripts/select-plan-comment.sh (whose stdin contract is exactly that
# shape). Same stderr audit as default mode.
# ---------------------------------------------------------------------------
echo "=== --json mode: drops untrusted authors, keeps GraphQL field names ==="
inc
export SHIM_VIEW_JSON='{
  "body": "ISSUE_BODY_MARKER spec from operator",
  "comments": [
    {"body": "TRUSTED_OWNER_BYTES",   "author": {"login": "alice"},   "authorAssociation": "OWNER",       "createdAt": "2026-01-01T00:00:00Z"},
    {"body": "UNTRUSTED_NONE_BYTES",  "author": {"login": "mallory"}, "authorAssociation": "NONE",        "createdAt": "2026-01-02T00:00:00Z"},
    {"body": "TRUSTED_MEMBER_BYTES",  "author": {"login": "bob"},     "authorAssociation": "MEMBER",      "createdAt": "2026-01-03T00:00:00Z"},
    {"body": "UNTRUSTED_CONTRIB_BYTES","author": {"login": "eve"},    "authorAssociation": "CONTRIBUTOR", "createdAt": "2026-01-04T00:00:00Z"}
  ]
}'
: > "$OUT_F"; : > "$ERR_F"
bash "$HELPER" --json 999 >"$OUT_F" 2>"$ERR_F" || true
out=$(cat "$OUT_F"); err=$(cat "$ERR_F")
if   ! jq -e '(keys == ["comments"]) and (.comments | length == 2)' "$OUT_F" >/dev/null 2>&1; then
  fail_msg "stdout is not a {comments:[2 trusted]} JSON document; got: $out"
elif ! jq -e '[.comments[].authorAssociation] == ["OWNER","MEMBER"]' "$OUT_F" >/dev/null 2>&1; then
  fail_msg "trusted subset wrong or out of order; got: $out"
elif ! jq -e '.comments[0] | (.body == "TRUSTED_OWNER_BYTES") and (.createdAt == "2026-01-01T00:00:00Z") and (.author.login == "alice")' "$OUT_F" >/dev/null 2>&1; then
  fail_msg "GraphQL field names not preserved; got: $out"
elif   grep -q "UNTRUSTED_" <<<"$out"; then
  fail_msg "untrusted comment bytes leaked to --json stdout; got: $out"
elif ! grep -q "ignored 2" <<<"$err"; then
  fail_msg "--json audit count wrong; stderr: $err"
elif ! grep -q "@mallory" <<<"$err" || ! grep -q "@eve" <<<"$err"; then
  fail_msg "--json audit missing dropped @logins; stderr: $err"
else
  pass_msg "--json emits {comments:[trusted only]} with GraphQL keys intact + stderr audit"
fi

echo "=== --json mode: select-plan-comment.sh selects the trusted plan end-to-end ==="
inc
export SHIM_VIEW_JSON='{
  "body": "B",
  "comments": [
    {"body": "## Implementation Plan\n\nTRUSTED-PLAN-BODY", "author": {"login": "alice"},   "authorAssociation": "OWNER", "createdAt": "2026-01-01T00:00:00Z"},
    {"body": "## Implementation Plan\n\nFAKE-PLAN-BODY",    "author": {"login": "mallory"}, "authorAssociation": "NONE",  "createdAt": "2026-01-02T00:00:00Z"}
  ]
}'
sel=$(bash "$HELPER" --json 7 2>/dev/null | bash "$SCRIPT_DIR/../scripts/select-plan-comment.sh" || true)
if grep -q "TRUSTED-PLAN-BODY" <<<"$sel" && ! grep -q "FAKE-PLAN-BODY" <<<"$sel"; then
  pass_msg "--json | select-plan-comment.sh picks the trusted plan (untrusted later plan never wins)"
else
  fail_msg "end-to-end selection wrong; got: $sel"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "Ran $TESTS tests: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ]
