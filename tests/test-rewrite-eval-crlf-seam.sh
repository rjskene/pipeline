#!/bin/bash
# Issue #1162 — CRLF-jq seam over rewrite-eval-screenshot-urls.sh.
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. The
# post-merge screenshot-URL rewriter reads
#   URL="$(printf '%s' "$EVAL" | jq -r '.url')"             (L66)
#   COMMENT_ID="${URL##*issuecomment-}"                     (L67)
# and PATCHes /repos/<repo>/issues/comments/<COMMENT_ID>. Under CRLF jq
# URL=".../issuecomment-100\r", so COMMENT_ID="100\r" and the live PATCH goes to
#   /repos/test/repo/issues/comments/100\r
# — a \r-suffixed comment id 404s on a Windows host. Same class as #1158.
#
# This script has no --fixture mode, so (like tests/test-auto-merge-gate-crlf-
# seam.sh) the seam is layered on a gh STUB. The stub answers headRefName +
# comments and, on the PATCH call, records the ENDPOINT positional (the arg
# right after `PATCH`) verbatim to ENDPOINT_FILE. The assertion is scoped to
# that endpoint (the COMMENT_ID comparand) rather than the whole call log,
# because the `-f body=` arg legitimately carries CRs from the out-of-scope
# `.body` read (#1162 fixes only the COMMENT_ID boundary).
#
# Model: tests/test-auto-merge-gate-crlf-seam.sh (gh stub + fake-jq seam) +
# tests/test-rewrite-eval-screenshot-urls.sh (gh shim shape).
#
# EXPECTED (before the fix): PATCH fires but the endpoint carries a \r -> FAILS.
# EXPECTED (after  the fix): L66 gains `| tr -d '\r'`, endpoint is CR-free.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/rewrite-eval-screenshot-urls.sh"
SEAM_LIB="${ROOT}/tests/_lib/crlf-jq-seam.sh"

for f in "$HELPER" "$SEAM_LIB"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: required file missing: $f"
    exit 1
  fi
done

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SEAM_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

CALL_LOG="$TMP/calls.log"
ENDPOINT_FILE="$TMP/endpoint.txt"
export CALL_LOG ENDPOINT_FILE
: > "$CALL_LOG"

# gh stub — resolves the head branch, returns a `## Evaluation` comment whose
# url is issuecomment-100 and whose body carries a branch-pinned raw-host
# screenshot URL, and on PATCH records the endpoint positional verbatim.
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"pr view"*"--json headRefName"*)
    printf 'feature/foo\n'
    ;;
  *"pr view"*"--json comments"*)
    printf '%s' '{"comments":[{"body":"## Evaluation\n\n**Verdict:** Approved\n\n- ![shot](https://raw.githubusercontent.com/test/repo/feature/foo/.eval-screenshots/shot.png)","url":"https://github.com/test/repo/pull/5#issuecomment-100"}]}'
    ;;
  *"api"*"PATCH"*)
    # Record the endpoint positional — the arg immediately after `PATCH`.
    prev=""
    for a in "$@"; do
      [ "$prev" = "PATCH" ] && printf '%s' "$a" > "$ENDPOINT_FILE"
      prev="$a"
    done
    echo "PATCH-called" >> "$CALL_LOG"
    printf '{"ok":true}\n'
    ;;
  *)
    echo "[gh stub] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"

# Layer the fake CRLF jq into the SAME bin dir (resolves real jq now, before we
# prepend $TMP/bin to PATH, then shadows it for the helper run).
if ! make_crlf_jq_bin "$TMP/bin"; then
  echo "FAIL: CRLF-seam fake-jq setup failed (non-vacuity guard)"
  exit 1
fi

FAILED=0

echo "CRLF-seam — rewrite-eval-screenshot-urls COMMENT_ID read under Windows CRLF jq:"

(
  export PATH="$TMP/bin:$PATH"
  export PIPELINE_REPO="test/repo"
  export PIPELINE_SCREENSHOT_REWRITE_ENABLED=true
  bash "$HELPER" 5 abc123sha
) >/dev/null 2>&1

# (a) the rewrite must actually fire — otherwise the endpoint assertion below is
#     vacuous (a no-op PATCH would trivially carry no CR).
if grep -q 'PATCH-called' "$CALL_LOG"; then
  echo "  PASS: rewrite fired (PATCH called)"
else
  echo "  FAIL: rewrite did not fire (no PATCH) — cannot exercise the COMMENT_ID endpoint"
  FAILED=$((FAILED+1))
fi

# (b) THE regression assertion: the comment-id endpoint must be CR-free. Under
#     CRLF jq the unfixed COMMENT_ID="100\r" poisons the PATCH path. Fails NOW;
#     passes once L66 strips the trailing CR.
if [ -f "$ENDPOINT_FILE" ] && LC_ALL=C grep -q $'\r' "$ENDPOINT_FILE"; then
  echo "  FAIL: PATCH endpoint carries a CR: '$(LC_ALL=C tr -d '\n' < "$ENDPOINT_FILE" | cat -v)' — CR-poisoned COMMENT_ID reached the gh comment path"
  FAILED=$((FAILED+1))
else
  echo "  PASS: PATCH endpoint is CR-free (COMMENT_ID survives CRLF jq)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
