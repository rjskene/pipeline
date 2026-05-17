#!/bin/bash
set -uo pipefail

# Tests for scripts/doctor.sh `skill_files_residual` check.
# Spoofs CLAUDE_PLUGIN_ROOT to a tmp dir populated with plugin-shipped
# basenames so the test does not depend on a real plugin install.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# gh shim — just enough to keep upstream checks happy.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") exit 0 ;;
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
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"

# claude shim — make plugin_loaded pass
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

# Build a fake plugin root with the basenames doctor expects to compare against.
mk_plugin_root() {
  local root="$1"
  rm -rf "$root"
  mkdir -p "$root/skills/classify-issue" "$root/skills/plan-issue"
  mkdir -p "$root/hooks" "$root/scripts" "$root/agents"
  touch "$root/skills/classify-issue/SKILL.md"
  touch "$root/skills/plan-issue/SKILL.md"
  touch "$root/hooks/restrict_paths.py"
  touch "$root/scripts/doctor.sh"
  touch "$root/agents/tdd-implementer.md"
}

mk_plugin_root_with_templates() {
  local root="$1"
  mk_plugin_root "$root"
  # Class 2 fixture: plugin ships <name>.sh.template files under scripts/
  touch "$root/scripts/spawn-claude.sh.template"
  touch "$root/scripts/cleanup-worktree.sh.template"
}

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
PIPELINE_REPO="${PIPELINE_REPO_OVERRIDE:-rjskene/bomon-train}"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

run_helper() {
  local fx="$1" plugin_root="$2"; shift 2
  (
    cd "$fx"
    PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$plugin_root" \
      LABELS_JSON="$ALL_LABELS_JSON" \
      "$@" bash "$HELPER"
  ) > "$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

PLUGIN_ROOT="$TMP/plugin-root"
mk_plugin_root "$PLUGIN_ROOT"

# ---------------------------------------------------------------------------
# Case 1: consumer .claude/ absent → pass
# ---------------------------------------------------------------------------
echo "Case 1: no consumer .claude/ → pass"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-noclaude)
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
grep -qE '^CHECK: skill_files_residual status=pass detail=no plugin-basename duplicates' <<<"$out" \
  && pass_msg "no-consumer-claude: pass detail" \
  || { fail_msg "no-consumer-claude: wrong detail"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 2: only consumer-authored skills (basenames not in plugin) → pass + Preserved list
# ---------------------------------------------------------------------------
echo "Case 2: consumer-authored only → pass with Preserved list"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-consumer-only)
mkdir -p "$FX/.claude/skills/my-custom-skill"
echo "consumer skill body" > "$FX/.claude/skills/my-custom-skill/SKILL.md"
mkdir -p "$FX/.claude/scripts"
echo "echo hi" > "$FX/.claude/scripts/my-custom-script.sh"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
# Plugin basenames include SKILL.md, so consumer SKILL.md WILL be flagged.
# To trigger this case we need basenames that don't collide; rename them.
# Instead, use scripts/ check: my-custom-script.sh is not in plugin.
# But SKILL.md in consumer collides with plugin SKILL.md basename.
# So adjust: remove the SKILL.md fixture.
rm -rf "$FX/.claude/skills"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
grep -qE '^CHECK: skill_files_residual status=pass' <<<"$out" \
  && pass_msg "consumer-only: status=pass" \
  || { fail_msg "consumer-only: wrong status"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Preserved — consumer-owned:' <<<"$out" \
  && grep -qE 'my-custom-script\.sh' <<<"$out" \
  && pass_msg "consumer-only: Preserved list shows consumer file" \
  || { fail_msg "consumer-only: missing Preserved section"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 3: consumer .claude/skills/classify-issue/SKILL.md present → warn (1 dup)
# ---------------------------------------------------------------------------
echo "Case 3: 1 duplicate SKILL.md → warn"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-dup-skill)
mkdir -p "$FX/.claude/skills/classify-issue"
echo "stale copy" > "$FX/.claude/skills/classify-issue/SKILL.md"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: skill_files_residual status=warn detail=1 duplicate' <<<"$out" \
  && pass_msg "dup-skill: warn detail=1 duplicate" \
  || { fail_msg "dup-skill: wrong detail"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Duplicates of plugin-owned files' <<<"$out" \
  && grep -qE 'classify-issue/SKILL\.md' <<<"$out" \
  && pass_msg "dup-skill: lists duplicate file" \
  || { fail_msg "dup-skill: missing duplicate section"; echo "$out" | sed 's/^/    /'; }
grep -qE 'migrate-from-subtree\.sh' <<<"$out" \
  && pass_msg "dup-skill: remediation hint present" \
  || fail_msg "dup-skill: missing remediation hint"

