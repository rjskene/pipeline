#!/bin/bash
set -uo pipefail

# Tests for the settings_residual check in scripts/doctor.sh.
# Scans $PROJECT_ROOT/.claude/settings.json for pipeline-owned hook command basenames
# (sourced from _advisory-text.sh) and emits a warn per pipeline hook entry found.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"
ADVISORY="$SCRIPT_DIR/../scripts/_advisory-text.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")   exit 0 ;;
  "label list")
    JQ=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "--jq" ]; then JQ="$2"; shift 2; else shift; fi
    done
    if [ "$JQ" = ".[].name" ]; then
      python3 -c 'import json,os,sys
data=json.loads(os.environ.get("LABELS_JSON","[]"))
for d in data: print(d["name"])'
    else
      printf '%s\n' "${LABELS_JSON:-[]}"
    fi
    ;;
  "label create") exit 0 ;;
  *) exit 99 ;;
esac
GH
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/claude" <<'CLAUDE'
#!/bin/bash
case "$1 $2" in
  "plugin list") printf '%s\n' "${CLAUDE_PLUGIN_LIST:-claude-pipeline 0.4.0}" ;;
  *) exit 0 ;;
esac
CLAUDE
chmod +x "$TMP/bin/claude"

ALL_LABELS_JSON='[
  {"name":"plan-pending"},{"name":"plan-reviewed"},{"name":"plan-approved"},
  {"name":"in-progress"},{"name":"pr-open"},{"name":"merged"},
  {"name":"excluded"},{"name":"later"},{"name":"human"},{"name":"brainstorm"}
]'

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
  cat > "$fx/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

run_helper() {
  local fx="$1"; shift
  (
    cd "$fx"
    PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$fx" "$@" bash "$HELPER"
  ) > "$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

export PATH="$TMP/bin:$PATH"

# Pre-fetch the advisory text for the three "common" basenames (load helper directly).
# shellcheck disable=SC1090
source "$ADVISORY"
ADV_RESTRICT_PATHS="$(advisory_for_hook restrict_paths.py)"
ADV_LOG_TOOL_USE="$(advisory_for_hook log-tool-use.sh)"
ADV_LOG_SUBAGENT="$(advisory_for_hook log_subagent.py)"

# ---------------------------------------------------------------------------
# Case 1: no .claude/settings.json → pass
# ---------------------------------------------------------------------------
echo "Case 1: no .claude/settings.json"
FX=$(fresh_fx fx-no-settings)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"
grep -qE '^CHECK: settings_residual status=pass detail=no settings\.json$' <<<"$out" \
  && pass_msg "no-settings: pass" \
  || { fail_msg "no-settings: missing pass line"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 2: only non-pipeline hook entries → pass
# ---------------------------------------------------------------------------
echo "Case 2: only non-pipeline hook entries"
FX=$(fresh_fx fx-clean-settings)
mkdir -p "$FX/.claude"
cat > "$FX/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"command": "/usr/local/bin/some-other-hook.sh"}]},
      {"hooks": [{"command": "python3 .claude/custom/my-hook.py"}]}
    ]
  }
}
JSON
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"
grep -qE '^CHECK: settings_residual status=pass detail=no pipeline hook entries$' <<<"$out" \
  && pass_msg "clean-settings: pass" \
  || { fail_msg "clean-settings: missing pass line"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: all three common pipeline entries → warn, plural, annotations + summary
# ---------------------------------------------------------------------------
echo "Case 3: three pipeline hook entries"
FX=$(fresh_fx fx-three-entries)
mkdir -p "$FX/.claude"
cat > "$FX/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"command": "python3 .claude/hooks/restrict_paths.py"}]}
    ],
    "PostToolUse": [
      {"hooks": [{"command": "bash .claude/hooks/log-tool-use.sh"}]},
      {"hooks": [{"command": "python3 .claude/hooks/log_subagent.py"}]}
    ]
  }
}
JSON
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"

grep -qE '^CHECK: settings_residual status=warn detail=3 pipeline hook entries in \.claude/settings\.json$' <<<"$out" \
  && pass_msg "three-entries: warn with plural detail" \
  || { fail_msg "three-entries: missing warn line"; echo "$out" | sed 's/^/    /'; }

grep -qF "  - .claude/hooks/restrict_paths.py" <<<"$out" \
  && pass_msg "three-entries: restrict_paths.py indented entry" \
  || fail_msg "three-entries: missing restrict_paths.py entry"
grep -qF "      $ADV_RESTRICT_PATHS" <<<"$out" \
  && pass_msg "three-entries: restrict_paths.py advisory line" \
  || { fail_msg "three-entries: missing restrict_paths.py advisory"; echo "$out" | sed 's/^/    /'; }

