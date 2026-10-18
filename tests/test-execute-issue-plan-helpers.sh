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
for h in fetch-plan pre-pr; do
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

# Pre-PR helper fixture: a temp CLAUDE_PLUGIN_ROOT whose derive-pr-title.sh and
# check-cross-cutting-guards.sh are env-driven stubs.
mkdir -p "$TMP/plug/scripts"
cat > "$TMP/plug/scripts/derive-pr-title.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "${STUB_TITLE:-feat(x): stub title}"
exit "${STUB_TITLE_RC:-0}"
STUB
cat > "$TMP/plug/scripts/check-cross-cutting-guards.sh" <<'STUB'
#!/bin/bash
echo "GUARDS-RAN"
[ -n "${STUB_GUARD_ERR:-}" ] && printf '%s\n' "$STUB_GUARD_ERR" >&2
exit "${STUB_GUARD_RC:-0}"
STUB
chmod +x "$TMP/plug/scripts/"*.sh

# run_prepr [env...] — stdout in $TMP/out, stdout+stderr in $TMP/all.
run_prepr() {
  ( cd "$TMP/proj" && env PATH="$TMP/bin:$PATH" PIPELINE_REPO=fake/repo PIPELINE_BASE_BRANCH=main \
      CLAUDE_PLUGIN_ROOT="$TMP/plug" "$@" bash "$PREPR" 77 ) > "$TMP/out" 2>"$TMP/err"
  local rc=$?
  cat "$TMP/out" "$TMP/err" > "$TMP/all"
  return "$rc"
}
all_has() { grep -qF -- "$1" "$TMP/all"; }

scenario "P1: title rc 0 + guards rc 0 -> PR_TITLE=<title>, rc 0"
run_prepr STUB_TITLE='fix(core): a title'; rc=$?
if [ "$rc" -eq 0 ] && [ "$(tail -n 1 "$TMP/out")" = 'PR_TITLE=fix(core): a title' ] && all_has 'GUARDS-RAN'; then
  pass_msg "green -> last stdout line PR_TITLE=<title>"
else
  fail_msg "green: rc=$rc out: $(tr '\n' ' ' < "$TMP/all")"
fi

scenario "P2: title rc 2 -> tracker ABORT, rc 1"
run_prepr STUB_TITLE_RC=2; rc=$?
if [ "$rc" -eq 1 ] && all_has 'ABORT: Issue #77 is a tracker' && ! all_has 'PR_TITLE=' && ! all_has 'GUARDS-RAN'; then
  pass_msg "tracker -> ABORT rc 1, guards not run"
else
  fail_msg "tracker: rc=$rc out: $(tr '\n' ' ' < "$TMP/all")"
fi

scenario "P3: title rc 3 -> derive failure ABORT, rc 1"
run_prepr STUB_TITLE_RC=3; rc=$?
if [ "$rc" -eq 1 ] && all_has 'ABORT: derive-pr-title.sh failed with exit 3' && ! all_has 'PR_TITLE='; then
  pass_msg "derive failure -> ABORT rc 1"
else
  fail_msg "derive failure: rc=$rc out: $(tr '\n' ' ' < "$TMP/all")"
fi

scenario "P4: guards rc 1 -> guard failure ABORT, rc 1"
run_prepr STUB_GUARD_RC=1; rc=$?
if [ "$rc" -eq 1 ] && all_has 'ABORT: cross-cutting guard failure' && ! all_has 'PR_TITLE='; then
  pass_msg "guard failure -> ABORT rc 1"
else
  fail_msg "guard failure: rc=$rc out: $(tr '\n' ' ' < "$TMP/all")"
fi

scenario "P5: guards rc 0 + INERT cruft arm -> INERT ABORT, rc 1"
run_prepr STUB_GUARD_ERR='INERT: check-branch-cruft.sh (PIPELINE_BASE_BRANCH unset)'; rc=$?
if [ "$rc" -eq 1 ] && all_has 'ABORT: the cruft guard went INERT' && ! all_has 'PR_TITLE='; then
  pass_msg "INERT cruft guard -> ABORT rc 1 (P1 is its negative control)"
else
  fail_msg "INERT: rc=$rc out: $(tr '\n' ' ' < "$TMP/all")"
fi

echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
[ "$FAIL" -eq 0 ]
