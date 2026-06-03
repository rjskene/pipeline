#!/bin/bash
set -uo pipefail

# Tests for issue #917 — doctor's stdin_read_timeout_guards check + the
# `--fix stdin-guards` remediation.
#
# The check scans consumer .claude/hooks/ for stdin reads that lack a timeout
# guard (Python: json.load(sys.stdin)/sys.stdin.read() with no
# read_event_stdin/signal.alarm/select.select nearby; bash: $(cat) capture with
# no timeout). Severity is WARN (consumer-owned files; never FAIL — mirrors
# settings_residual). `--fix stdin-guards` re-syncs plugin-shipped Python dups
# from the plugin and in-place timeout-wraps consumer-authored bash hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — make all early gh checks pass.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") echo '{"name":"repo"}'; exit 0 ;;
  "label list") exit 0 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# Build a plugin root that ships a GUARDED restrict_paths.py (the re-sync source
# for --fix stdin-guards) plus the other minimal plugin files.
PLUGIN_ROOT="$TMP/plugin-root"
mk_plugin_root() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/skills/classify-issue" "$root/hooks" "$root/scripts" "$root/agents" "$root/.claude-plugin"
  touch "$root/skills/classify-issue/SKILL.md"
  touch "$root/scripts/doctor.sh"
  touch "$root/agents/tdd-implementer.md"
  echo '{}' > "$root/.claude-plugin/plugin.json"
  # Guarded plugin copy of restrict_paths.py — what --fix re-syncs.
  cat > "$root/hooks/restrict_paths.py" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from subagent_log_utils import read_event_stdin  # noqa: E402
data = read_event_stdin()
PY
  touch "$root/hooks/subagent_log_utils.py"
}
mk_plugin_root "$PLUGIN_ROOT"

# fresh_fx: a consumer fixture with git + a valid pipeline.config.
fresh_fx() {
  local name="$1"
  local fx="$TMP/$name"
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
  cat > "$fx/pipeline.config" <<CFG
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

run_doctor() {
  local fx="$1" plugin_root="$2"; shift 2
  (
    cd "$fx"
    PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$plugin_root" "$@" \
      bash "$HELPER" </dev/null
  ) >"$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

# Extract the status= token for the stdin_read_timeout_guards CHECK line.
guard_status() {
  grep -E '^CHECK: stdin_read_timeout_guards ' "$1" \
    | sed -nE 's/.*status=([a-z]+).*/\1/p' | head -1
}

# ---------------------------------------------------------------------------
# Case 1: unguarded consumer hooks (1 python + 1 bash) → WARN naming both.
# ---------------------------------------------------------------------------
echo "Case 1: unguarded consumer hooks → status=warn naming both"
FX=$(fresh_fx fx-unguarded)
mkdir -p "$FX/.claude/hooks"
cat > "$FX/.claude/hooks/restrict_paths.py" <<'PY'
import json, sys
data = json.load(sys.stdin)
PY
cat > "$FX/.claude/hooks/custom-logger.sh" <<'SH'
#!/bin/bash
INPUT=$(cat)
echo "$INPUT"
SH
run_doctor "$FX" "$PLUGIN_ROOT"
st="$(guard_status "$FX/out")"
[ "$st" = "warn" ] && pass_msg "case1: status=warn" || { fail_msg "case1: status='$st' (want warn)"; grep -i stdin "$FX/out" | sed 's/^/    /'; }
if grep -q "restrict_paths.py" "$FX/out" && grep -q "custom-logger.sh" "$FX/out"; then
  pass_msg "case1: both unguarded files named"
else
  fail_msg "case1: not both files named"
  grep -i stdin "$FX/out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 2: guarded consumer hooks → status=pass.
# ---------------------------------------------------------------------------
echo "Case 2: guarded consumer hooks → status=pass"
FX=$(fresh_fx fx-guarded)
mkdir -p "$FX/.claude/hooks"
cat > "$FX/.claude/hooks/restrict_paths.py" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from subagent_log_utils import read_event_stdin  # noqa: E402
data = read_event_stdin()
PY
cat > "$FX/.claude/hooks/custom-logger.sh" <<'SH'
#!/bin/bash
INPUT=$(timeout 5 cat || true)
echo "$INPUT"
SH
run_doctor "$FX" "$PLUGIN_ROOT"
st="$(guard_status "$FX/out")"
[ "$st" = "pass" ] && pass_msg "case2: status=pass" || { fail_msg "case2: status='$st' (want pass)"; grep -i stdin "$FX/out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: no consumer .claude/hooks/ → status=pass (nothing to scan).
# ---------------------------------------------------------------------------
echo "Case 3: no consumer hooks dir → status=pass"
FX=$(fresh_fx fx-none)
run_doctor "$FX" "$PLUGIN_ROOT"
st="$(guard_status "$FX/out")"
[ "$st" = "pass" ] && pass_msg "case3: status=pass" || { fail_msg "case3: status='$st' (want pass)"; grep -i stdin "$FX/out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 4: the check NEVER fails the doctor run on its own (WARN-only). A fixture
# whose only finding is unguarded hooks must not flip doctor's exit to 1 because
# of this check. (Other checks may still fail in the fixture env, so we only
# assert the check's severity stays warn, never the run exit.)
# ---------------------------------------------------------------------------
echo "Case 4: WARN-only severity (never fail the run on its own)"
FX=$(fresh_fx fx-warnonly)
mkdir -p "$FX/.claude/hooks"
cat > "$FX/.claude/hooks/x.py" <<'PY'
import json, sys
json.load(sys.stdin)
PY
run_doctor "$FX" "$PLUGIN_ROOT"
st="$(guard_status "$FX/out")"
[ "$st" = "warn" ] && pass_msg "case4: severity warn (not fail)" || { fail_msg "case4: status='$st' (want warn)"; grep -i stdin "$FX/out" | sed 's/^/    /'; }

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
