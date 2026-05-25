#!/bin/bash
# SKILL-level integration test for the Step 11 baseRefName assertion +
# TOCTOU re-check defense-in-depth gate (#295).
#
# Three fixtures:
#   (a) baseRefName=main at gate time, PIPELINE_BASE_BRANCH=staging:
#       gate emits `block-base-mismatch`; SKILL Step 11.4 comment-body
#       template contains the literal "Auto-merge skipped: block-base-mismatch"
#       and a retarget suggestion line; no `gh pr merge` is invoked.
#   (b) baseRefName=staging at gate time, but flips to `main` between
#       the gate call and the merge call (TOCTOU): the SECOND
#       `gh pr view --json baseRefName` re-read MUST detect divergence
#       and abort.
#   (c) baseRefName=staging at BOTH call sites: green path, merge proceeds.
#
# Substrate:
#   - Fixture (a) drives auto_merge_should_fire directly via the harness.
#   - Fixture (b) drives a small bash driver that mirrors Step 11's
#     "gate -> re-read baseRefName -> gh pr merge" sequence using a gh
#     shim with a counter file in $TMPDIR that flips baseRefName on the
#     second call.
#   - Fixture (c) drives the same driver with a stable-staging shim.
#   - The SKILL.md prose is linted for the new Step 11 contract
#     (block-base-mismatch enumeration, TOCTOU re-check description,
#     retarget-suggestion comment template, dual-defense doctrine note).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/auto-merge-gate.sh"
SKILL="${ROOT}/skills/evaluate-issue-pr/SKILL.md"
HARNESS="${ROOT}/tests/_lib/auto-merge-gate-harness.sh"

if [ ! -f "$HELPER" ] || [ ! -f "$SKILL" ] || [ ! -f "$HARNESS" ]; then
  echo "FAIL: prerequisite file missing"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAILED=0
fail() { echo "  FAIL: $1"; FAILED=$((FAILED+1)); }
pass() { echo "  PASS: $1"; }

mkdir -p "$TMP/bin"
for util in grep head awk jq cat; do
  if [ -x "/usr/bin/$util" ]; then
    ln -sf "/usr/bin/$util" "$TMP/bin/$util"
  elif [ -x "/bin/$util" ]; then
    ln -sf "/bin/$util" "$TMP/bin/$util"
  fi
done

# -----------------------------------------------------------------------------
# Fixture (a): gate-level rejection on baseRefName=main.
# -----------------------------------------------------------------------------
echo "=== Fixture (a): baseRefName=main at gate time ==="
cat > "$TMP/bin/gh" <<'SHIM_A'
#!/bin/bash
ALL_ARGS="$*"
case "$ALL_ARGS" in
  *"issue view"*"--json labels"*) printf '\n' ;;
  *"pr view"*"--json baseRefName"*) printf 'main\n' ;;
  *"pr view"*"--json comments"*)
    printf '## Evaluation\n\n**Verdict:** Approved\n' ;;
  *"pr view"*"--json statusCheckRollup"*)
    printf '%s' '{"statusCheckRollup":[{"name":"x","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
  *"pr merge"*)
    echo "GATE_BREACH: gh pr merge was invoked despite base mismatch" >&2
    exit 99 ;;
  *) echo "[shim-a] unhandled: $ALL_ARGS" >&2; exit 1 ;;
esac
SHIM_A
chmod +x "$TMP/bin/gh"

(
  export PATH="$TMP/bin:$PATH"
  export PIPELINE_REPO="test/repo"
  export PIPELINE_BASE_BRANCH="staging"
  unset MANUAL_MERGE
  # shellcheck disable=SC1090
  source "$HARNESS"
  out=$(auto_merge_should_fire 100 200 2>/dev/null); rc=$?
  printf '%s\n' "$out" > "$TMP/a.out"
  echo "$rc" > "$TMP/a.rc"
)