grep -qF "  - .claude/hooks/log-tool-use.sh" <<<"$out" \
  && pass_msg "three-entries: log-tool-use.sh indented entry" \
  || fail_msg "three-entries: missing log-tool-use.sh entry"
grep -qF "      $ADV_LOG_TOOL_USE" <<<"$out" \
  && pass_msg "three-entries: log-tool-use.sh advisory line" \
  || fail_msg "three-entries: missing log-tool-use.sh advisory"

grep -qF "  - .claude/hooks/log_subagent.py" <<<"$out" \
  && pass_msg "three-entries: log_subagent.py indented entry" \
  || fail_msg "three-entries: missing log_subagent.py entry"
grep -qF "      $ADV_LOG_SUBAGENT" <<<"$out" \
  && pass_msg "three-entries: log_subagent.py advisory line" \
  || fail_msg "three-entries: missing log_subagent.py advisory"

grep -qF '  → run: bash ${CLAUDE_PLUGIN_ROOT}/scripts/migrate-from-subtree.sh --patch settings' <<<"$out" \
  && pass_msg "three-entries: summary run line present" \
  || { fail_msg "three-entries: missing summary run line"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 4: only log_subagent.py → warn, singular "entry"
# ---------------------------------------------------------------------------
echo "Case 4: single pipeline hook entry (singular)"
FX=$(fresh_fx fx-single-entry)
mkdir -p "$FX/.claude"
cat > "$FX/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"command": "python3 .claude/hooks/log_subagent.py"}]}
    ]
  }
}
JSON
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"
grep -qE '^CHECK: settings_residual status=warn detail=1 pipeline hook entry in \.claude/settings\.json$' <<<"$out" \
  && pass_msg "single-entry: warn singular" \
  || { fail_msg "single-entry: missing singular warn line"; echo "$out" | sed 's/^/    /'; }
grep -qF "      $ADV_LOG_SUBAGENT" <<<"$out" \
  && pass_msg "single-entry: HTS-dogfood advisory rendered" \
  || fail_msg "single-entry: missing HTS-dogfood advisory"
# Ensure no other annotations leaked in.
if grep -qF "      $ADV_RESTRICT_PATHS" <<<"$out"; then
  fail_msg "single-entry: stray restrict_paths advisory rendered"
else
  pass_msg "single-entry: no stray advisories"
fi

# ---------------------------------------------------------------------------
# Case 5: jq absent → doctor fails-fast at jq_installed pre-flight.
# Since #270, jq is enforced as a hard pre-flight dependency alongside gh,
# so settings_residual is never reached when jq is missing. The contract
# verified here is the new fail-fast behavior, not the old per-check warn.
# ---------------------------------------------------------------------------
echo "Case 5: jq absent"
FX=$(fresh_fx fx-no-jq)
mkdir -p "$FX/.claude"
cat > "$FX/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {"hooks": [{"command": "python3 .claude/hooks/restrict_paths.py"}]}
    ]
  }
}
JSON
# Build an isolated PATH dir containing only the shims (no jq).
NOJQ_BIN="$TMP/nojq-bin"
rm -rf "$NOJQ_BIN"
mkdir -p "$NOJQ_BIN"
cp "$TMP/bin/gh" "$NOJQ_BIN/gh"
cp "$TMP/bin/claude" "$NOJQ_BIN/claude"
# Symlink every binary from /usr/bin and /bin EXCEPT jq, so PATH=$NOJQ_BIN has
# every coreutil doctor.sh needs but `command -v jq` returns false.
for src_dir in /usr/bin /bin; do
  [ -d "$src_dir" ] || continue
  for f in "$src_dir"/*; do
    bn="$(basename "$f")"
    [ "$bn" = "jq" ] && continue
    [ -e "$NOJQ_BIN/$bn" ] && continue
    ln -s "$f" "$NOJQ_BIN/$bn" 2>/dev/null || true
  done
done
(
  cd "$FX"
  PATH="$NOJQ_BIN" env "CLAUDE_PLUGIN_ROOT=$FX" LABELS_JSON="$ALL_LABELS_JSON" \
    bash "$HELPER"
) > "$FX/out" 2>&1
echo "$?" > "$FX/rc"
out="$(cat "$FX/out")"
rc="$(cat "$FX/rc")"
grep -qE '^CHECK: jq_installed status=fail' <<<"$out" \
  && pass_msg "no-jq: emits CHECK: jq_installed status=fail (fail-fast pre-flight)" \
  || { fail_msg "no-jq: missing jq_installed fail line"; echo "$out" | sed 's/^/    /'; }
[ "$rc" != "0" ] \
  && pass_msg "no-jq: non-zero exit (got $rc) — fail-fast on missing jq" \
  || fail_msg "no-jq: exit was 0; doctor must fail-fast on missing jq"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
