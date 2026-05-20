#!/bin/bash
# Tests for the doctor `container_skills_validity` check (issue #321).
#
# Four fixtures vary PIPELINE_CONTAINER_SKILLS in pipeline.config and assert
# the structured `CHECK: container_skills_validity status=<...> detail=<...>`
# line. The canonical skill set is derived at runtime from
# ${CLAUDE_PLUGIN_ROOT}/skills/, so each fixture materialises a fake plugin
# root containing the real skill names (including classify-issue, to prove
# the derivation is wired up correctly).

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

# Stubbed gh that satisfies the gh_installed / gh_auth / gh_repo_reachable /
# labels_exist checks without hitting the network.
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

# fresh_fx <name> [pipeline_container_skills_line]
# Creates a fake consumer project and a fake plugin root. The 2nd arg is
# the literal line to append to pipeline.config — pass an empty string for
# the "unset" fixture (no line emitted at all).
fresh_fx() {
  local name="$1"
  local pcs_line="${2-}"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.claude" "$root/plugin/skills" "$root/plugin/.claude-plugin"
  ( cd "$root/proj" \
      && git init -q \
      && git config user.email t@t \
      && git config user.name t \
      && git commit --allow-empty -q -m init \
      && (git branch -q staging 2>/dev/null || git checkout -q -b staging) ) >/dev/null 2>&1
  # Materialise the 10 canonical skill directories so the runtime-derived
  # set finds them — including classify-issue (case 2 asserts on this).
  for sk in classify-issue create-issues doctor evaluate-issue-plan evaluate-issue-pr \
            execute-issue-plan fullsend plan-issue run worktree-sync; do
    mkdir -p "$root/plugin/skills/$sk"
  done
  cat > "$root/plugin/.claude-plugin/plugin.json" <<'JSON'
{ "name": "pipeline", "version": "0.8.0" }
JSON
  {
    cat <<'CFG'
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
    if [ -n "$pcs_line" ]; then
      printf '%s\n' "$pcs_line"
    fi
  } > "$root/proj/pipeline.config"
  echo "$root"
}

run_doctor() {
  local root="$1"
  (
    cd "$root/proj"
    PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$root/plugin" bash "$DOCTOR"
  ) > "$root/out" 2>&1 || true
  cat "$root/out"
}

# ---------------------------------------------------------------------------
# Case 1: PIPELINE_CONTAINER_SKILLS unset -> pass (default: evaluate-issue-pr)
# ---------------------------------------------------------------------------
echo "Case 1: PIPELINE_CONTAINER_SKILLS unset -> pass (default)"
ROOT=$(fresh_fx fx-1-unset "")
OUT=$(run_doctor "$ROOT")
if grep -qE '^CHECK: container_skills_validity status=pass detail=default \(evaluate-issue-pr\)' <<<"$OUT"; then
  pass_msg "unset -> status=pass with 'default (evaluate-issue-pr)' detail"
else
  fail_msg "expected status=pass with 'default (evaluate-issue-pr)' detail"
  grep -E 'container_skills_validity' <<<"$OUT" | sed 's/^/    /' || echo "    (no container_skills_validity line emitted at all)"
fi

# ---------------------------------------------------------------------------
# Case 2: 4 real canonical skills (including classify-issue) -> pass
# ---------------------------------------------------------------------------
echo "Case 2: 4 canonical skills incl. classify-issue -> pass"
ROOT=$(fresh_fx fx-2-canonical 'PIPELINE_CONTAINER_SKILLS="evaluate-issue-pr execute-issue-plan plan-issue classify-issue"')
OUT=$(run_doctor "$ROOT")
if grep -qE '^CHECK: container_skills_validity status=pass detail=4 skill\(s\) all canonical' <<<"$OUT"; then
  pass_msg "4 canonical skills -> status=pass mentioning '4 skill(s) all canonical'"
else
  fail_msg "expected status=pass mentioning '4 skill(s) all canonical'"
  grep -E 'container_skills_validity' <<<"$OUT" | sed 's/^/    /' || echo "    (no container_skills_validity line emitted at all)"
fi

# ---------------------------------------------------------------------------
# Case 3: unknown skill -> warn
# ---------------------------------------------------------------------------
echo "Case 3: unknown skill -> warn"
ROOT=$(fresh_fx fx-3-unknown 'PIPELINE_CONTAINER_SKILLS="evaluate-issue-pr bogus-skill"')
OUT=$(run_doctor "$ROOT")
if grep -qE '^CHECK: container_skills_validity status=warn detail=unknown skill\(s\): bogus-skill' <<<"$OUT"; then
  pass_msg "unknown skill -> status=warn mentioning 'bogus-skill'"
else
  fail_msg "expected status=warn mentioning 'bogus-skill'"
  grep -E 'container_skills_validity' <<<"$OUT" | sed 's/^/    /' || echo "    (no container_skills_validity line emitted at all)"
fi

# ---------------------------------------------------------------------------
# Case 4: explicit empty string -> pass (disabled, not a misconfig)
# ---------------------------------------------------------------------------
echo "Case 4: PIPELINE_CONTAINER_SKILLS=\"\" -> pass (disabled)"
ROOT=$(fresh_fx fx-4-empty 'PIPELINE_CONTAINER_SKILLS=""')
OUT=$(run_doctor "$ROOT")
if grep -qE '^CHECK: container_skills_validity status=pass detail=disabled \(explicit empty\)' <<<"$OUT"; then
  pass_msg "empty string -> status=pass with 'disabled (explicit empty)' detail"
else
  fail_msg "expected status=pass with 'disabled (explicit empty)' detail"
  grep -E 'container_skills_validity' <<<"$OUT" | sed 's/^/    /' || echo "    (no container_skills_validity line emitted at all)"
fi

echo ""
echo "================================"
echo "  PASS=$PASS FAIL=$FAIL"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
