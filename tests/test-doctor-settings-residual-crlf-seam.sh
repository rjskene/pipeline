#!/bin/bash
set -uo pipefail

# Issue #1158 — CRLF-jq seam over doctor.sh's settings_residual check.
#
# Git-for-Windows jq (msvcrt) terminates every output line with \r\n. The
# residual-hook read `jq -r '.hooks | ... | .command'` (L699) hands
# `python3 .claude/hooks/log_subagent.py\r` to the loop, so `_sr_bn` becomes
# `log_subagent.py\r`. The exact-line `grep -Fxq "$_sr_bn"` against the CR-free
# `list_pipeline_hook_basenames` allow-list then MISSES, `_sr_findings` stays
# empty, and doctor falsely records `settings_residual pass "no pipeline hook
# entries"` while a real pipeline hook sits in .claude/settings.json.
#
# Model: tests/test-doctor-settings-residual.sh Case 4 (single log_subagent.py
# entry → warn, singular). A fake jq earlier on PATH reproduces the msvcrt CR
# faithfully on an LF-only host; the whole doctor run is scoped under it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=_lib/crlf-jq-seam.sh
source "$SCRIPT_DIR/_lib/crlf-jq-seam.sh"

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim (auth/repo/labels) — mirrors test-doctor-settings-residual.sh.
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
      printf '%s\n' plan-pending plan-reviewed plan-approved in-progress pr-open merged excluded later human brainstorm
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

# Fake CRLF jq LAYERED into the same bin dir (shadows real jq for the doctor run).
if ! make_crlf_jq_bin "$TMP/bin"; then
  fail_msg "CRLF-seam: fake-jq seam setup failed (non-vacuity guard)"
  echo "RESULT: $PASS passed, $FAIL failed"
  exit 1
fi

# Fresh consumer fixture with ONE pipeline hook (log_subagent.py is in the
# list_pipeline_hook_basenames allow-list).
FX="$TMP/fx"
mkdir -p "$FX/.claude"
(
  cd "$FX"
  git init -q
  git config user.email t@t
  git config user.name t
  git commit --allow-empty -q -m init
  git branch -q staging 2>/dev/null || git checkout -q -b staging
) >/dev/null 2>&1
cat > "$FX/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
SETTINGS="$FX/.claude/$(printf 'settings').json"
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"command": "python3 .claude/hooks/log_subagent.py"}]}
    ]
  }
}
JSON

(
  cd "$FX"
  PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$FX" LABELS_JSON='[]' bash "$HELPER"
) > "$FX/out" 2>&1
out="$(cat "$FX/out")"

# (a) settings_residual must DETECT the residual hook (warn), NOT falsely pass.
if grep -qE '^CHECK: settings_residual status=warn detail=1 pipeline hook entry in \.claude/settings\.json$' <<<"$out"; then
  pass_msg "CRLF-seam: settings_residual detects the residual hook (warn) under CRLF jq"
else
  fail_msg "CRLF-seam: settings_residual should warn, not falsely 'pass no pipeline hook entries'"
  grep 'settings_residual' <<<"$out" | sed 's/^/    /'
fi

# (b) the residual hook basename must be annotated (finding rendered).
if grep -qF "  - .claude/hooks/log_subagent.py" <<<"$out"; then
  pass_msg "CRLF-seam: residual hook basename annotated (log_subagent.py)"
else
  fail_msg "CRLF-seam: residual hook entry not annotated (grep -Fxq missed the CR-poisoned basename)"
fi

# (c) no stray CR must survive into the settings_residual CHECK line or entries.
sr_lines="$(grep -E 'settings_residual|\.claude/hooks/' <<<"$out" || true)"
if [ -n "$sr_lines" ] && printf '%s' "$sr_lines" | grep -q $'\r'; then
  fail_msg "CRLF-seam: settings_residual output carries a stray CR under CRLF jq"
else
  pass_msg "CRLF-seam: no stray CR in settings_residual output"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
