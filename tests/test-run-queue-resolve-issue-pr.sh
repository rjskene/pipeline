#!/bin/bash
set -uo pipefail

# Issue #518: classify_issue / resolve_issue_pr currently use the loose
# `linked:<N>` PR-search qualifier which is NOT an exact-scope filter — it
# returned the unrelated PR #513 (the visual-proof PR for #512) when invoked
# for issue #517, causing the mock-web-eval classifier to run against #513's
# diff and emit `--container-mode=mock-web-eval`, which spawn-claude then
# rejected for `execute-issue-plan` (allowlist miss → blocked dispatch).
#
# This test pins the fix: both helpers must scope the lookup by the closing
# keyword (`Closes #<N>` / `Fixes #<N>` / `Resolves #<N>`, case-insensitive,
# word-boundary-anchored) in the candidate PR's body. PRs that mention #<N>
# only in passing (e.g. "see also #517", or `Closes #512` for a sibling
# issue) MUST NOT be returned.
#
# Strategy: extract the two helper functions from scripts/run-queue.sh,
# source them into this shell with a stub `gh` on PATH plus a stub
# classifier-invoke. No tmux, no main poll loop — the helpers are unit-
# testable in isolation.
#
# Three assertions:
#   (a) resolve_issue_pr 517 returns empty when the only candidate PR
#       (#513) lacks `Closes #517`/`Fixes #517`/etc. in its body.
#   (b) classify_issue 517 emits `mode=bare` (first line) instead of
#       propagating the noise PR #513 into the classifier, which would
#       otherwise emit `--container-mode=mock-web-eval`.
#   (c) Positive control: when the candidate PR's body DOES contain
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

# Extract the two function definitions from run-queue.sh and write them to a
# sourceable fragment. The functions reference only `gh`, `mktemp`, `head`,
# `cat`, `rm`, `bash`, and `${CLAUDE_PLUGIN_ROOT:-.}/scripts/eval-classifier-invoke.sh`
# — all of which we stub below.
HELPERS_FILE="$SANDBOX/helpers.sh"
{
  sed -n '/^classify_issue() {/,/^}/p' "$RUN_QUEUE"
  echo
  sed -n '/^resolve_issue_pr() {/,/^}/p' "$RUN_QUEUE"
} > "$HELPERS_FILE"

# Sanity: both function definitions made it into the fragment.
if ! grep -q '^classify_issue() {' "$HELPERS_FILE" || \
   ! grep -q '^resolve_issue_pr() {' "$HELPERS_FILE"; then
  echo "FATAL: failed to extract helpers from $RUN_QUEUE" >&2
  exit 2
fi

# Stub classifier-invoke: emits `--container-mode=mock-web-eval` when called
# with a non-empty PR argument (simulating the mock-web-eval classifier
# reacting to PR #513's diff). With the fix in place, the helper is called
# with PR='' and the stub emits nothing → mode=bare.
mkdir -p "$SANDBOX/plugin/scripts"
cat > "$SANDBOX/plugin/scripts/eval-classifier-invoke.sh" <<'EOF'
#!/bin/bash
# $1 = issue, $2 = pr
if [ -n "${2:-}" ]; then
  echo "--container-mode=mock-web-eval"
fi
exit 0
EOF
chmod +x "$SANDBOX/plugin/scripts/eval-classifier-invoke.sh"

# Stub gh: drives both lookups. The two case-specific branches differ only in
# whether the candidate PR body contains the closing keyword for #517.
make_gh_stub() {
  local closes_517="$1"   # "yes" → body has `Closes #517`; "no" → only #512
  local stub="$2"
  cat > "$stub/gh" <<EOF
#!/bin/bash
ARGS="\$*"
case "\$1 \$2" in
  "pr list")
    # Pre-fix path: \`linked:<N>\` returns the noise PR #513 (kept so the
    # RED run before the fix lands still exhibits the bug; post-fix this
    # branch is dead code because resolve_issue_pr no longer uses
    # \`linked:\` and the inline classify_issue lookup was unified into it).
    if [[ "\$ARGS" == *'--search linked:517'* ]]; then
      if [[ "\$ARGS" == *'.[0].number'* ]]; then
        echo "513"
      else
        echo '[{"number":513}]'
      fi
      exit 0
    fi
    # Post-fix path: exact-scope search returns a JSON array of {number,body}
    # so the helper can closing-keyword-filter the body. The two cases differ
    # only in whether the body contains \`Closes #517\` (positive control)
    # vs only \`Closes #512\` (the issue #518 noise shape).
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
  "pr view")
    # Some implementations re-fetch the body via \`gh pr view\`. Mirror the
    # same body shape so both lookup strategies agree.
    if [ "${closes_517}" = "yes" ]; then
      echo '{"body":"Visual proof for #512\\n\\nCloses #517"}'
    else
      echo '{"body":"Visual proof for #512\\n\\nCloses #512"}'
    fi
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
  local cmd="$2"         # e.g. "resolve_issue_pr 517" or "classify_issue 517"
  local stub="$SANDBOX/stub-$closes_517"
  mkdir -p "$stub"
  make_gh_stub "$closes_517" "$stub"
  (
    set +e
    export PATH="$stub:$PATH"
    export CLAUDE_PLUGIN_ROOT="$SANDBOX/plugin"
    export PIPELINE_REPO="fake/repo"
    # Non-empty classifier so classify_issue takes the full gh-lookup path
    # (the empty-classifier branch short-circuits to mode=bare without
    # touching the bug surface).
    export PIPELINE_EVAL_CLASSIFIER="dummy.sh"
    export PIPELINE_PROJECT_ROOT="$SANDBOX/plugin"
    # Provide the consumer-side classifier file so classifier-invoke does
    # not bail with classifier-not-found (it would still exit 0, but mode
    # logic would route differently).
    touch "$SANDBOX/plugin/dummy.sh"
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
  fail_msg "(a) expected empty, got: '$out_a' (linked:517 noise PR leaked through)"
fi

# ============================== (b) ==============================
echo ""
echo "Case (b): classify_issue 517 emits mode=bare (noise PR not propagated to classifier)"
out_b_full=$(run_case "no" "classify_issue 517")
mode_b=$(printf '%s\n' "$out_b_full" | head -1)
inc
if [ "$mode_b" = "bare" ]; then
  pass_msg "(b) classify_issue 517 first line == 'bare'"
else
  fail_msg "(b) expected first line 'bare', got: '$mode_b' (classifier saw noise PR #513 and emitted container-mode)"
  printf '%s\n' "$out_b_full" | sed 's/^/    /'
fi

# ============================== (c) ==============================
echo ""
echo "Case (c): positive control — resolve_issue_pr 517 returns 513 when body has Closes #517"
out_c=$(run_case "yes" "resolve_issue_pr 517" | tr -d '[:space:]')
inc
if [ "$out_c" = "513" ]; then
  pass_msg "(c) resolve_issue_pr 517 -> 513 (closing keyword match)"
else
  fail_msg "(c) expected '513', got: '$out_c' (legitimate PR was wrongly filtered out)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
