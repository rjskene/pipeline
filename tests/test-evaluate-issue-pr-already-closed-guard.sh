#!/bin/bash
# SKILL-level test for the Step 11 "issue already closed" benign-non-error
# guard (#813).
#
# Context: `gh pr merge` auto-closes the linked issue via
# closingIssuesReferences a beat before the skill's explicit `gh issue close`
# runs, so the explicit close reports "already closed". Cosmetic only — the
# final state is correct — but it reads like an error in logs on every merge.
#
# Fix (option b): swallow the benign "already closed" non-error on the
# explicit `gh issue close` so it does NOT surface as an error.
#
# Substrate:
#   - A small bash driver mirrors Step 11's close call wrapped in the
#     prescribed guard. Two fixtures:
#       (a) gh issue close exits non-zero with an "already closed" stderr
#           -> driver MUST exit 0 (benign swallow), no error surfaced.
#       (b) gh issue close exits non-zero with a genuine error stderr
#           -> driver MUST surface a non-zero exit (real failure not masked).
#   - The SKILL.md prose is linted for the new Step 11 guard contract.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${ROOT}/skills/evaluate-issue-pr/SKILL.md"

if [ ! -f "$SKILL" ]; then
  echo "FAIL: prerequisite SKILL.md missing"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
pass() { echo "  PASS: $1"; }

mkdir -p "$TMP/bin"
for util in grep head awk cat sed; do
  if [ -x "/usr/bin/$util" ]; then
    ln -sf "/usr/bin/$util" "$TMP/bin/$util"
  elif [ -x "/bin/$util" ]; then
    ln -sf "/bin/$util" "$TMP/bin/$util"
  fi
done

# -----------------------------------------------------------------------------
# Extract the guard snippet from the SKILL so the test exercises the SAME
# code the skill prescribes (not a private re-implementation). We pull the
# fenced bash block containing the `gh issue close` call from Step 11.
# -----------------------------------------------------------------------------
SNIPPET="$TMP/close_snippet.sh"
awk '
  /^[[:space:]]*```bash/ { inblk=1; buf=""; next }
  /^[[:space:]]*```/      { if (inblk && buf ~ /gh issue close/) { printf "%s", buf; exit } inblk=0; next }
  inblk { line=$0; sub(/^[[:space:]]+/, "", line); buf = buf line "\n" }
' "$SKILL" > "$SNIPPET"

if ! grep -q 'gh issue close' "$SNIPPET"; then
  fail "could not locate a Step 11 'gh issue close' bash block in SKILL.md"
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi

# -----------------------------------------------------------------------------
# Driver: source the extracted snippet with the close-comment variables
# pre-bound, against a gh shim. Asserts the snippet's own guard behaviour.
# -----------------------------------------------------------------------------
DRIVER="$TMP/driver.sh"
cat > "$DRIVER" <<DRIVER_BODY
#!/bin/bash
set -u
ISSUE=100
PR_NUM=200
SHA=abcdef0
CLOSE_SUFFIX=" (\${SHA})"
FOOTER="Auto-merged: test"
PIPELINE_REPO="test/repo"
# shellcheck disable=SC1090
source "$SNIPPET"
DRIVER_BODY
chmod +x "$DRIVER"

# -----------------------------------------------------------------------------
# Fixture (a): gh issue close fails with a benign "already closed" message.
# -----------------------------------------------------------------------------
echo "=== Fixture (a): benign 'already closed' is swallowed ==="
cat > "$TMP/bin/gh" <<'SHIM_A'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue edit"*) exit 0 ;;
  *"issue close"*)
    echo "failed to close issue: GraphQL: Issue is already closed (closeIssue)" >&2
    exit 1 ;;
  *) echo "[shim-a] unhandled: $ALL_ARGS" >&2; exit 1 ;;
esac
SHIM_A
chmod +x "$TMP/bin/gh"

(
  export PATH="$TMP/bin:$PATH"
  bash "$DRIVER" > "$TMP/a.out" 2> "$TMP/a.err"
  echo $? > "$TMP/a.rc"
)
a_rc=$(cat "$TMP/a.rc")
if [ "$a_rc" -eq 0 ]; then
  pass "fixture (a): benign already-closed swallowed (driver rc=0)"
else
  fail "fixture (a): expected rc=0 (benign swallow), got rc=$a_rc err='$(cat "$TMP/a.err")'"
fi

# -----------------------------------------------------------------------------
# Fixture (b): gh issue close fails with a GENUINE error (not already-closed).
# The guard must NOT mask a real failure.
# -----------------------------------------------------------------------------
echo "=== Fixture (b): genuine close failure is NOT masked ==="
cat > "$TMP/bin/gh" <<'SHIM_B'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue edit"*) exit 0 ;;
  *"issue close"*)
    echo "failed to close issue: HTTP 503 service unavailable" >&2
    exit 1 ;;
  *) echo "[shim-b] unhandled: $ALL_ARGS" >&2; exit 1 ;;
esac
SHIM_B
chmod +x "$TMP/bin/gh"

(
  export PATH="$TMP/bin:$PATH"
  bash "$DRIVER" > "$TMP/b.out" 2> "$TMP/b.err"
  echo $? > "$TMP/b.rc"
)
b_rc=$(cat "$TMP/b.rc")
if [ "$b_rc" -ne 0 ]; then
  pass "fixture (b): genuine close failure surfaced (driver rc=$b_rc)"
else
  fail "fixture (b): expected rc!=0 (real failure surfaced), got rc=0"
fi

# -----------------------------------------------------------------------------
# SKILL.md prose contract.
# -----------------------------------------------------------------------------
echo "=== SKILL.md prose contract ==="
prose_want() {
  local name="$1" pat="$2"
  if grep -qiE -- "$pat" "$SKILL"; then
    pass "$name"
  else
    fail "$name (pattern not found: $pat)"
  fi
}
prose_want "Step 11 documents already-closed benign swallow" 'already closed|already-closed'
prose_want "Step 11 references #813" '#813'

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