# ---------------------------------------------------------------------------
# Case 4: tdd-implementer.md + restrict_paths.py duplicates → warn (2 dups)
# ---------------------------------------------------------------------------
echo "Case 4: 2 duplicates (agent + hook) → warn"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-dup-2)
mkdir -p "$FX/.claude/agents" "$FX/.claude/hooks"
echo "stale agent" > "$FX/.claude/agents/tdd-implementer.md"
echo "stale hook" > "$FX/.claude/hooks/restrict_paths.py"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
grep -qE '^CHECK: skill_files_residual status=warn detail=2 duplicate' <<<"$out" \
  && pass_msg "dup-2: warn detail=2 duplicate(s)" \
  || { fail_msg "dup-2: wrong detail"; echo "$out" | sed 's/^/    /'; }
grep -qE 'tdd-implementer\.md' <<<"$out" \
  && grep -qE 'restrict_paths\.py' <<<"$out" \
  && pass_msg "dup-2: both files listed" \
  || { fail_msg "dup-2: missing files"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 5: duplicate SKILL.md contains `--repo rjskene/bomon` but
#          $PIPELINE_REPO=rjskene/bomon-train → fail with critical line + exit non-zero
# ---------------------------------------------------------------------------
echo "Case 5: stale-repo critical fail"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-stale-repo)
mkdir -p "$FX/.claude/skills/classify-issue"
cat > "$FX/.claude/skills/classify-issue/SKILL.md" <<'SK'
# classify-issue (stale)

Run: gh issue list --repo rjskene/bomon --state open

PIPELINE_REPO context: "rjskene/bomon"
SK
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"; rc="$(cat "$FX/rc")"
grep -qE '^CHECK: skill_files_residual status=fail detail=.*stale-repo' <<<"$out" \
  && pass_msg "stale-repo: status=fail detail mentions stale-repo" \
  || { fail_msg "stale-repo: wrong detail"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Critical: stale legacy-install references' <<<"$out" \
  && pass_msg "stale-repo: critical header present" \
  || { fail_msg "stale-repo: missing critical header"; echo "$out" | sed 's/^/    /'; }
grep -qE 'targets rjskene/bomon' <<<"$out" \
  && grep -qE 'current PIPELINE_REPO=rjskene/bomon-train' <<<"$out" \
  && pass_msg "stale-repo: captured token + actual repo in detail" \
  || { fail_msg "stale-repo: missing token/actual"; echo "$out" | sed 's/^/    /'; }
[ "$rc" != "0" ] && pass_msg "stale-repo: non-zero exit ($rc)" || fail_msg "stale-repo: exit was 0"

# ---------------------------------------------------------------------------
# Case 6: consumer skills/todo/SKILL.md must NOT be flagged as duplicate,
#          but consumer skills/classify-issue/SKILL.md MUST be flagged.
# ---------------------------------------------------------------------------
echo "Case 6: relative-path skill matching"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-relpath-skill)
mkdir -p "$FX/.claude/skills/todo" "$FX/.claude/skills/classify-issue"
echo "consumer-authored todo skill" > "$FX/.claude/skills/todo/SKILL.md"
echo "stale copy of plugin skill"   > "$FX/.claude/skills/classify-issue/SKILL.md"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
grep -qE '^CHECK: skill_files_residual status=warn detail=1 duplicate' <<<"$out" \
  && pass_msg "relpath-skill: warn detail=1 (only classify-issue is dup)" \
  || { fail_msg "relpath-skill: wrong detail"; echo "$out" | sed 's/^/    /'; }
grep -qE 'classify-issue/SKILL\.md' <<<"$out" \
  && pass_msg "relpath-skill: classify-issue listed as duplicate" \
  || fail_msg "relpath-skill: classify-issue not flagged"
awk '/Duplicates of plugin-owned files/{flag=1; next} /Required — rendered from plugin templates:|Preserved — consumer-owned:/{flag=0} flag' <<<"$out" \
  | grep -qE 'todo/SKILL\.md' \
  && fail_msg "relpath-skill: todo/SKILL.md WRONGLY flagged as duplicate" \
  || pass_msg "relpath-skill: todo/SKILL.md NOT flagged (preserved)"
awk '/Preserved — consumer-owned:/{flag=1; next} flag' <<<"$out" \
  | grep -qE 'todo/SKILL\.md' \
  && pass_msg "relpath-skill: todo/SKILL.md appears under Preserved" \
  || { fail_msg "relpath-skill: todo/SKILL.md missing from Preserved"; echo "$out" | sed 's/^/    /'; }

