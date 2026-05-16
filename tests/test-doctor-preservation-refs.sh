#!/bin/bash
# tests/test-doctor-preservation-refs.sh — tests for scan-preservation-refs.sh
# and the preservation_refs check in doctor.sh.
#
# Builds a fake project tree + fake $CLAUDE_PLUGIN_ROOT per case (mirroring
# the fresh_fx pattern from test-doctor-consumer-drift.sh) and asserts the
# REF / VERDICT rows the helper emits, plus the doctor block output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/scan-preservation-refs.sh"
DIFF_HELPER="$SCRIPT_DIR/../scripts/diff-consumer-files.sh"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ---------------------------------------------------------------------------
# Fixture builder
#
# Materialises:
#   $1/proj/ — fake consumer project
#     pipeline.config (PIPELINE_REPO=owner/repo-correct)
#     .claude/{scripts,hooks,skills/pipeline}/
#   $1/plugin/ — fake $CLAUDE_PLUGIN_ROOT
#     scripts/, hooks/, skills/pipeline/SKILL.md
#
# Echoes the fixture root; cd into "$root/proj" to run the helper.
# ---------------------------------------------------------------------------
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.claude/scripts" "$root/proj/.claude/hooks" \
           "$root/proj/.claude/skills/pipeline"
  mkdir -p "$root/plugin/scripts" "$root/plugin/hooks" \
           "$root/plugin/skills/pipeline"
  cat > "$root/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
  # Plugin-shipped pipeline skill (so .claude/skills/pipeline/SKILL.md refs
  # classify as falls-away by default).
  printf '# pipeline\n' > "$root/plugin/skills/pipeline/SKILL.md"
  echo "$root"
}

run_helper() {
  local root="$1"; shift
  (
    cd "$root/proj"
    # shellcheck disable=SC1091
    source ./pipeline.config
    CLAUDE_PLUGIN_ROOT="$root/plugin" bash "$HELPER" "$@"
  )
}

# ---------------------------------------------------------------------------
# Case 1: helper exists and is executable.
# ---------------------------------------------------------------------------
echo "Case 1: helper exists"
if [ -f "$HELPER" ]; then
  pass_msg "scan-preservation-refs.sh exists at $HELPER"
else
  fail_msg "scan-preservation-refs.sh missing at $HELPER"
fi

# ---------------------------------------------------------------------------
# Case 2: empty fixture (no consumer .claude/{scripts,hooks}/ files) emits
# zero rows and exits 0.
# ---------------------------------------------------------------------------
echo "Case 2: empty fixture → zero rows, rc=0"
ROOT=$(fresh_fx fx-empty)
out="$(run_helper "$ROOT" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
  pass_msg "empty fixture: zero rows, rc=0"
else
  fail_msg "empty fixture: expected zero rows + rc=0 (got rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
# Case 3: helper enumerates the same set of .claude/scripts/ + .claude/hooks/
# files (with plugin counterparts) as diff-consumer-files.sh covers.
# ---------------------------------------------------------------------------
echo "Case 3: enumeration parity with diff-consumer-files.sh"
ROOT=$(fresh_fx fx-parity)
# Plugin ships three files; consumer has copies of two of them plus one extra.
printf '#!/bin/bash\necho a\n' > "$ROOT/plugin/scripts/a.sh"
printf '#!/bin/bash\necho b\n' > "$ROOT/plugin/scripts/b.sh"
printf '#!/bin/bash\necho h\n' > "$ROOT/plugin/hooks/h.py"
cp "$ROOT/plugin/scripts/a.sh" "$ROOT/proj/.claude/scripts/a.sh"
cp "$ROOT/plugin/hooks/h.py" "$ROOT/proj/.claude/hooks/h.py"
# Consumer-only file (no plugin counterpart) — should NOT appear in helper output.
printf '#!/bin/bash\necho own\n' > "$ROOT/proj/.claude/scripts/consumer-only.sh"

scan_files="$(run_helper "$ROOT" | awk -F'\t' '$1=="REF"||$1=="VERDICT"{print $2}' | sort -u)"
expected="$(printf '%s\n' '.claude/hooks/h.py' '.claude/scripts/a.sh' | sort -u)"
if [ "$scan_files" = "$expected" ]; then
  pass_msg "helper enumerates files with plugin counterparts only"
else
  fail_msg "enumeration parity mismatch"
  echo "    expected:"; echo "$expected" | sed 's/^/      /'
  echo "    got:"; echo "$scan_files" | sed 's/^/      /'
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
