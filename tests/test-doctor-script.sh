#!/bin/bash
set -uo pipefail

# Tests for scripts/doctor.sh — the non-mutating consumer-install validator.
# The gh CLI and claude CLI are replaced by PATH-resident shims fed via env vars.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — answers auth status / repo view / label list / label create
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "${SHIM_LOG:-/dev/null}"
case "$1 $2" in
  "auth status")
    exit "${GH_AUTH_RC:-0}" ;;
  "repo view")
    exit "${GH_REPO_RC:-0}" ;;
  "label list")
    # Strip --jq if present, then print the configured LABELS_JSON. If --jq
    # '.[].name' is requested, emit one name per line.
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
  "label create")
    echo "label create $3 --color ${5:-} --description ${7:-}" >> "${SHIM_LOG:-/dev/null}"
    exit 0 ;;
  *)
    echo "shim: unhandled gh $*" >&2
    exit 99 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# claude shim (used by later cases; default = not installed unless CLAUDE_SHIM is set)
mk_claude_shim() {
  cat > "$TMP/bin/claude" <<CLAUDE
#!/bin/bash
case "\$1 \$2" in
  "plugin list") printf '%s\n' "\${CLAUDE_PLUGIN_LIST:-}" ;;
  *) exit 0 ;;
esac
CLAUDE
  chmod +x "$TMP/bin/claude"
}

# canonical all-10-labels payload (used as default by passing cases)
ALL_LABELS_JSON='[
  {"name":"plan-pending","color":"C2E0C6","description":"Plan posted, awaiting review"},
  {"name":"plan-reviewed","color":"BFD4F2","description":"Plan evaluated"},
  {"name":"plan-approved","color":"0E8A16","description":"Approved, ready for execution"},
  {"name":"in-progress","color":"FBCA04","description":"Currently being implemented"},
  {"name":"pr-open","color":"1D76DB","description":"PR open, awaiting review"},
  {"name":"merged","color":"6F42C1","description":"PR merged, ready for cleanup"},
  {"name":"excluded","color":"E4E669","description":"Excluded from pipeline"},
  {"name":"later","color":"D4C5F9","description":"Deferred"},
  {"name":"human","color":"F9D0C4","description":"Needs human in the loop"},
  {"name":"brainstorm","color":"FEF2C0","description":"Non-actionable discussion/exploration"}
]'

# Build a fresh fixture project dir. Initializes git and creates a local
# $PIPELINE_BASE_BRANCH branch so the base_branch_local check passes by default.
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
    git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null || true
  ) >/dev/null 2>&1
  cat > "$fx/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

# Run the helper inside the fixture with PATH-shimmed gh/claude and capture stdout/exit.
# Args: fixture_dir [env var=value ...]
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
# Case 1: all-clean — every check passes
# ---------------------------------------------------------------------------
echo "Case 1: all-clean"
FX=$(fresh_fx fx-clean)
mk_claude_shim
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: pipeline_config status=pass' <<<"$out" \
  && pass_msg "all-clean: pipeline_config status=pass" \
  || { fail_msg "all-clean: missing pipeline_config pass"; echo "$out" | sed 's/^/    /'; }
grep -qE '^=== Summary ===$' <<<"$out" \
  && pass_msg "all-clean: summary header present" \
  || fail_msg "all-clean: summary header missing"
[ "$rc" = "0" ] && pass_msg "all-clean: exit 0" || fail_msg "all-clean: exit $rc"

# ---------------------------------------------------------------------------
# Case 2: missing pipeline.config
# ---------------------------------------------------------------------------
echo "Case 2: missing config"
FX=$(fresh_fx fx-noconfig)
rm -f "$FX/pipeline.config"
run_helper "$FX"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: pipeline_config status=fail.*not found' <<<"$out" \
  && pass_msg "no-config: pipeline_config status=fail not found" \
  || { fail_msg "no-config: wrong/missing fail detail"; echo "$out" | sed 's/^/    /'; }
grep -qE '^=== Summary ===$' <<<"$out" \
  && pass_msg "no-config: summary header still present" \
  || fail_msg "no-config: summary header missing"