# ---------------------------------------------------------------------------
# Case 7: --fix residual respects relative-path matching
# ---------------------------------------------------------------------------
echo "Case 7: --fix residual relative-path matching"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-fix-relpath)
mkdir -p "$FX/.claude/skills/todo" "$FX/.claude/skills/classify-issue"
echo "consumer todo" > "$FX/.claude/skills/todo/SKILL.md"
echo "stale classify" > "$FX/.claude/skills/classify-issue/SKILL.md"
(
  cd "$FX"
  PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT" \
    LABELS_JSON="$ALL_LABELS_JSON" DOCTOR_FIX_NONINTERACTIVE=1 \
    bash "$HELPER" --fix residual
) > "$FX/out" 2>&1
out="$(cat "$FX/out")"
grep -qE 'Remove duplicate of plugin-shipped file: \.claude/skills/classify-issue\?' <<<"$out" \
  && pass_msg "fix-relpath: classify-issue prompted for removal" \
  || { fail_msg "fix-relpath: classify-issue not prompted"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Remove duplicate of plugin-shipped file: \.claude/skills/todo' <<<"$out" \
  && fail_msg "fix-relpath: todo WRONGLY prompted for removal" \
  || pass_msg "fix-relpath: todo NOT prompted (preserved)"
[ -d "$FX/.claude/skills/todo" ] && pass_msg "fix-relpath: todo dir survives" \
  || fail_msg "fix-relpath: todo dir was deleted"

# ---------------------------------------------------------------------------
# Case 8: consumer .claude/scripts/spawn-claude.sh is classified as
# consumer-required (plugin ships scripts/spawn-claude.sh.template). It
# must NOT be flagged as duplicate and must NOT appear in --fix residual.
# ---------------------------------------------------------------------------
echo "Case 8: consumer-required from .template"
PLUGIN_ROOT_T="$TMP/plugin-root-templates"
mk_plugin_root_with_templates "$PLUGIN_ROOT_T"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-consumer-required)
mkdir -p "$FX/.claude/scripts"
echo "rendered spawn"   > "$FX/.claude/scripts/spawn-claude.sh"
echo "rendered cleanup" > "$FX/.claude/scripts/cleanup-worktree.sh"
echo "consumer-only"    > "$FX/.claude/scripts/my-custom.sh"
run_helper "$FX" "$PLUGIN_ROOT_T"
out="$(cat "$FX/out")"
grep -qE '^CHECK: skill_files_residual status=pass' <<<"$out" \
  && pass_msg "consumer-required: status=pass (no duplicates)" \
  || { fail_msg "consumer-required: wrong status"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Required — rendered from plugin templates:' <<<"$out" \
  && grep -qE 'spawn-claude\.sh' <<<"$out" \
  && grep -qE 'cleanup-worktree\.sh' <<<"$out" \
  && pass_msg "consumer-required: section lists both rendered scripts" \
  || { fail_msg "consumer-required: missing section"; echo "$out" | sed 's/^/    /'; }
grep -qE 'Preserved — consumer-owned:' <<<"$out" \
  && grep -qE 'my-custom\.sh' <<<"$out" \
  && pass_msg "consumer-required: my-custom.sh appears under Preserved" \
  || fail_msg "consumer-required: my-custom.sh missing from Preserved"
# Verify --fix residual does NOT propose deleting the rendered scripts.
(
  cd "$FX"
  PATH="$TMP/bin:$PATH" env "CLAUDE_PLUGIN_ROOT=$PLUGIN_ROOT_T" \
    LABELS_JSON="$ALL_LABELS_JSON" DOCTOR_FIX_NONINTERACTIVE=1 \
    bash "$HELPER" --fix residual
) > "$FX/fix-out" 2>&1
fix_out="$(cat "$FX/fix-out")"
grep -qE 'Remove duplicate of plugin-shipped file: \.claude/scripts/spawn-claude\.sh' <<<"$fix_out" \
  && fail_msg "consumer-required: spawn-claude.sh WRONGLY prompted for removal" \
  || pass_msg "consumer-required: spawn-claude.sh NOT prompted"
[ -f "$FX/.claude/scripts/spawn-claude.sh" ] && pass_msg "consumer-required: spawn-claude.sh survives" \
  || fail_msg "consumer-required: spawn-claude.sh was deleted"

# ---------------------------------------------------------------------------
# Case 9: pyc/__pycache__ in consumer .claude/ → filtered out of all output
# ---------------------------------------------------------------------------
echo "Case 9: pyc/__pycache__ in consumer .claude/ → filtered out of all output"
FX=$(PIPELINE_REPO_OVERRIDE="rjskene/bomon-train" fresh_fx fx-pyc-filter)
mkdir -p "$FX/.claude/scripts/__pycache__" "$FX/.claude/hooks/__pycache__"
echo "binary" > "$FX/.claude/scripts/__pycache__/foo.cpython-312.pyc"
echo "binary" > "$FX/.claude/hooks/__pycache__/bar.cpython-312.pyc"
# Also drop a consumer-owned .sh so the Preserved section actually renders.
echo "echo hi" > "$FX/.claude/scripts/my-script.sh"
run_helper "$FX" "$PLUGIN_ROOT"
out="$(cat "$FX/out")"
if ! grep -qE '__pycache__|\.pyc' <<<"$out"; then
  pass_msg "pyc-filter: no pyc/__pycache__ tokens anywhere in doctor output"
else
  fail_msg "pyc-filter: pyc/__pycache__ leaked into output"
  echo "$out" | sed 's/^/    /'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
