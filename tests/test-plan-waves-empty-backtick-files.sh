#!/bin/bash
set -euo pipefail

# Regression guard for issue #730 — pipefail must not kill wave computation when
# a plan comment's `**Files to change:**` block has NO backtick-wrapped paths.
#
# scripts/plan-waves.sh runs `set -euo pipefail`. The execute-stage path
# extracts plan-comment file paths via `... | grep -oE '`[^`]+`' | ...` inside a
# `PLAN_FILES=$(...)` command substitution. When the `**Files to change:**`
# bullets contain ZERO backtick-wrapped paths (e.g. prose bullets), the `grep`
# matches nothing and exits 1; pipefail propagates it and `set -e` aborts the
# whole script — the wave plan and --emit-edges map both come back empty.
#
# This guard runs the wave computation over a fixture plan whose
# `**Files to change:**` block has zero backtick paths and asserts the script
# exits 0 with a coherent `Wave N:` line.
#
# gh-shim harness mirrors tests/test-plan-waves-emit-edges.sh and
# tests/test-plan-waves-unified-graph.sh: `gh` replaced by a PATH-resident shim
# reading canned JSON from $GH_ISSUE_DIR/<N>.json (and <N>.comments.json).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/plan-waves.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "  (helper does not exist yet at $HELPER — every case will FAIL by design until implementation)"
fi

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
# Args look like: issue view 42 --repo owner/repo --json number,title,body,labels
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  n="$3"
  for a in "$@"; do
    if [ "$a" = "comments" ]; then
      f="$GH_ISSUE_DIR/$n.comments.json"
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
      echo '{"comments":[]}'; exit 0
    fi
  done
  f="$GH_ISSUE_DIR/$n.json"
  if [ -f "$f" ]; then
    cat "$f"
    exit 0
  fi
  echo "shim: no canned JSON for issue $n" >&2
  exit 1
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

# Helper: write a canned issue JSON. Args: dir, number, labels-json, body
write_issue() {
  local dir="$1" num="$2" labels="$3" body="$4"
  jq -n \
    --arg num "$num" \
    --arg body "$body" \
    --argjson labels "$labels" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: $labels}' \
    > "$dir/$num.json"
}

# Helper: write a canned comments JSON carrying a single plan comment body.
write_plan_comment() {
  local dir="$1" num="$2" plan_body="$3"
  jq -n --arg body "$plan_body" \
    '{comments: [{body: $body}]}' \
    > "$dir/$num.comments.json"
}

run_helper() {
  bash "$HELPER" "$@"
}

# ---- Slate: a single P2 issue whose approved plan comment has a
# `**Files to change:**` block with ZERO backtick-wrapped paths (prose bullets).
S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
write_issue "$S" 1 '[{"name":"priority/P2"}]' \
  "An issue whose plan describes files in prose, not backticks."
write_plan_comment "$S" 1 "## Implementation Plan

**Files to change:**
- the wave planner script (no backticks here)
- a new regression test under the tests directory

**Tasks (ordered):**
- do the thing
"

# ---- Case 1: helper exits 0 and emits a coherent Wave line (no pipefail abort).
echo "Case 1: empty-backtick **Files to change:** block does not kill the script"
inc
if OUT=$(run_helper --stage=execute 1 2>"$S/stderr1"); then
  if echo "$OUT" | grep -qE '^Wave 1: execute #1'; then
    pass_msg "Case 1: helper exited 0 with a coherent Wave line"
  else
    fail_msg "Case 1: helper exited 0 but emitted no coherent Wave line"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc (pipefail killed the script on empty grep)"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr1"
fi

# ---- Case 2: --emit-edges also survives and emits an EDGE line for the issue.
echo "Case 2: --emit-edges survives empty-backtick plan and emits an EDGE line"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2>"$S/stderr2"); then
  if echo "$OUT" | grep -qE '^EDGE #1 '; then
    pass_msg "Case 2: --emit-edges emitted an EDGE line (no empty map)"
  else
    fail_msg "Case 2: --emit-edges emitted no EDGE line"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc on --emit-edges"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr2"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
