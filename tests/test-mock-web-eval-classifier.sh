#!/bin/bash
set -uo pipefail

# Tests for scripts/mock-web-eval-classifier.sh (issue #231).
# The classifier emits `--container-mode=mock-web-eval` on stdout when the
# PR touches `mock-web/**` or carries the `web-eval` label; otherwise it
# emits nothing. It exits non-zero with a stderr diagnostic on gh failure.
#
# Test 5 covers the classifier-not-found contract of scripts/eval-classifier-invoke.sh
# end-to-end through the routing seam.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/scripts/mock-web-eval-classifier.sh"
INVOKE_WRAPPER="$REPO_ROOT/scripts/eval-classifier-invoke.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$SCRIPT_UNDER_TEST" ]; then
  echo "ERROR: script under test not found at $SCRIPT_UNDER_TEST" >&2
  exit 1
fi
if [ ! -f "$INVOKE_WRAPPER" ]; then
  echo "ERROR: invoke wrapper not found at $INVOKE_WRAPPER" >&2
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/scripts" "$WORKDIR/bin"
cp "$SCRIPT_UNDER_TEST" "$PROJ/scripts/mock-web-eval-classifier.sh"
chmod +x "$PROJ/scripts/mock-web-eval-classifier.sh"
cp "$INVOKE_WRAPPER" "$PROJ/scripts/eval-classifier-invoke.sh"
chmod +x "$PROJ/scripts/eval-classifier-invoke.sh"

# gh stub — dispatches on $GH_STUB_MODE and the first two args.
# Returns post-jq-shape output (one filename or label per line) to match
# what the classifier sees after `--jq '.labels[].name'` / `--name-only`.
cat > "$WORKDIR/bin/gh" <<'STUB'
#!/bin/bash
case "$GH_STUB_MODE" in
  path-match)
    case "$1 $2" in
      "pr diff") echo "mock-web/index.html"; echo "mock-web/app.js" ;;
      "pr view") : ;;  # no labels
      "pr list") echo "999" ;;
    esac
    ;;
  label-match)
    case "$1 $2" in
      "pr diff") echo "src/foo.ts" ;;
      "pr view") echo "web-eval"; echo "priority/P1" ;;
      "pr list") echo "999" ;;
    esac
    ;;
  neither)
    case "$1 $2" in
      "pr diff") echo "src/foo.ts" ;;
      "pr view") echo "priority/P2" ;;
      "pr list") echo "999" ;;
    esac
    ;;
  fail)
    echo "gh: not authenticated" >&2
    exit 1
    ;;
esac
exit 0
STUB
chmod +x "$WORKDIR/bin/gh"

run_classifier() {
  # Run classifier with the gh stub on PATH. Args forwarded.
  PATH="$WORKDIR/bin:$PATH" bash "$PROJ/scripts/mock-web-eval-classifier.sh" "$@"
}

# -------------------------------------------------------------------------
# Test 1: PR touches mock-web/** -> stdout "--container-mode=mock-web-eval"
# -------------------------------------------------------------------------
echo "Test 1: path match fires"
inc
OUT_FILE="$WORKDIR/out1.txt"
ERR_FILE="$WORKDIR/err1.txt"
GH_STUB_MODE=path-match run_classifier 231 999 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
ACTUAL="$(cat "$OUT_FILE")"
if [ "$rc" -ne 0 ]; then
  fail_msg "expected exit 0 on path match, got $rc (stderr: $(cat "$ERR_FILE"))"
elif [ "$ACTUAL" != "--container-mode=mock-web-eval" ]; then
  fail_msg "expected stdout '--container-mode=mock-web-eval', got '$ACTUAL'"
else
  pass_msg "path match -> --container-mode=mock-web-eval, exit 0"
fi

# -------------------------------------------------------------------------
# Test 2: PR carries `web-eval` label -> stdout "--container-mode=mock-web-eval"
# -------------------------------------------------------------------------
echo "Test 2: label match fires"
inc
OUT_FILE="$WORKDIR/out2.txt"
ERR_FILE="$WORKDIR/err2.txt"
GH_STUB_MODE=label-match run_classifier 231 999 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
ACTUAL="$(cat "$OUT_FILE")"
if [ "$rc" -ne 0 ]; then
  fail_msg "expected exit 0 on label match, got $rc (stderr: $(cat "$ERR_FILE"))"
elif [ "$ACTUAL" != "--container-mode=mock-web-eval" ]; then
  fail_msg "expected stdout '--container-mode=mock-web-eval', got '$ACTUAL'"
else
  pass_msg "label match -> --container-mode=mock-web-eval, exit 0"
fi

# -------------------------------------------------------------------------
# Test 3: neither match -> empty stdout, exit 0
# -------------------------------------------------------------------------
echo "Test 3: neither match -> empty stdout"
inc
OUT_FILE="$WORKDIR/out3.txt"
ERR_FILE="$WORKDIR/err3.txt"
GH_STUB_MODE=neither run_classifier 231 999 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -ne 0 ]; then
  fail_msg "expected exit 0 on no-match, got $rc (stderr: $(cat "$ERR_FILE"))"
elif [ -s "$OUT_FILE" ]; then
  fail_msg "expected empty stdout on no-match, got: $(cat "$OUT_FILE")"
else
  pass_msg "no match -> empty stdout, exit 0"
fi

# -------------------------------------------------------------------------
# Test 4: gh failure -> non-zero exit + stderr diagnostic
# -------------------------------------------------------------------------
echo "Test 4: gh failure surfaces diagnostic"
inc
OUT_FILE="$WORKDIR/out4.txt"
ERR_FILE="$WORKDIR/err4.txt"
GH_STUB_MODE=fail run_classifier 999 999 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -eq 0 ]; then
  fail_msg "expected non-zero exit on gh failure, got 0"
elif ! grep -qE 'gh.*(diff|view|list).*fail' "$ERR_FILE"; then
  fail_msg "expected stderr matching 'gh.*(diff|view|list).*fail'; got: $(cat "$ERR_FILE")"
else
  pass_msg "gh failure -> non-zero exit, stderr diagnostic emitted"
fi

# -------------------------------------------------------------------------
# Test 5: classifier file missing -> invoke wrapper exits 3
# -------------------------------------------------------------------------
echo "Test 5: classifier file missing -> wrapper exit 3"
inc
OUT_FILE="$WORKDIR/out5.txt"
ERR_FILE="$WORKDIR/err5.txt"
PIPELINE_EVAL_CLASSIFIER="scripts/does-not-exist.sh" \
  bash "$PROJ/scripts/eval-classifier-invoke.sh" 999 999 \
  > "$OUT_FILE" 2> "$ERR_FILE"
rc=$?
if [ "$rc" -ne 3 ]; then
  fail_msg "expected exit 3 on missing classifier, got $rc"
elif ! grep -q "classifier-not-found" "$ERR_FILE"; then
  fail_msg "expected stderr 'classifier-not-found'; got: $(cat "$ERR_FILE")"
else
  pass_msg "missing classifier -> exit 3, classifier-not-found marker"
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