[ "$rc" != "0" ] && pass_msg "no-config: non-zero exit ($rc)" || fail_msg "no-config: exit was 0"

# ---------------------------------------------------------------------------
# Case 3: missing required key (PIPELINE_REPO blank)
# ---------------------------------------------------------------------------
echo "Case 3: missing PIPELINE_REPO"
FX=$(fresh_fx fx-nokey)
cat > "$FX/pipeline.config" <<'CFG'
PIPELINE_BASE_BRANCH="staging"
CFG
run_helper "$FX"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: pipeline_config status=fail.*PIPELINE_REPO' <<<"$out" \
  && pass_msg "no-repo-key: fail detail mentions PIPELINE_REPO" \
  || { fail_msg "no-repo-key: wrong detail"; echo "$out" | sed 's/^/    /'; }
[ "$rc" != "0" ] && pass_msg "no-repo-key: non-zero exit" || fail_msg "no-repo-key: exit was 0"

# ---------------------------------------------------------------------------
# Case 4: gh auth fails / repo unreachable
# ---------------------------------------------------------------------------
echo "Case 4a: gh auth fails"
FX=$(fresh_fx fx-noauth)
run_helper "$FX" GH_AUTH_RC=1 LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: gh_auth status=fail.*not authenticated' <<<"$out" \
  && pass_msg "gh-noauth: gh_auth status=fail" \
  || { fail_msg "gh-noauth: missing/wrong gh_auth fail"; echo "$out" | sed 's/^/    /'; }
[ "$rc" != "0" ] && pass_msg "gh-noauth: non-zero exit" || fail_msg "gh-noauth: exit was 0"

echo "Case 4b: gh repo unreachable"
FX=$(fresh_fx fx-norepo)
run_helper "$FX" GH_REPO_RC=1 LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: gh_repo_reachable status=fail.*not reachable' <<<"$out" \
  && pass_msg "gh-norepo: gh_repo_reachable status=fail" \
  || { fail_msg "gh-norepo: missing/wrong gh_repo_reachable fail"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 5: labels_exist
# ---------------------------------------------------------------------------
echo "Case 5a: all 10 labels present"
FX=$(fresh_fx fx-labels-pass)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: labels_exist status=pass detail=10/10' <<<"$out" \
  && pass_msg "labels-pass: 10/10 detail" \
  || { fail_msg "labels-pass: wrong detail"; echo "$out" | sed 's/^/    /'; }

echo "Case 5b: two labels missing"
FX=$(fresh_fx fx-labels-missing)
PARTIAL_JSON='[
  {"name":"plan-pending"},{"name":"plan-reviewed"},
  {"name":"in-progress"},{"name":"pr-open"},{"name":"merged"},
  {"name":"excluded"},{"name":"later"},{"name":"human"}
]'
run_helper "$FX" LABELS_JSON="$PARTIAL_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: labels_exist status=fail detail=missing:.*plan-approved' <<<"$out" \
  && grep -qE 'brainstorm' <<<"$out" \
  && pass_msg "labels-missing: detail lists missing labels" \
  || { fail_msg "labels-missing: wrong detail"; echo "$out" | sed 's/^/    /'; }

echo "Case 5c: override honored"
FX=$(fresh_fx fx-labels-override)
cat > "$FX/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_LABELS_EXCLUDED="skip"
CFG
OVERRIDE_JSON='[
  {"name":"plan-pending"},{"name":"plan-reviewed"},{"name":"plan-approved"},
  {"name":"in-progress"},{"name":"pr-open"},{"name":"merged"},
  {"name":"skip"},{"name":"later"},{"name":"human"},{"name":"brainstorm"}
]'
run_helper "$FX" LABELS_JSON="$OVERRIDE_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: labels_exist status=pass detail=10/10' <<<"$out" \
  && pass_msg "labels-override: pass when PIPELINE_LABELS_EXCLUDED=skip" \
  || { fail_msg "labels-override: failed"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 6: plugin_loaded
