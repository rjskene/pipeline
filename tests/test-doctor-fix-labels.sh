#!/bin/bash
set -uo pipefail

# Tests for `scripts/doctor.sh --fix labels` — the one mutating path. Uses a
# PATH-shimmed gh that records every `gh label create` call to $SHIM_LOG.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — only `label create` matters here. Every call records a fully
# normalized log line "<name>|<color>|<description>" so assertions can parse it.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "label create")
    NAME="$3"; shift 3
    COLOR=""; DESC=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --color) COLOR="$2"; shift 2 ;;
        --description) DESC="$2"; shift 2 ;;
        --force|--repo) shift ;;
        *) shift ;;
      esac
    done
    # --repo had its value swallowed above; that's fine — we don't assert on it.
    echo "$NAME|$COLOR|$DESC" >> "${SHIM_LOG:-/dev/null}"
    exit 0 ;;
  *)
    exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

mk_fixture() {
  local name="$1"
  local fx="$TMP/$name"
  rm -rf "$fx"; mkdir -p "$fx"
  cat > "$fx/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

run_fix() {
  local fx="$1"; shift
  (
    cd "$fx"
    SHIM_LOG="$fx/shim.log" env "$@" bash "$HELPER" --fix labels
  ) >"$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

# ---------------------------------------------------------------------------
# Case A: all 14 canonical labels are seeded with exact color/description.
# ---------------------------------------------------------------------------
echo "Case A: seeds all 14 labels"
FX=$(mk_fixture fx-a)
run_fix "$FX"
rc="$(cat "$FX/rc")"
[ "$rc" = "0" ] && pass_msg "A: exit 0" || { fail_msg "A: exit $rc"; cat "$FX/out" | sed 's/^/    /'; }
count=$(wc -l < "$FX/shim.log" | tr -d ' ')
[ "$count" = "14" ] && pass_msg "A: 14 label create calls" || fail_msg "A: got $count label create calls"

# Canonical (name, color, description) — must match doctor.sh LABEL_TABLE and README.
expected=(
  "plan-pending|C2E0C6|Plan posted, awaiting review"
  "plan-reviewed|BFD4F2|Plan evaluated"
  "plan-approved|0E8A16|Approved, ready for execution"
  "in-progress|FBCA04|Currently being implemented"
  "pr-open|1D76DB|PR open, awaiting review"
  "merged|6F42C1|PR merged, ready for cleanup"
  "docs-only|D4C5F9|Documentation-only change — no implementation"
  "multi-task|5319e7|Issue too large for one PR; requires decomposition into sub-issues"
  "quick-fix|0E8A16|Quick-fix path — inline TDD, single failing test"
  "excluded|E4E669|Excluded from pipeline"
  "later|D4C5F9|Deferred"
  "human|F9D0C4|Needs human in the loop"
  "brainstorm|FEF2C0|Non-actionable discussion/exploration"
  "needs-browser|1F77B4|Gates Playwright MCP attachment and visual-proof-from-plan sub-skill"
)
for row in "${expected[@]}"; do
  if grep -Fxq "$row" "$FX/shim.log"; then
    pass_msg "A: canonical row present: ${row%%|*}"
  else
    fail_msg "A: missing canonical row: $row"
    echo "    shim log:"; sed 's/^/      /' "$FX/shim.log"
  fi
done

# ---------------------------------------------------------------------------
# Case B: idempotency — second run produces identical end-state (same 10 calls).
# ---------------------------------------------------------------------------
echo "Case B: second run is idempotent"
FX=$(mk_fixture fx-b)
run_fix "$FX"
first="$(sort "$FX/shim.log")"
: > "$FX/shim.log"
run_fix "$FX"
second="$(sort "$FX/shim.log")"
[ "$first" = "$second" ] && pass_msg "B: identical end-state on re-run" \
  || { fail_msg "B: re-run differs"; diff <(echo "$first") <(echo "$second") | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case D: PIPELINE_LABELS_* overrides change the seeded names.
# ---------------------------------------------------------------------------
echo "Case D: PIPELINE_LABELS_* overrides honored"
FX=$(mk_fixture fx-d)
cat > "$FX/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_LABELS_EXCLUDED="skip"
PIPELINE_LABELS_LATER="defer"
PIPELINE_LABELS_HUMAN="needs-human"
PIPELINE_LABELS_BRAINSTORM="ideation"
CFG
run_fix "$FX"
for want_name in skip defer needs-human ideation; do
  if grep -E "^$want_name\|" "$FX/shim.log" >/dev/null; then
    pass_msg "D: override present: $want_name"
  else
    fail_msg "D: missing override: $want_name"
  fi
done
for not_want in excluded later human brainstorm; do
  if grep -E "^$not_want\|" "$FX/shim.log" >/dev/null; then
    fail_msg "D: default leaked despite override: $not_want"
  else
    pass_msg "D: default suppressed: $not_want"
  fi
done

# ---------------------------------------------------------------------------
# Case E: missing pipeline.config → non-zero exit, doesn't call gh.
# ---------------------------------------------------------------------------
echo "Case E: errors when pipeline.config missing"
FX="$TMP/fx-e"; mkdir -p "$FX"
run_fix "$FX"
rc="$(cat "$FX/rc")"
[ "$rc" != "0" ] && pass_msg "E: non-zero exit" || fail_msg "E: exit was 0"
[ ! -s "$FX/shim.log" ] && pass_msg "E: no gh calls made" || { fail_msg "E: gh was called"; sed 's/^/    /' "$FX/shim.log"; }

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
