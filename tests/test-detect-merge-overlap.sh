#!/bin/bash
# Test the pre-merge pairwise file-overlap detection helper:
#   - detect_merge_overlap prints OVERLAP <a> <b> <count> + indented shared paths
#   - emits nothing for disjoint pairs (empty-output contract)
#   - recommend_merge_order ranks fewest-overlap-first, PR-number tiebreak
# Mirrors the gh-shim-via-PATH pattern in tests/test-auto-merge-greenlight.sh.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="${ROOT}/scripts/detect-merge-overlap.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: ${HELPER} does not exist"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- gh shim: dispatch on the PR number embedded in the `pr view` argv ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
ALL_ARGS="$*"
# Scan positional args for the PR number (follows `view`) and the --jq filter,
# emulating gh's own --jq post-processing so the helper sees the same output
# real `gh pr view --json files --jq '.files[].path'` would produce.
PR=""
JQ=""
prev=""
for a in "$@"; do
  case "$prev" in
    view) PR="$a" ;;
    --jq) JQ="$a" ;;
  esac
  prev="$a"
done
case "$PR" in
  101) JSON='{"files":[{"path":"a.md"},{"path":"b.md"}]}' ;;
  102) JSON='{"files":[{"path":"b.md"},{"path":"c.md"}]}' ;;
  103) JSON='{"files":[{"path":"d.md"}]}' ;;
  104) JSON='{"files":[{"path":"e.md"}]}' ;;
  105) JSON='{"files":[{"path":"[id].tsx"},{"path":"x.md"}]}' ;;
  106) JSON='{"files":[{"path":"[id].tsx"},{"path":"y.md"}]}' ;;
  *)
    echo "[gh shim] unhandled: $ALL_ARGS" >&2
    exit 1
    ;;
esac
if [ -n "$JQ" ]; then
  printf '%s' "$JSON" | jq -r "$JQ"
else
  printf '%s\n' "$JSON"
fi
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="test/repo"

# shellcheck disable=SC1090
source "$HELPER"

FAILED=0
check() {
  local name="$1" cond="$2"
  if [ "$cond" = "ok" ]; then
    echo "  PASS: $name"
  else
    echo "  FAIL: $name"
    FAILED=$((FAILED+1))
  fi
}

echo "=== detect_merge_overlap: overlapping pair reported ==="
OUT=$(detect_merge_overlap 101 102 103)
case "$OUT" in
  *"OVERLAP 101 102 1"*) check "reports OVERLAP 101 102 1" ok ;;
  *) check "reports OVERLAP 101 102 1" "no" ;;
esac
case "$OUT" in
  *"
  b.md"*) check "lists shared path b.md (indented)" ok ;;
  *) check "lists shared path b.md (indented)" "no" ;;
esac
case "$OUT" in
  *"OVERLAP 101 103"*) check "no spurious OVERLAP 101 103" "no" ;;
  *) check "no spurious OVERLAP 101 103" ok ;;
esac
case "$OUT" in
  *"OVERLAP 102 103"*) check "no spurious OVERLAP 102 103" "no" ;;
  *) check "no spurious OVERLAP 102 103" ok ;;
esac

echo "=== detect_merge_overlap: disjoint pair emits nothing ==="
# 103 (d.md) and 104 (e.md) share no files -> output must be exactly empty.
OUT=$(detect_merge_overlap 103 104)
if [ -z "$OUT" ]; then
  check "disjoint pair 103/104 -> empty output" ok
else
  check "disjoint pair 103/104 -> empty output" "no"
fi

echo "=== detect_merge_overlap: shared path with glob metacharacters printed literally ==="
# Next.js-style dynamic-route paths (e.g. [id].tsx) are legal git paths. The
# shared-path list must NOT glob-expand against the cwd. Run from a dir holding
# a decoy "i.tsx" that the bracket pattern [id].tsx would match if expanded.
GLOB_DIR="$TMP/globtest"
mkdir -p "$GLOB_DIR"
: > "$GLOB_DIR/i.tsx"
OUT=$(cd "$GLOB_DIR" && detect_merge_overlap 105 106)
case "$OUT" in
  *"  [id].tsx"*) check "shared glob-metachar path printed literally" ok ;;
  *) echo "    got: [$OUT]"; check "shared glob-metachar path printed literally" "no" ;;
esac

echo "=== recommend_merge_order: fewest-overlap-first, PR-number tiebreak ==="
# 101<->102 overlap on b.md (1 each); 103, 104 disjoint (0 each).
# Expected: 103, 104 (0 overlaps, asc PR num), then 101, 102 (1 overlap, asc).
ORDER=$(recommend_merge_order 101 102 103 104)
EXPECTED_ORDER=$(printf '103\n104\n101\n102')
if [ "$ORDER" = "$EXPECTED_ORDER" ]; then
  check "recommend_merge_order ranks 103 104 101 102" ok
else
  echo "    got: [$ORDER]"
  check "recommend_merge_order ranks 103 104 101 102" "no"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "FAILED: $FAILED check(s)"
  exit 1
fi
echo "OK: all checks passed"
