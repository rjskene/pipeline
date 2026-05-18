#!/bin/bash
# Tests for the doctor `base_branch_enforcement` check, load-bearing hook
# drift escalation, and gh >= 2.0 minimum-version sub-check (#295).
#
# Six fixtures:
#   (a) plugin-registered + hook file present                  → pass
#   (b) consumer-registered + hook file present                → pass
#   (c) hook file absent                                       → fail
#   (d) hook file present but unregistered (no Bash matcher)   → fail
#   (e) consumer copy of enforce-base-branch.py drifted        → consumer_drift fail (load-bearing)
#   (f) gh version < 2.0                                       → gh_installed fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

if [ ! -f "$DOCTOR" ]; then
  echo "FAIL: $DOCTOR does not exist"
  exit 1
fi

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ----- Shared shim bin for gh (used by most cases except case f) ------------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  auth)    [ "$2" = "status" ] && exit 0 ;;
  repo)    [ "$2" = "view" ] && exit 0 ;;
  label)   [ "$2" = "list" ] && { echo '[]'; exit 0; } ;;
  version) echo "gh version 2.40.0 (2024-01-01)"; echo "https://github.com/cli/cli/releases/tag/v2.40.0"; exit 0 ;;
esac
exit 0
GH
chmod +x "$TMP/bin/gh"

# Fresh fixture: a fake consumer-project directory plus a fake plugin root.
#   $root/proj/        — consumer project (git init'd, has pipeline.config)
#   $root/plugin/      — fake CLAUDE_PLUGIN_ROOT
# Caller is responsible for materialising hook files and manifest contents
# under $root/plugin/.
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.claude/scripts" "$root/proj/.claude/hooks" "$root/proj/.claude/agents"
  mkdir -p "$root/plugin/scripts" "$root/plugin/hooks" "$root/plugin/agents"
  mkdir -p "$root/plugin/.claude-plugin"
  ( cd "$root/proj" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git commit --allow-empty -q -m init \
      && (git branch -q staging 2>/dev/null || git checkout -q -b staging) ) >/dev/null 2>&1
  cat > "$root/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
  echo "$root"
}

# Write a plugin manifest that registers enforce-base-branch.py in a
# PreToolUse Bash matcher.
write_plugin_manifest_with_hook() {
  local plugin="$1"
  cat > "$plugin/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "pipeline",
  "version": "0.8.0",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/enforce-base-branch.py"
          }
        ]
      }
    ]
  }
}
JSON
}

# Write a plugin manifest that does NOT register enforce-base-branch.py.
write_plugin_manifest_empty() {
  local plugin="$1"
  cat > "$plugin/.claude-plugin/plugin.json" <<'JSON'
{
  "name": "pipeline",
  "version": "0.8.0",
  "hooks": {
    "PreToolUse": []
  }
}
JSON
}

write_consumer_settings_with_hook() {
  local proj="$1"
  cat > "$proj/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/enforce-base-branch.py"
          }
        ]
      }
    ]
  }
}
JSON
}

# ---------------------------------------------------------------------------
# Case (a): plugin-registered + hook-file-present → pass
# ---------------------------------------------------------------------------
echo "Case a: plugin-registered + hook-file-present"
ROOT=$(fresh_fx fx-a-plugin)
write_plugin_manifest_with_hook "$ROOT/plugin"
echo "# enforce-base-branch.py" > "$ROOT/plugin/hooks/enforce-base-branch.py"