a_out=$(cat "$TMP/a.out")
a_rc=$(cat "$TMP/a.rc")
if [ "$a_rc" -ne 0 ] && [ "$a_out" = "block-base-mismatch" ]; then
  pass "fixture (a): gate emits block-base-mismatch, rc != 0"
else
  fail "fixture (a): expected rc!=0 + 'block-base-mismatch', got rc=$a_rc out='$a_out'"
fi

# -----------------------------------------------------------------------------
# TOCTOU driver — mirrors Step 11.3 green path with a second baseRefName
# re-read immediately before `gh pr merge`.
# -----------------------------------------------------------------------------
DRIVER="$TMP/step11_driver.sh"
cat > "$DRIVER" <<'DRIVER_BODY'
#!/bin/bash
# Minimal driver mirroring evaluate-issue-pr Step 11.3 green path with
# the TOCTOU re-check inserted immediately before gh pr merge.
set -u

PR_NUM="$1"
HELPER="$2"
ISSUE=100

# shellcheck disable=SC1090
source "$HELPER"
REASON=$(auto_merge_should_fire "$ISSUE" "$PR_NUM" 2>/dev/null)

if [ "$REASON" != "green" ]; then
  printf 'BLOCK %s\n' "$REASON"
  exit 0
fi

# TOCTOU re-check immediately before merge.
BASE_RECHECK=$(gh pr view "$PR_NUM" --repo "$PIPELINE_REPO" --json baseRefName --jq .baseRefName 2>/dev/null)
if [ -z "$BASE_RECHECK" ] || [ "$BASE_RECHECK" != "$PIPELINE_BASE_BRANCH" ]; then
  printf 'BLOCK block-base-mismatch\n'
  exit 0
fi

gh pr merge "$PR_NUM" --repo "$PIPELINE_REPO" --merge --delete-branch
printf 'MERGED\n'
DRIVER_BODY
chmod +x "$DRIVER"

# -----------------------------------------------------------------------------
# Fixture (b): baseRefName flips main->staging between calls (TOCTOU).
# Counter file: 1st call returns staging (gate passes), 2nd call returns main.
# -----------------------------------------------------------------------------
echo "=== Fixture (b): TOCTOU — baseRefName flips between gate and merge ==="
COUNTER_B="$TMP/counter_b"
echo 0 > "$COUNTER_B"
export _COUNTER_FILE_B="$COUNTER_B"

cat > "$TMP/bin/gh" <<SHIM_B
#!/bin/bash
ALL_ARGS="\$*"
COUNTER_FILE="$COUNTER_B"
case "\$ALL_ARGS" in
  *"issue view"*"--json labels"*) printf '\n' ;;
  *"pr view"*"--json baseRefName"*)
    n=\$(cat "\$COUNTER_FILE")
    n=\$((n+1))
    echo "\$n" > "\$COUNTER_FILE"
    if [ "\$n" = "1" ]; then
      printf 'staging\n'
    else
      printf 'main\n'
    fi
    ;;
  *"pr view"*"--json comments"*)
    printf '## Evaluation\n\n**Verdict:** Approved\n' ;;
  *"pr view"*"--json statusCheckRollup"*)
    printf '%s' '{"statusCheckRollup":[{"name":"x","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
  *"pr merge"*)
    echo "GATE_BREACH: gh pr merge was invoked despite TOCTOU flip" >&2
    exit 99 ;;
  *) echo "[shim-b] unhandled: \$ALL_ARGS" >&2; exit 1 ;;
esac
SHIM_B
chmod +x "$TMP/bin/gh"

(
  export PATH="$TMP/bin:$PATH"
  export PIPELINE_REPO="test/repo"
  export PIPELINE_BASE_BRANCH="staging"
  unset MANUAL_MERGE
  bash "$DRIVER" 200 "$HELPER" > "$TMP/b.out" 2> "$TMP/b.err"
  echo $? > "$TMP/b.rc"
)
b_out=$(cat "$TMP/b.out")
b_err=$(cat "$TMP/b.err")
b_rc=$(cat "$TMP/b.rc")

