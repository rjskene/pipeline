#!/bin/bash
# Sealed unit tests for scripts/rewrite-eval-screenshot-urls.sh (issue #506).
#
# Contract: after auto-merge, rewrite branch-pinned raw.githubusercontent.com
# screenshot URLs in the latest `## Evaluation` comment to merge-SHA-pinned
# URLs so the evidence is durable for the life of the commit (supersedes the
# Option A ephemeral-404 behaviour from tracker #383).
#
# Cases:
#   (a) URL with feature-branch component is rewritten to the merge-SHA
#   (b) URL on a non-PR branch (external doc link) is left untouched (no-op)
#   (c) comment without any screenshot URLs is a no-op (no PATCH call)
#   (d) PATCH failure exits 0 with a stderr warning (fail-soft)
#   (e) multiple feature-branch URLs all rewritten; non-PR URL preserved
#   (f) re-running on an already-rewritten comment is a no-op (idempotent)
#   (g) PIPELINE_SCREENSHOT_REWRITE_ENABLED=false short-circuits (no PATCH)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/rewrite-eval-screenshot-urls.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- gh shim -------------------------------------------------------------
# Emits fixtures from env vars; records the PATCH body so the test can assert
# what the helper sent. GH_PATCH_FAIL=1 makes the `gh api PATCH` call fail.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
echo "gh $ALL_ARGS" >> "${CALL_LOG:-/dev/null}"
case "$ALL_ARGS" in
  *"pr view"*"--json headRefName"*)
    printf '%s\n' "${GH_HEAD_REF:-feature/foo}"
    ;;
  *"pr view"*"--json comments"*)
    printf '%s' "${GH_COMMENTS_JSON:-}"
    ;;
  *"api"*"PATCH"*)
    # Capture the -f body=<...> argument verbatim.
    for a in "$@"; do
      case "$a" in
        body=*) printf '%s' "${a#body=}" > "${PATCH_BODY_FILE:-/dev/null}" ;;
      esac
    done
    if [ "${GH_PATCH_FAIL:-0}" = "1" ]; then
      echo "gh: PATCH failed (simulated)" >&2
      exit 1
    fi
    printf '{"ok":true}\n'
    ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="test/repo"

FAILED=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }

CALL_LOG="$TMP/calls.log"
PATCH_BODY_FILE="$TMP/patch-body.txt"
export CALL_LOG PATCH_BODY_FILE

reset_state() {
  : > "$CALL_LOG"
  rm -f "$PATCH_BODY_FILE"
  unset GH_PATCH_FAIL
  export PIPELINE_SCREENSHOT_REWRITE_ENABLED=true
}

# Build a comments payload from one or more comment bodies.
make_comments() {
  # Each arg is a comment body; assigns sequential issuecomment ids.
  local n=100 first=1 json='{"comments":['
  for body in "$@"; do
    [ "$first" -eq 1 ] || json+=','
    first=0
    local enc; enc=$(printf '%s' "$body" | jq -Rs .)
    json+=$(printf '{"body":%s,"url":"https://github.com/test/repo/pull/5#issuecomment-%d"}' "$enc" "$n")
    n=$((n+1))
  done
  json+=']}'
  printf '%s' "$json"
}

patched()     { grep -q 'PATCH' "$CALL_LOG"; }
patch_body()  { cat "$PATCH_BODY_FILE" 2>/dev/null; }

URL_BRANCH="https://raw.githubusercontent.com/test/repo/feature/foo/.eval-screenshots"
URL_SHA="https://raw.githubusercontent.com/test/repo/abc123sha/.eval-screenshots"
URL_MAIN="https://raw.githubusercontent.com/test/repo/main/.eval-screenshots/architecture.png"

echo "=== (a) feature-branch URL rewritten to merge-SHA ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

**Verdict:** Approved

**Screenshots:**
- ![shot](${URL_BRANCH}/shot.png)")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patched; then pass "(a) PATCH was called"; else fail "(a) PATCH was called"; fi
if patch_body | grep -qF "${URL_SHA}/shot.png"; then pass "(a) body uses merge-SHA URL"; else fail "(a) body uses merge-SHA URL"; fi
if patch_body | grep -qF "${URL_BRANCH}/shot.png"; then fail "(a) body still has branch URL"; else pass "(a) branch URL removed"; fi

echo "=== (b) non-PR-branch URL left untouched (no-op) ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

**Verdict:** Approved

See ![doc](${URL_MAIN})")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patched; then fail "(b) must NOT PATCH (no feature-branch URL)"; else pass "(b) no PATCH on non-PR URL"; fi

echo "=== (c) comment without screenshot URLs is a no-op ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

**Verdict:** Approved

**Screenshots:** None")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patched; then fail "(c) must NOT PATCH (no screenshots)"; else pass "(c) no PATCH when no screenshots"; fi

echo "=== (d) PATCH failure exits 0 with stderr warning ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_PATCH_FAIL=1
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

**Verdict:** Approved

- ![shot](${URL_BRANCH}/shot.png)")"
STDERR="$(bash "$HELPER" 5 abc123sha 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "(d) exit 0 on PATCH failure"; else fail "(d) exit 0 on PATCH failure (got $rc)"; fi
if [ -n "$STDERR" ]; then pass "(d) emits stderr warning"; else fail "(d) emits stderr warning"; fi

echo "=== (e) multiple feature-branch URLs rewritten; non-PR URL preserved ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

- ![one](${URL_BRANCH}/one.png)
- ![two](${URL_BRANCH}/two.png)
- ![doc](${URL_MAIN})")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patch_body | grep -qF "${URL_SHA}/one.png"; then pass "(e) first URL rewritten"; else fail "(e) first URL rewritten"; fi
if patch_body | grep -qF "${URL_SHA}/two.png"; then pass "(e) second URL rewritten"; else fail "(e) second URL rewritten"; fi
if patch_body | grep -qF "${URL_MAIN}"; then pass "(e) non-PR URL preserved"; else fail "(e) non-PR URL preserved"; fi

echo "=== (f) already-rewritten comment is a no-op (idempotent) ==="
reset_state
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

- ![shot](${URL_SHA}/shot.png)")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patched; then fail "(f) must NOT PATCH (already SHA-pinned)"; else pass "(f) idempotent no-op"; fi

echo "=== (g) PIPELINE_SCREENSHOT_REWRITE_ENABLED=false short-circuits ==="
reset_state
export PIPELINE_SCREENSHOT_REWRITE_ENABLED=false
export GH_HEAD_REF="feature/foo"
export GH_COMMENTS_JSON="$(make_comments "## Evaluation

- ![shot](${URL_BRANCH}/shot.png)")"
bash "$HELPER" 5 abc123sha 2>/dev/null
if patched; then fail "(g) disabled flag must NOT PATCH"; else pass "(g) opt-out short-circuits"; fi

echo ""
if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
