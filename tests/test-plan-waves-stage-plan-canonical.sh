#!/bin/bash
set -uo pipefail

# #1485 — classify folded into plan-issue. plan-waves.sh: `--stage=plan` is the
# canonical wave verb; `--stage=classify` survives one release as a deprecated
# alias (behavior unchanged). resolve-stage-model.sh: documents (header only)
# that there is NO `classify` stage arm — classification runs inside `plan`.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WAVES="$SCRIPT_DIR/../scripts/plan-waves.sh"
RESOLVER="$SCRIPT_DIR/../scripts/resolve-stage-model.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh shim (same shape as tests/test-plan-waves.sh).
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
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
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo "shim: no canned JSON for issue $n" >&2
  exit 1
fi
echo "shim: unrecognized call: $*" >&2
exit 2
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

write_issue() {
  local dir="$1" num="$2" prio="$3" body="$4"
  jq -n --arg num "$num" --arg body "$body" --arg prio "$prio" \
    '{number: ($num|tonumber), title: ("issue " + $num), body: $body, labels: [{name: $prio}]}' \
    > "$dir/$num.json"
}

F="$TMP/fx"; mkdir -p "$F"; export GH_ISSUE_DIR="$F"
write_issue "$F" 1 "priority/P2" "Touches \`shared/common.sh\` here."
write_issue "$F" 2 "priority/P2" "Also references \`shared/common.sh\` (body mention)."

# 1. Invalid --stage error text: lists plan, marks classify as deprecated alias.
ERR=$(bash "$WAVES" --stage=bogus 1 2>&1 >/dev/null)
if echo "$ERR" | grep -q 'plan|execute' \
   && echo "$ERR" | grep -qiE 'classify[^|]*deprecated alias'; then
  pass_msg "invalid-stage text lists plan|execute and marks classify deprecated alias"
else
  fail_msg "invalid-stage text: $ERR"
fi

# 2. usage(): canonical `[--stage=plan|execute]` + classify deprecation note.
USAGE=$(bash "$WAVES" </dev/null 2>&1 >/dev/null)
if echo "$USAGE" | grep -qF '[--stage=plan|execute]' \
   && echo "$USAGE" | grep -qF '(classify: deprecated alias of plan, removed next release)'; then
  pass_msg "usage() shows --stage=plan|execute and classify deprecation"
else
  fail_msg "usage(): $USAGE"
fi

# 3. Header comment documents plan canonical + classify alias.
if head -30 "$WAVES" | grep -qF '(plan|execute)' \
   && head -30 "$WAVES" | grep -qF '(classify: deprecated alias of plan, removed next release)'; then
  pass_msg "header comment documents plan canonical + classify alias"
else
  fail_msg "header comment missing plan-canonical/classify-alias text"
fi

# 4. --stage=plan prints the plan verb, single parallel wave.
OUT=$(bash "$WAVES" --stage=plan 1 2 2>/dev/null)
if echo "$OUT" | grep -qE '^Wave 1: plan #1, #2 in parallel$' && ! echo "$OUT" | grep -qE '^Wave 2:'; then
  pass_msg "--stage=plan → Wave 1: plan #1, #2 in parallel"
else
  fail_msg "--stage=plan output: $OUT"
fi

# 5. --stage=classify alias still works and prints `classify` (one release).
if OUT=$(bash "$WAVES" --stage=classify 1 2 2>/dev/null) \
   && echo "$OUT" | grep -qE '^Wave 1: classify #1, #2 in parallel$'; then
  pass_msg "--stage=classify alias exits 0 and prints classify verb"
else
  fail_msg "--stage=classify alias: $OUT"
fi

# 6. File-conflict comment names the plan stage (alias classify).
if grep -qF 'the plan stage (alias classify) skips it' "$WAVES"; then
  pass_msg "file-conflict comment updated"
else
  fail_msg "file-conflict comment not updated"
fi

# 7. resolve-stage-model.sh header notes the classify fold (#1485).
HDR=$(awk 'NR>1 && /^[^#]/ {exit} {print}' "$RESOLVER")
if echo "$HDR" | grep -qF '#1485' \
   && echo "$HDR" | grep -qiE 'no .?classify.? stage arm' \
   && echo "$HDR" | grep -qiE 'classif.*(inline|inside).*plan'; then
  pass_msg "resolver header documents no classify arm (classification inside plan)"
else
  fail_msg "resolver header lacks #1485 classify-fold note"
fi

# 8. resolver has no classify arm: usage error exit 2.
bash "$RESOLVER" 1 classify >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
  pass_msg "resolve-stage-model.sh 1 classify exits 2 (no classify arm)"
else
  fail_msg "resolve-stage-model.sh 1 classify exited $rc (expected 2)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
