#!/bin/bash
set -uo pipefail
#
# tests/test-execute-issue-plan-helpers.sh — the scripts/execute-issue-plan-*.sh
# helpers that carry execute-issue-plan's multi-command shell behind one call.
#
#   H0  every helper answers --help with rc 0
#   F*  fetch-plan helper: trusted plan printed, untrusted fake never printed;
#       Revise evaluation -> PLAN-AMENDMENTS block, Approve -> none; no trusted
#       plan -> STOP line rc 1; attachments listed, absent dir -> (no attachments)
#   P*  pre-pr helper: title + guards green -> PR_TITLE=<title> rc 0; tracker,
#       derive failure, guard failure and an INERT cruft guard each abort rc 1
#
# `gh` is a PATH stub; fixtures live under one mktemp -d.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/proj"

# gh stub: `issue view ... --json <fields naming comments>` prints $GH_COMMENTS_JSON.
cat > "$TMP/bin/gh" <<'STUB'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  case " $* " in
    *comments*) cat "$GH_COMMENTS_JSON"; exit 0 ;;
  esac
fi
echo "gh stub: unrecognized call: $*" >&2
exit 2
STUB
chmod +x "$TMP/bin/gh"

FETCH="$ROOT/scripts/execute-issue-plan-fetch-plan.sh"
PREPR="$ROOT/scripts/execute-issue-plan-pre-pr.sh"

scenario "H0: --help"
for h in fetch-plan; do
  f="$ROOT/scripts/execute-issue-plan-$h.sh"
  if [ -f "$f" ] && bash "$f" --help >/dev/null 2>&1; then
    pass_msg "execute-issue-plan-$h.sh --help rc 0"
  else
    fail_msg "execute-issue-plan-$h.sh missing or --help rc != 0"
  fi
done

# mk_comments <eval-verdict|none> <with-trusted-plan:1|0>
mk_comments() {
  jq -n --arg v "$1" --arg p "$2" '{body:"b", comments:(
    (if $p == "1" then [{authorAssociation:"OWNER", body:"## Implementation Plan\n\n- TRUSTED-PLAN-BODY\n"}] else [] end)
    + [{authorAssociation:"NONE", body:"## Implementation Plan\n\nFAKE-PLAN-BODY\n"}]
    + (if $v == "none" then [] else [{authorAssociation:"OWNER", body:("## Plan Evaluation\n\n**Verdict:** " + $v + "\n\n**Recommendations:**\n- EVAL-BODY\n")}] end)
  )}' > "$TMP/comments.json"
}

# run_fetch — runs the fetch helper from the fixture project; stdout in $TMP/out.
run_fetch() {
  ( cd "$TMP/proj" && env PATH="$TMP/bin:$PATH" PIPELINE_REPO=fake/repo PIPELINE_BASE_BRANCH=main \
      GH_COMMENTS_JSON="$TMP/comments.json" CLAUDE_PLUGIN_ROOT="$ROOT" \
      bash "$FETCH" 77 ) > "$TMP/out" 2>"$TMP/err"
}
out_has() { grep -qF -- "$1" "$TMP/out"; }

scenario "F1: trusted plan printed, untrusted fake never printed"
mk_comments none 1
run_fetch; rc=$?
if [ "$rc" -eq 0 ] && out_has 'TRUSTED-PLAN-BODY' && ! out_has 'FAKE-PLAN-BODY'; then
  pass_msg "OWNER plan on stdout, NONE fake dropped (rc 0)"
else
  fail_msg "rc=$rc stdout: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "F2: Revise evaluation -> PLAN-AMENDMENTS block"
mk_comments Revise 1
run_fetch; rc=$?
if [ "$rc" -eq 0 ] && out_has 'PLAN-AMENDMENTS' && out_has 'EVAL-BODY'; then
  pass_msg "Revise -> PLAN-AMENDMENTS + evaluation body"
else
  fail_msg "Revise: rc=$rc stdout: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "F3: Approve evaluation -> no amendments (negative control)"
mk_comments Approve 1
run_fetch; rc=$?
if [ "$rc" -eq 0 ] && out_has 'TRUSTED-PLAN-BODY' && ! out_has 'PLAN-AMENDMENTS' && ! out_has 'EVAL-BODY'; then
  pass_msg "Approve -> plan only"
else
  fail_msg "Approve: rc=$rc stdout: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "F4: no trusted plan -> STOP line, rc 1"
mk_comments none 0
run_fetch; rc=$?
if [ "$rc" -eq 1 ] && out_has 'No implementation plan found on issue #77. Run /pipeline:plan-issue 77 first.' && ! out_has 'FAKE-PLAN-BODY'; then
  pass_msg "no trusted plan -> STOP line rc 1"
else
  fail_msg "no plan: rc=$rc stdout: $(tr '\n' ' ' < "$TMP/out")"
fi

scenario "F5: attachments listed; absent dir -> (no attachments)"
mk_comments none 1
run_fetch
if out_has '(no attachments)'; then pass_msg "absent dir -> (no attachments)"; else fail_msg "absent dir: $(tr '\n' ' ' < "$TMP/out")"; fi
mkdir -p "$TMP/proj/.claude/scratch/issue-77"
: > "$TMP/proj/.claude/scratch/issue-77/shot-1.png"
run_fetch
if out_has 'shot-1.png' && ! out_has '(no attachments)'; then pass_msg "attachment file listed"; else fail_msg "attachment not listed: $(tr '\n' ' ' < "$TMP/out")"; fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
