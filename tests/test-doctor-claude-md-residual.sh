#!/bin/bash
set -uo pipefail

# Tests for the claude_md_residual check in scripts/doctor.sh.
# Delegates to scripts/migration-cleanup-claudemd.sh under the hood.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim (copy of pattern from test-doctor-script.sh)
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit "${GH_AUTH_RC:-0}" ;;
  "repo view")   exit "${GH_REPO_RC:-0}" ;;
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

# claude shim
cat > "$TMP/bin/claude" <<'CLAUDE'
#!/bin/bash
case "$1 $2" in
  "plugin list") printf '%s\n' "${CLAUDE_PLUGIN_LIST:-}" ;;
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

# ---------------------------------------------------------------------------
# Case 1: no CLAUDE.md → pass
# ---------------------------------------------------------------------------
echo "Case 1: no CLAUDE.md present"
FX=$(fresh_fx fx-no-claudemd)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_md_residual status=pass detail=no residual pipeline state in CLAUDE.md' <<<"$out" \
  && pass_msg "no-claudemd: pass" \
  || { fail_msg "no-claudemd: missing pass line"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 2: clean CLAUDE.md (only well-formed plugin-era content) → pass
# ---------------------------------------------------------------------------
echo "Case 2: clean CLAUDE.md"
FX=$(fresh_fx fx-clean-claudemd)
cat > "$FX/CLAUDE.md" <<'MD'
# Project notes

This is a clean project. Nothing to see here.

## Coding conventions

Use spaces, not tabs.
MD
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_md_residual status=pass detail=no residual pipeline state in CLAUDE.md' <<<"$out" \
  && pass_msg "clean-claudemd: pass" \
  || { fail_msg "clean-claudemd: missing pass line"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: legacy ## Pipeline header + .claude-pipeline/ corroboration → warn
# ---------------------------------------------------------------------------
echo "Case 3: legacy ## Pipeline header"
FX=$(fresh_fx fx-pipeline-header)
cat > "$FX/CLAUDE.md" <<'MD'
# Project

## Pipeline

Install via the legacy installer at .claude-pipeline/install.sh.
MD
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"
line="$(grep -E '^CHECK: claude_md_residual ' <<<"$out" || true)"
if grep -qE '^CHECK: claude_md_residual status=warn detail=[0-9]+ residual reference' <<<"$line"; then
  n="$(echo "$line" | sed -E 's/.*detail=([0-9]+).*/\1/')"
  if [ "$n" -ge 1 ]; then
    pass_msg "pipeline-header: warn with finding count $n >= 1"
  else
    fail_msg "pipeline-header: count $n < 1"
  fi
else
  fail_msg "pipeline-header: missing warn line"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 4: legacy ## Worktrees header + .claude-pipeline/ corroboration → warn
# Proves the REGEX_HEADER extension picks up "Worktrees".
# ---------------------------------------------------------------------------
echo "Case 4: legacy ## Worktrees header"
FX=$(fresh_fx fx-worktrees-header)
cat > "$FX/CLAUDE.md" <<'MD'
# Project

## Worktrees

See .claude-pipeline/scripts/setup-worktree.sh for the wrapper.
MD
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"
line="$(grep -E '^CHECK: claude_md_residual ' <<<"$out" || true)"
if grep -qE '^CHECK: claude_md_residual status=warn detail=[0-9]+ residual reference' <<<"$line"; then
  pass_msg "worktrees-header: warn"
else
  fail_msg "worktrees-header: missing warn line"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 5: dangling .claude/scripts/spawn-claude.sh AND unprefixed /plan-issue → warn with count>=2
# Note: the scanner's REGEX_PATHS targets `.claude-pipeline/`, `subtree pull`, or `install.sh`.
# The scanner's REGEX_CMDS targets unprefixed pipeline slash commands like /plan-issue.
# We exercise both pass-2 (paths) and pass-3 (cmds) by combining install.sh + /plan-issue.
# ---------------------------------------------------------------------------
echo "Case 5: legacy paths + unprefixed slash commands"
FX=$(fresh_fx fx-mixed-residual)
cat > "$FX/CLAUDE.md" <<'MD'
# Project

To install: run install.sh from the repo root.

To plan an issue, use /plan-issue.
MD
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"
line="$(grep -E '^CHECK: claude_md_residual ' <<<"$out" || true)"
if grep -qE '^CHECK: claude_md_residual status=warn detail=[0-9]+ residual reference' <<<"$line"; then
  n="$(echo "$line" | sed -E 's/.*detail=([0-9]+).*/\1/')"
  if [ "$n" -ge 2 ]; then
    pass_msg "mixed-residual: warn with finding count $n >= 2"
  else
    fail_msg "mixed-residual: count $n < 2"
    echo "$out" | sed 's/^/    /'
  fi
else
  fail_msg "mixed-residual: missing warn line"
  echo "$out" | sed 's/^/    /'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