# ---------------------------------------------------------------------------
echo "Case 6a: claude CLI present and plugin loaded"
FX=$(fresh_fx fx-plugin-yes)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST="claude-pipeline 0.4.0"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: plugin_loaded status=pass' <<<"$out" \
  && pass_msg "plugin-yes: status=pass" \
  || { fail_msg "plugin-yes: missing pass"; echo "$out" | sed 's/^/    /'; }

echo "Case 6b: claude CLI present but plugin not in list"
FX=$(fresh_fx fx-plugin-no)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" CLAUDE_PLUGIN_LIST=""
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: plugin_loaded status=fail' <<<"$out" \
  && pass_msg "plugin-no: status=fail" \
  || { fail_msg "plugin-no: missing fail"; echo "$out" | sed 's/^/    /'; }

echo "Case 6c: claude CLI absent → warn"
FX=$(fresh_fx fx-plugin-warn)
# Remove the shim AND override PATH to exclude any system-installed claude.
rm -f "$TMP/bin/claude"
(
  cd "$FX"
  PATH="$TMP/bin:/usr/bin:/bin" CLAUDE_PLUGIN_ROOT="$FX" LABELS_JSON="$ALL_LABELS_JSON" bash "$HELPER"
) > "$FX/out" 2>&1
echo "$?" > "$FX/rc"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: plugin_loaded status=warn.*claude CLI not on PATH' <<<"$out" \
  && pass_msg "plugin-warn: status=warn" \
  || { fail_msg "plugin-warn: missing warn"; echo "$out" | sed 's/^/    /'; }
[ "$rc" = "0" ] && pass_msg "plugin-warn: warn does not cause non-zero exit" || fail_msg "plugin-warn: warn caused exit $rc"
mk_claude_shim  # restore for later cases

# ---------------------------------------------------------------------------
# Case 7: no_residual_subtree
# ---------------------------------------------------------------------------
echo "Case 7a: clean (no residual subtree)"
FX=$(fresh_fx fx-clean-subtree)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: no_residual_subtree status=pass' <<<"$out" \
  && pass_msg "clean-subtree: pass" \
  || { fail_msg "clean-subtree: missing pass"; echo "$out" | sed 's/^/    /'; }

echo "Case 7b: residual .claude-pipeline dir"
FX=$(fresh_fx fx-residual)
mkdir -p "$FX/.claude-pipeline"
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: no_residual_subtree status=fail.*\.claude-pipeline' <<<"$out" \
  && pass_msg "residual-subtree: fail detail mentions .claude-pipeline" \
  || { fail_msg "residual-subtree: wrong detail"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 8: base_branch_local
# ---------------------------------------------------------------------------
echo "Case 8a: base branch missing"
FX="$TMP/fx-nobranch"
rm -rf "$FX"; mkdir -p "$FX"
( cd "$FX" && git init -q && git config user.email t@t && git config user.name t && git commit --allow-empty -q -m init ) >/dev/null 2>&1
cat > "$FX/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: base_branch_local status=fail.*branch not found' <<<"$out" \
  && pass_msg "no-base-branch: fail detail=branch not found" \
  || { fail_msg "no-base-branch: wrong detail"; echo "$out" | sed 's/^/    /'; }

echo "Case 8b: base branch local but no upstream → warn"
FX=$(fresh_fx fx-no-upstream)
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: base_branch_local status=warn.*no upstream' <<<"$out" \
  && pass_msg "no-upstream: status=warn detail=no upstream" \
  || { fail_msg "no-upstream: wrong detail"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 9: mixed pass/fail → non-zero exit; summary table present
# ---------------------------------------------------------------------------
echo "Case 9: mixed pass/fail → exit 1, summary rendered"
FX=$(fresh_fx fx-mixed)
mkdir -p "$FX/.claude-pipeline"  # force one fail
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
[ "$rc" != "0" ] && pass_msg "mixed: non-zero exit" || fail_msg "mixed: exit was 0"
grep -qE '^=== Summary ===$' <<<"$out" \
  && pass_msg "mixed: summary header" \
  || fail_msg "mixed: summary header missing"
