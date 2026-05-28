#!/bin/bash
set -uo pipefail

# Issue #518: resolve_issue_pr must scope the PR lookup by the closing
# keyword (`Closes #<N>` / `Fixes #<N>` / `Resolves #<N>`, case-insensitive,
# word-boundary-anchored) in the candidate PR's body. PRs that mention #<N>
# only in passing (e.g. "see also #517", or `Closes #512` for a sibling
# issue) MUST NOT be returned.
#
# Post-#514 the pre-spawn classifier was removed (classify_issue
# unconditionally emits mode=bare), so this test no longer exercises the
# classifier-rejection path. The exact-scope resolve_issue_pr contract is
# still load-bearing for evaluator_finished_terminal()'s manual-merge /
# block-* detection, so we pin it here.
#
# Strategy: extract resolve_issue_pr from scripts/run-queue.sh and source it
# into this shell with a stub `gh` on PATH. No tmux, no main poll loop —
# the helper is unit-testable in isolation.
#
# Two assertions:
#   (a) resolve_issue_pr 517 returns empty when the only candidate PR
#       (#513) lacks `Closes #517`/`Fixes #517`/etc. in its body.
#   (b) Positive control: when the candidate PR's body DOES contain
#       `Closes #517`, resolve_issue_pr 517 returns 513.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_QUEUE="$REPO_ROOT/scripts/run-queue.sh"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Extract the resolve_issue_pr function definition from run-queue.sh and write
# it to a sourceable fragment. The function references only `gh` and `python3`
# — both stubbed / present on PATH.
HELPERS_FILE="$SANDBOX/helpers.sh"
sed -n '/^resolve_issue_pr() {/,/^}/p' "$RUN_QUEUE" > "$HELPERS_FILE"

# Sanity: function definition made it into the fragment.
if ! grep -q '^resolve_issue_pr() {' "$HELPERS_FILE"; then
  echo "FATAL: failed to extract resolve_issue_pr from $RUN_QUEUE" >&2
  exit 2
fi

# Stub gh: drives the lookup. The two case-specific branches differ only in
# whether the candidate PR body contains the closing keyword for #517.
make_gh_stub() {
  local closes_517="$1"   # "yes" → body has `Closes #517`; "no" → only #512
  local stub="$2"
  cat > "$stub/gh" <<EOF
#!/bin/bash
ARGS="\$*"
case "\$1 \$2" in
  "pr list")
    # Exact-scope search returns a JSON array of {number,body} so the helper
    # can closing-keyword-filter the body. The two cases differ only in
    # whether the body contains \`Closes #517\` (positive control) vs only
    # \`Closes #512\` (the issue #518 noise shape).
    if [[ "\$ARGS" == *'in:title,body'* ]]; then
      if [ "${closes_517}" = "yes" ]; then
        echo '[{"number":513,"body":"Visual proof for #512\n\nCloses #517"}]'
      else
        echo '[{"number":513,"body":"Visual proof for #512\n\nCloses #512"}]'
      fi
      exit 0
    fi
    echo ""
    ;;
  *) echo "" ;;
esac
EOF
  chmod +x "$stub/gh"
}

# Helper: run one assertion in an isolated subshell so set state, PATH,
# and sourced functions don't leak between cases.
run_case() {
  local closes_517="$1"  # yes|no
  local cmd="$2"         # e.g. "resolve_issue_pr 517"
  local stub="$SANDBOX/stub-$closes_517"
  mkdir -p "$stub"
  make_gh_stub "$closes_517" "$stub"
  (
    set +e
    export PATH="$stub:$PATH"
    export PIPELINE_REPO="fake/repo"
    # shellcheck disable=SC1090
    source "$HELPERS_FILE"
    eval "$cmd"
  )
}

# ============================== (a) ==============================
echo "Case (a): resolve_issue_pr 517 returns empty for noise PR without Closes #517"
out_a=$(run_case "no" "resolve_issue_pr 517" | tr -d '[:space:]')
inc
if [ -z "$out_a" ]; then
  pass_msg "(a) resolve_issue_pr 517 -> empty (noise PR rejected)"
else
  fail_msg "(a) expected empty, got: '$out_a' (noise PR leaked through)"
fi

# ============================== (b) ==============================
echo ""
echo "Case (b): positive control — resolve_issue_pr 517 returns 513 when body has Closes #517"
out_b=$(run_case "yes" "resolve_issue_pr 517" | tr -d '[:space:]')
inc
if [ "$out_b" = "513" ]; then
  pass_msg "(b) resolve_issue_pr 517 -> 513 (closing keyword match)"
else
  fail_msg "(b) expected '513', got: '$out_b' (legitimate PR was wrongly filtered out)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