if [ "$b_rc" -eq 0 ] && [ "$b_out" = "BLOCK block-base-mismatch" ]; then
  pass "fixture (b): TOCTOU re-check caught the flip, no merge invoked"
else
  fail "fixture (b): expected 'BLOCK block-base-mismatch' and rc=0, got rc=$b_rc out='$b_out' err='$b_err'"
fi

# -----------------------------------------------------------------------------
# Fixture (c): green path — baseRefName=staging at both call sites.
# -----------------------------------------------------------------------------
echo "=== Fixture (c): stable staging at both call sites ==="
COUNTER_C="$TMP/counter_c"
echo 0 > "$COUNTER_C"

cat > "$TMP/bin/gh" <<SHIM_C
#!/bin/bash
ALL_ARGS="\$*"
COUNTER_FILE="$COUNTER_C"
case "\$ALL_ARGS" in
  *"issue view"*"--json labels"*) printf '\n' ;;
  *"pr view"*"--json baseRefName"*)
    n=\$(cat "\$COUNTER_FILE")
    n=\$((n+1))
    echo "\$n" > "\$COUNTER_FILE"
    printf 'staging\n'
    ;;
  *"pr view"*"--json comments"*)
    printf '## Evaluation\n\n**Verdict:** Approved\n' ;;
  *"pr view"*"--json statusCheckRollup"*)
    printf '%s' '{"statusCheckRollup":[{"name":"x","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN"}' ;;
  *"pr merge"*) printf 'merge ok\n' ;;
  *) echo "[shim-c] unhandled: \$ALL_ARGS" >&2; exit 1 ;;
esac
SHIM_C
chmod +x "$TMP/bin/gh"

(
  export PATH="$TMP/bin:$PATH"
  export PIPELINE_REPO="test/repo"
  export PIPELINE_BASE_BRANCH="staging"
  unset MANUAL_MERGE
  bash "$DRIVER" 200 "$HELPER" > "$TMP/c.out" 2> "$TMP/c.err"
  echo $? > "$TMP/c.rc"
)
c_out=$(cat "$TMP/c.out")
c_rc=$(cat "$TMP/c.rc")
c_calls=$(cat "$COUNTER_C")

if [ "$c_rc" -eq 0 ] && printf '%s' "$c_out" | grep -q 'MERGED'; then
  pass "fixture (c): green path — merge invoked"
else
  fail "fixture (c): expected MERGED + rc=0, got rc=$c_rc out='$c_out'"
fi

if [ "$c_calls" -ge 2 ]; then
  pass "fixture (c): baseRefName re-read fired (>=2 calls observed: $c_calls)"
else
  fail "fixture (c): TOCTOU re-read never happened (only $c_calls baseRefName calls)"
fi

# -----------------------------------------------------------------------------
# SKILL.md prose assertions for the new Step 11 contract.
# -----------------------------------------------------------------------------
echo "=== SKILL.md prose contract ==="

prose_want() {
  local name="$1" pat="$2"
  if grep -qE -- "$pat" "$SKILL"; then
    pass "$name"
  else
    fail "$name (pattern not found: $pat)"
  fi
}

prose_want "Step 11 enumerates block-base-mismatch token" 'block-base-mismatch'
prose_want "Step 11 documents TOCTOU re-check" '(TOCTOU|re-read|re-check).*baseRefName|baseRefName.*(TOCTOU|re-read|re-check)'
prose_want "Step 11.4 comment template carries Auto-merge skipped literal" 'Auto-merge skipped'
prose_want "Step 11.4 retarget-pr.sh suggestion" 'retarget-pr\.sh'
prose_want "Step 11.4 gh pr edit --base fallback suggestion" 'gh pr edit.*--base'
prose_want "Step 11 dual-defense doctrine note" '(defense-in-depth|defense in depth|dual-defense|dual defense)'
prose_want "Step 11 references #295 / hook bypass rationale" '#295|hook.*bypass|bypassed'

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: all assertions passed"
  exit 0
else
  echo "RESULT: $FAILED assertion(s) failed"
  exit 1
fi
