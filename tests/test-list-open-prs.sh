#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."

# Unit test for scripts/list-open-prs.sh — the feed helper that emits one
# deterministic ledger line per OPEN pull request (mirror of
# scripts/list-release-prs.sh). Issue #1168.
#
# The helper makes exactly one `gh pr list` call; this test stubs `gh` with a
# JSON fixture so the emitted line format is asserted hermetically (no live
# GitHub). The contract under test:
#
#   pr=<num> base=<baseRefName> draft=<true|false> ci=<pass|fail|pending> \
#     review=<approved|changes|none> issue=<N|--> title=<title>
#
# Fixture exercises every mapping branch:
#   #501 — all-SUCCESS rollup → ci=pass; reviewDecision APPROVED → approved;
#          draft=false; base=staging; branch trailing `-1168` → issue=1168.
#   #502 — empty rollup → ci=pending; reviewDecision null → none; draft=true;
#          dependabot branch (no trailing -N) + no body Closes → issue=--.
#   #503 — FAILURE rollup → ci=fail; CHANGES_REQUESTED → changes; draft=false;
#          base=main; body "Fixes #77" (no branch number) → issue=77.

# pipeline.config is gitignored — prefer it locally, fall back to the committed
# example so the test also runs in CI.
if [ -f ./pipeline.config ]; then
  # shellcheck disable=SC1091
  source ./pipeline.config
else
  # shellcheck disable=SC1091
  source ./pipeline.config.example
fi
export PIPELINE_REPO

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && echo "    $2"; }

STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*"--state open"*"statusCheckRollup"*)
    cat <<'JSON'
[
  {"number":501,"title":"feat(status): add unmerged PR ledger","baseRefName":"staging","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS"}],"headRefName":"feature/status-unmerged-prs-ledger-1168","body":"advisory ledger feature"},
  {"number":502,"title":"chore(deps): bump lodash","baseRefName":"staging","isDraft":true,"reviewDecision":null,"statusCheckRollup":[],"headRefName":"dependabot/npm_and_yarn/lodash","body":"bumps lodash from 1.0.0 to 1.0.1"},
  {"number":503,"title":"fix(core): handle nil","baseRefName":"main","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"conclusion":"FAILURE"}],"headRefName":"hotfix/nil-guard","body":"Fixes #77 in the core module"}
]
JSON
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

OUT=$(PATH="$STUB_DIR:$PATH" bash scripts/list-open-prs.sh 2>/dev/null || true)

# --- Exact line format, per PR (grep -qxF = whole-line fixed-string) --------

exp_501='pr=501 base=staging draft=false ci=pass review=approved issue=1168 title=feat(status): add unmerged PR ledger'
if printf '%s\n' "$OUT" | grep -qxF "$exp_501"; then
  pass_msg "#501 row: pass/approved/draft=false, branch-slug issue=1168"
else
  fail_msg "#501 row: pass/approved/draft=false, branch-slug issue=1168" "got: $OUT"
fi

exp_502='pr=502 base=staging draft=true ci=pending review=none issue=-- title=chore(deps): bump lodash'
if printf '%s\n' "$OUT" | grep -qxF "$exp_502"; then
  pass_msg "#502 row: pending/none/draft=true, issue-less PR → issue=--"
else
  fail_msg "#502 row: pending/none/draft=true, issue-less PR → issue=--" "got: $OUT"
fi

exp_503='pr=503 base=main draft=false ci=fail review=changes issue=77 title=fix(core): handle nil'
if printf '%s\n' "$OUT" | grep -qxF "$exp_503"; then
  pass_msg "#503 row: fail/changes, body-Fixes issue=77, base=main"
else
  fail_msg "#503 row: fail/changes, body-Fixes issue=77, base=main" "got: $OUT"
fi

# --- CRLF discipline (#1165): no stray CR in emitted feed ------------------
if printf '%s' "$OUT" | grep -q $'\r'; then
  fail_msg "no stray CR in emitted feed lines" "$(printf '%s' "$OUT" | grep -n $'\r' | head)"
else
  pass_msg "no stray CR in emitted feed lines"
fi

echo ""
echo "=========================================================="
echo "test-list-open-prs: PASS: $PASS  FAIL: $FAIL"
echo "=========================================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
