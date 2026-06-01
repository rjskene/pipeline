#!/bin/bash
set -euo pipefail

# Regression guard for issue #811 — plan-waves.sh --emit-edges body-detection
# must not capture backtick-wrapped PROSE as file paths.
#
# Root cause: the body-detection fallback (no plan comment) extracts
# backtick-wrapped spans and filters with `grep -E '/|\.(ext)$'`. The `/`
# branch matches ANY span containing a slash, so prose like
#   `git mv skills/`  or  `move it to .claude/skills/ next`
# passes the filter. The span is then whitespace-split, and fragments such as
# `skills/` re-pass the `/` filter and are emitted as fabricated file paths —
# producing false-positive conflict edges and garbled `files=` lists.
#
# The fix tightens the path predicate: a token only counts as a file path when
# it is a single whitespace-free path-shaped token (a `dir/file` shape or an
# anchored known extension). Prose phrases (multi-word, containing spaces) and
# their fragments are rejected.
#
# gh-shim harness mirrors tests/test-plan-waves-emit-edges.sh: `gh` replaced by
# a PATH-resident shim reading canned JSON from $GH_ISSUE_DIR/<N>.json.

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

# Helper: write a canned issue JSON. Args: dir, number, priority_label, body
write_issue() {
  local dir="$1" num="$2" prio="$3" body="$4"
  local labels='[]'
  if [ -n "$prio" ]; then
    labels=$(printf '[{"name":"%s"}]' "$prio")
  fi
  jq -n \
    --arg num "$num" \
    --arg body "$body" \
    --argjson labels "$labels" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: $labels}' \
    > "$dir/$num.json"
}

run_helper() {
  bash "$HELPER" "$@"
}

# ---- Slate: a single issue whose body backticks SLASHED PROSE (no real path),
# plus one issue with a genuine path so we can confirm real paths still survive.
S="$TMP/slate"; mkdir -p "$S"; export GH_ISSUE_DIR="$S"
# #1: pure prose-with-slash spans — must yield NO files.
write_issue "$S" 1 "priority/P2" \
  'Reorganize per the plan: `git mv skills/` then `put it in .claude/skills/ later` — see notes.'
# #2: a real path token in backticks — must still be detected.
write_issue "$S" 2 "priority/P2" \
  'Edit the real file `subagents/_template/CLAUDE.md` to fix the header.'

# ---- Case 1: prose-with-slash backticks produce NO file tokens (files=-) ----
echo "Case 1: backtick-wrapped slashed PROSE is not captured as a file path"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 2>"$S/stderr1"); then
  E1=$(echo "$OUT" | grep -E '^EDGE #1 ' || true)
  # No prose word/fragment may appear in files=. Specifically, files must be `-`.
  if echo "$E1" | grep -qE '^EDGE #1 blockers=- files=-$'; then
    pass_msg "Case 1: #1 prose yields files=- (no fabricated path tokens)"
  else
    fail_msg "Case 1: #1 captured prose as file paths"
    echo "    e1: [$E1]"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 1: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr1"
fi

# ---- Case 2: a genuine path token in backticks IS still detected ----
echo "Case 2: a real path token in backticks survives the tightened predicate"
inc
if OUT=$(run_helper --stage=execute --emit-edges 1 2 2>"$S/stderr2"); then
  E2=$(echo "$OUT" | grep -E '^EDGE #2 ' || true)
  if [ "$E2" = "EDGE #2 blockers=- files=subagents/_template/CLAUDE.md" ]; then
    pass_msg "Case 2: #2 real path detected unchanged"
  else
    fail_msg "Case 2: #2 real path lost or mangled"
    echo "    e2: [$E2]"
    echo "    stdout:"; echo "$OUT" | sed 's/^/      /'
  fi
else
  rc=$?
  fail_msg "Case 2: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$S/stderr2"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