(
  cd "$ROOT/proj"
  PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: base_branch_enforcement status=pass' <<<"$out"; then
  pass_msg "(a) plugin-registered → status=pass"
else
  fail_msg "(a) expected base_branch_enforcement=pass"
  echo "$out" | grep -E 'base_branch_enforcement' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Case (b): consumer-registered + hook-file-present → pass
# ---------------------------------------------------------------------------
echo "Case b: consumer-registered + hook-file-present"
ROOT=$(fresh_fx fx-b-consumer)
write_plugin_manifest_empty "$ROOT/plugin"
echo "# enforce-base-branch.py" > "$ROOT/plugin/hooks/enforce-base-branch.py"
write_consumer_settings_with_hook "$ROOT/proj"

(
  cd "$ROOT/proj"
  PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: base_branch_enforcement status=pass' <<<"$out"; then
  pass_msg "(b) consumer-registered → status=pass"
else
  fail_msg "(b) expected base_branch_enforcement=pass"
  echo "$out" | grep -E 'base_branch_enforcement' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Case (c): hook file absent → fail
# ---------------------------------------------------------------------------
echo "Case c: hook file absent"
ROOT=$(fresh_fx fx-c-absent)
write_plugin_manifest_with_hook "$ROOT/plugin"
# DO NOT create hooks/enforce-base-branch.py

(
  cd "$ROOT/proj"
  PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: base_branch_enforcement status=fail.*enforce-base-branch\.py not present on disk' <<<"$out"; then
  pass_msg "(c) hook file absent → status=fail with right detail"
else
  fail_msg "(c) expected status=fail mentioning 'enforce-base-branch.py not present on disk'"
  echo "$out" | grep -E 'base_branch_enforcement' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Case (d): hook file present, neither plugin- nor consumer-registered → fail
# ---------------------------------------------------------------------------
echo "Case d: hook file present but unregistered"
ROOT=$(fresh_fx fx-d-unregistered)
write_plugin_manifest_empty "$ROOT/plugin"
echo "# enforce-base-branch.py" > "$ROOT/plugin/hooks/enforce-base-branch.py"
# No consumer settings either.

(
  cd "$ROOT/proj"
  PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: base_branch_enforcement status=fail.*exists but no PreToolUse Bash matcher invokes it' <<<"$out"; then
  pass_msg "(d) unregistered → status=fail with right detail"
else
  fail_msg "(d) expected status=fail mentioning 'exists but no PreToolUse Bash matcher invokes it'"
  echo "$out" | grep -E 'base_branch_enforcement' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Case (e): consumer copy of enforce-base-branch.py drifted → consumer_drift fail
# Load-bearing escalation: the basename is on LOAD_BEARING_HOOKS, so drift
# promotes from warn (bucket B/C/A/E) to fail.
# ---------------------------------------------------------------------------
echo "Case e: load-bearing hook drift → consumer_drift FAIL"
ROOT=$(fresh_fx fx-e-drift)
write_plugin_manifest_with_hook "$ROOT/plugin"
# Plugin counterpart reads pipeline.config; local has hardcoded literal
# that matches runtime PIPELINE_REPO (bucket B, not B.bug — but the
# load-bearing escalation should still promote to fail).
cat > "$ROOT/plugin/hooks/enforce-base-branch.py" <<'F'
from _pipeline_config import PIPELINE_REPO
print(PIPELINE_REPO)
F
cat > "$ROOT/proj/.claude/hooks/enforce-base-branch.py" <<'F'
PIPELINE_REPO = "owner/repo-correct"
print(PIPELINE_REPO)
F

(
  cd "$ROOT/proj"
  PATH="$TMP/bin:$PATH" \
    CLAUDE_PLUGIN_ROOT="$ROOT/plugin" \
    PIPELINE_PLUGIN_CACHE_DIR="$TMP/no-such-cache" \
    PIPELINE_INSTALLED_PLUGINS_FILE="$TMP/no-such-installed.json" \
    bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: consumer_drift status=fail' <<<"$out"; then
  pass_msg "(e) load-bearing drift → consumer_drift=fail"
else
  fail_msg "(e) expected consumer_drift=fail for load-bearing hook"
  echo "$out" | grep -E 'consumer_drift|enforce-base-branch' | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
# Case (f): gh version < 2.0 → gh_installed fail
# Replace gh shim so `gh version` reports 1.14.0.
# ---------------------------------------------------------------------------
echo "Case f: gh version below 2.0 floor"
ROOT=$(fresh_fx fx-f-oldgh)
write_plugin_manifest_with_hook "$ROOT/plugin"
echo "# enforce-base-branch.py" > "$ROOT/plugin/hooks/enforce-base-branch.py"

# Per-case bin dir with an old-gh shim.
mkdir -p "$TMP/bin-oldgh"
cat > "$TMP/bin-oldgh/gh" <<'GH'
#!/bin/bash
case "$1" in
  auth)    [ "$2" = "status" ] && exit 0 ;;
  repo)    [ "$2" = "view" ] && exit 0 ;;
  label)   [ "$2" = "list" ] && { echo '[]'; exit 0; } ;;
  version) echo "gh version 1.14.0 (2021-08-22)"; echo "https://github.com/cli/cli/releases/tag/v1.14.0"; exit 0 ;;
esac
exit 0
GH
chmod +x "$TMP/bin-oldgh/gh"

(
  cd "$ROOT/proj"
  PATH="$TMP/bin-oldgh:$PATH" CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR"
) > "$ROOT/out" 2>&1 || true
out="$(cat "$ROOT/out")"
if grep -qE '^CHECK: gh_installed status=fail.*below the 2\.0 floor' <<<"$out"; then
  pass_msg "(f) gh<2.0 → gh_installed=fail with 'below the 2.0 floor'"
else
  fail_msg "(f) expected gh_installed=fail mentioning 'below the 2.0 floor'"
  echo "$out" | grep -E 'gh_installed' | sed 's/^/    /' || true
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
