#!/bin/bash
# Regression for the doctor `jq_installed` pre-flight check (#270).
# jq is a hard runtime dependency for auto-merge-gate.sh, list-release-prs.sh,
# and parse-tracker-children.sh — doctor must surface a missing jq before
# downstream checks emit confusing cascade failures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

if [ ! -f "$HELPER" ]; then
  echo "FAIL: $HELPER does not exist"
  exit 1
fi

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Symlink standard utils (NOT jq) so a sandboxed PATH=$TMP/bin still works.
# Doctor shells out to a wide range of utilities — include bash/python3 and
# the common text-processing toolkit. jq is deliberately omitted so a
# system-installed jq cannot leak through.
SYS1=/usr/bin
SYS2=/bin
for util in bash sh grep head tail awk sed cat git basename dirname find sort uniq wc tr cut printf realpath stat ls rm mkdir chmod touch tee python3 env xargs mktemp; do
  if [ -x "$SYS1/$util" ]; then
    ln -sf "$SYS1/$util" "$TMP/bin/$util"
  elif [ -x "$SYS2/$util" ]; then
    ln -sf "$SYS2/$util" "$TMP/bin/$util"
  fi
done

# gh shim — self-contained (no jq dependency). Used by case B and the
# downstream check stubs that run after the jq pre-flight.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") exit 0 ;;
  "label list") printf '%s\n' "${LABELS_JSON:-[]}" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# Minimal fixture project — same shape as test-doctor-script.sh's fresh_fx.
mk_fixture() {
  local fx="$1"
  rm -rf "$fx"
  mkdir -p "$fx"
  (
    cd "$fx"
    git init -q
    git config user.email t@t
    git config user.name t
    git commit --allow-empty -q -m init
    git branch -q staging 2>/dev/null || git checkout -q -b staging
  ) >/dev/null 2>&1
  cat > "$fx/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
}

# ---------------------------------------------------------------------------
# Case 1: jq is masked off PATH — doctor must emit CHECK: jq_installed status=fail
#         AND exit non-zero (fail-fast, like gh_installed).
# ---------------------------------------------------------------------------
echo "Case 1: jq missing"
FX="$TMP/fx-no-jq"
mk_fixture "$FX"

set +e
(
  cd "$FX"
  # Precondition assertion: jq must not be findable in this sandboxed PATH.
  export PATH="$TMP/bin"
  if command -v jq >/dev/null 2>&1; then
    echo "[harness] precondition broken: jq resolvable as $(command -v jq)" >&2
    exit 88
  fi
  export CLAUDE_PLUGIN_ROOT="$FX"
  bash "$HELPER"
) > "$FX/out" 2> "$FX/err"
rc=$?
set -e

out="$(cat "$FX/out")"
err="$(cat "$FX/err")"

if [ "$rc" -eq 88 ]; then
  fail_msg "case-1: precondition broken — $err"
else
  if grep -qE '^CHECK: jq_installed status=fail' <<<"$out"; then
    pass_msg "no-jq: emits CHECK: jq_installed status=fail"
  else
    fail_msg "no-jq: missing 'CHECK: jq_installed status=fail' line"
    echo "$out" | sed 's/^/    /'
  fi
  if [ "$rc" -ne 0 ]; then
    pass_msg "no-jq: non-zero exit (got $rc)"
  else
    fail_msg "no-jq: exit was 0 — doctor must fail-fast on missing jq"
  fi
fi

# ---------------------------------------------------------------------------
# Case 2: jq present — doctor must emit CHECK: jq_installed status=pass.
# ---------------------------------------------------------------------------
echo "Case 2: jq present"
FX="$TMP/fx-with-jq"
mk_fixture "$FX"

# Drop a trivial jq stub into the sandboxed bin/ so `command -v jq` succeeds.
# Doesn't need real jq behavior — the pass case never invokes it for parsing.
cat > "$TMP/bin/jq" <<'JQ'
#!/bin/bash
# Trivial jq stub for the doctor jq_installed=pass case. Real jq isn't
# needed because doctor short-circuits to summary before any --jq query.
exit 0
JQ
chmod +x "$TMP/bin/jq"

set +e
(
  cd "$FX"
  export PATH="$TMP/bin"
  if ! command -v jq >/dev/null 2>&1; then
    echo "[harness] case-2 setup broken: jq not resolvable" >&2
    exit 88
  fi
  export CLAUDE_PLUGIN_ROOT="$FX"
  bash "$HELPER"
) > "$FX/out" 2> "$FX/err"
rc=$?
set -e

out="$(cat "$FX/out")"
err="$(cat "$FX/err")"

if [ "$rc" -eq 88 ]; then
  fail_msg "case-2: setup broken — $err"
else
  if grep -qE '^CHECK: jq_installed status=pass' <<<"$out"; then
    pass_msg "with-jq: emits CHECK: jq_installed status=pass"
  else
    fail_msg "with-jq: missing 'CHECK: jq_installed status=pass' line"
    echo "$out" | sed 's/^/    /'
  fi
fi

# Clean up the jq stub so later test invocations don't see it.
rm -f "$TMP/bin/jq"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
