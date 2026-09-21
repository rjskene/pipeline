#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$REPO_ROOT/pipeline.config"
EX="$REPO_ROOT/pipeline.config.example"
README="$REPO_ROOT/README.md"
CI="$REPO_ROOT/.github/workflows/ci.yml"
PASS=0; FAIL=0; SKIP=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# --------------------------------------------------------------------------
# LIVE-config rule (#1274 scope 7a).
#
# `staging` is the DOCUMENTED default and that contract is still pinned three
# ways below (pipeline.config.example, README, and the ci.yml branch list). The
# gitignored, host-specific pipeline.config is a different matter: the guard's
# actual intent is "a base branch is configured and it is NOT the release
# branch". A dogfood checkout that legitimately bases on another integration
# branch (e.g. the harness evolve clone's PIPELINE_BASE_BRANCH="evolve") must
# not red this guard, but `main` must still be rejected outright.
# --------------------------------------------------------------------------

# read_base_branch <file> — value of the LAST uncommented PIPELINE_BASE_BRANCH
# assignment (last-wins, matching shell source semantics). Strips a trailing
# ` # comment`, surrounding blanks, and one layer of surrounding quotes.
read_base_branch() {
  local file="$1" line v
  [ -f "$file" ] || return 0
  line="$(grep -E '^[[:space:]]*PIPELINE_BASE_BRANCH=' "$file" | tail -n 1 || true)"
  [ -n "$line" ] || return 0
  v="${line#*=}"
  v="$(printf '%s' "$v" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  case "$v" in
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
  esac
  printf '%s' "$v"
}

# base_branch_set <file> — a base branch is configured at all.
base_branch_set() { [ -n "$(read_base_branch "$1")" ]; }

# base_branch_ok <file> — configured AND not the release branch.
base_branch_ok() {
  local v
  v="$(read_base_branch "$1")"
  [ -n "$v" ] && [ "$v" != "main" ]
}

# pipeline.config is gitignored — only enforce when present (e.g., local dev machine).
if [ -f "$CFG" ]; then
  assert "pipeline.config sets PIPELINE_BASE_BRANCH" "base_branch_set '$CFG'"
  assert "pipeline.config PIPELINE_BASE_BRANCH is not the release branch (main)" "base_branch_ok '$CFG'"
else
  echo "  SKIP: pipeline.config sets PIPELINE_BASE_BRANCH (file gitignored, not present)"
  echo "  SKIP: pipeline.config PIPELINE_BASE_BRANCH is not the release branch (main)"
  SKIP=$((SKIP+2))
fi

# Guard-not-weakened controls. These run ALWAYS (not gated on the host config),
# so CI proves the de-pinned rule still rejects `main` and a missing setting.
CTL="$(mktemp -d)"
trap 'rm -rf "$CTL"' EXIT
printf 'PIPELINE_REPO="owner/repo"\nPIPELINE_BASE_BRANCH="main"\n' > "$CTL/release.config"
printf 'PIPELINE_REPO="owner/repo"\n# PIPELINE_BASE_BRANCH="staging"\n' > "$CTL/absent.config"
printf 'PIPELINE_REPO="owner/repo"\nPIPELINE_BASE_BRANCH="evolve"\n' > "$CTL/evolve.config"
assert "control: PIPELINE_BASE_BRANCH=\"main\" is rejected" "! base_branch_ok '$CTL/release.config'"
assert "control: a config with no live PIPELINE_BASE_BRANCH line is rejected" "! base_branch_ok '$CTL/absent.config'"
assert "control: a non-default, non-release value (evolve) is accepted" "base_branch_ok '$CTL/evolve.config'"

assert "pipeline.config.example default is staging" "grep -qE '^PIPELINE_BASE_BRANCH=\"staging\"' '$EX'"
assert "README documents PIPELINE_BASE_BRANCH=\"staging\" default" "grep -qE 'PIPELINE_BASE_BRANCH=\"staging\"' '$README'"
assert "README no longer documents PIPELINE_BASE_BRANCH=\"main\" as default" "! grep -qE 'PIPELINE_BASE_BRANCH=\"main\"' '$README'"
# #1274 scope 3: the post-merge evolve base must be exercised by push builds too.
# Order-tolerant on purpose — the list may grow again.
assert "ci.yml on.push.branches contains main, staging and evolve" "grep -qE '^[[:space:]]*branches:[[:space:]]*\[[^]]*\bmain\b[^]]*\bstaging\b[^]]*\bevolve\b[^]]*\]' '$CI'"
assert "ci.yml on.push.branches no longer main-only" "! grep -qE '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*\][[:space:]]*$' '$CI'"

echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = "0" ]