grep -qE '^no_residual_subtree[[:space:]]+fail' <<<"$out" \
  && pass_msg "mixed: summary row for no_residual_subtree fail" \
  || { fail_msg "mixed: summary row missing"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 11: claude_plugin_root — four statuses (pass / pass / warn / fail).
# Pins HOME to hermetic dirs so the developer's real cache doesn't pollute the
# assertion. Status conditions:
#   pass — CLAUDE_PLUGIN_ROOT was pre-set AND points to a valid directory.
#   pass — CLAUDE_PLUGIN_ROOT was empty; resolver self-resolved from cache
#          (self-resolution is the recommended path).
#   warn — CLAUDE_PLUGIN_ROOT was pre-set BUT the path does not exist /
#          is not a directory (likely stale config).
#   fail — CLAUDE_PLUGIN_ROOT was empty AND no plugin cache exists under HOME.
# ---------------------------------------------------------------------------
echo "Case 11: claude_plugin_root status check"

# Sub-case A: env pre-set to a valid directory → pass.
FX=$(fresh_fx fx-cpr-pass)
FAKE_HOME="$TMP/fake-home-empty-A"; mkdir -p "$FAKE_HOME"
PRESET_DIR="$TMP/preset-valid-A"; mkdir -p "$PRESET_DIR"
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" \
  HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$PRESET_DIR"
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_plugin_root status=pass' <<<"$out" \
  && pass_msg "cpr-pass: pre-set env → status=pass" \
  || { fail_msg "cpr-pass: did not emit pass"; echo "$out" | sed 's/^/    /'; }

# Sub-case B: env empty + cache present → pass (resolved path appears in detail).
FX=$(fresh_fx fx-cpr-selfresolve)
FAKE_HOME="$TMP/fake-home-with-cache"
mkdir -p "$FAKE_HOME/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0"
RESOLVED="$FAKE_HOME/.claude/plugins/cache/claude-pipeline/pipeline/0.4.0"
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" \
  HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT=""
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_plugin_root status=pass detail=self-resolved from plugin cache:' <<<"$out" \
  && pass_msg "cpr-selfresolve: empty env + cache → status=pass with self-resolve detail" \
  || { fail_msg "cpr-selfresolve: did not emit pass+self-resolve detail"; echo "$out" | sed 's/^/    /'; }
grep -qF "$RESOLVED" <<<"$out" \
  && pass_msg "cpr-selfresolve: detail names resolved path" \
  || { fail_msg "cpr-selfresolve: detail missing resolved path $RESOLVED"; echo "$out" | sed 's/^/    /'; }

# Sub-case C: env empty + no cache → fail.
FX=$(fresh_fx fx-cpr-fail)
FAKE_HOME="$TMP/fake-home-empty-C"; mkdir -p "$FAKE_HOME"
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" \
  HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT=""
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_plugin_root status=fail' <<<"$out" \
  && pass_msg "cpr-fail: empty env + no cache → status=fail" \
  || { fail_msg "cpr-fail: did not emit fail"; echo "$out" | sed 's/^/    /'; }

# Sub-case D: env set to a non-existent path → warn (stale config).
FX=$(fresh_fx fx-cpr-stale)
FAKE_HOME="$TMP/fake-home-empty-D"; mkdir -p "$FAKE_HOME"
STALE_PATH="$TMP/does/not/exist/plugin"
run_helper "$FX" LABELS_JSON="$ALL_LABELS_JSON" \
  HOME="$FAKE_HOME" CLAUDE_PLUGIN_ROOT="$STALE_PATH"
out="$(cat "$FX/out")"
grep -qE '^CHECK: claude_plugin_root status=warn detail=env points to non-existent path:' <<<"$out" \
  && pass_msg "cpr-stale: env set to non-existent path → status=warn" \
  || { fail_msg "cpr-stale: did not emit warn for non-existent path"; echo "$out" | sed 's/^/    /'; }
grep -qF "$STALE_PATH" <<<"$out" \
  && pass_msg "cpr-stale: detail names stale path" \
  || { fail_msg "cpr-stale: detail missing stale path $STALE_PATH"; echo "$out" | sed 's/^/    /'; }

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
