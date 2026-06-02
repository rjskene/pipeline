#!/bin/bash
set -uo pipefail

# Regression test for #810: the ## Boot snippet must locate
# scripts/_resolve-plugin-root.sh via a var-INDEPENDENT anchor (the plugin
# cache glob), NOT via `${CLAUDE_PLUGIN_ROOT:-.}/scripts/...` which is
# chicken-and-egg — when CLAUDE_PLUGIN_ROOT is unset that collapses to
# `./scripts/...` in the consumer cwd, which does not exist, so the
# self-resolve silently no-ops.
#
# IMPORTANT (keep in sync): the `source` line of the canonical snippet keeps a
# LITERAL `_resolve-plugin-root.sh` on it (the directory is a variable PREFIX,
# not the whole path) so it still matches the contract regex
# `source [^ ]*_resolve-plugin-root\.sh` enforced by
# tests/test-skills-source-resolver.sh and tests/test-skill-bash-blocks-self-resolve.sh.
#
# Three assertions:
#  (A) static: no plugin-root SKILL.md Boot block contains the
#      `${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh` form, and
#      every one references the cache-glob anchor path.
#  (C) static: every Boot block still matches `source [^ ]*_resolve-plugin-root\.sh`
#      (the existing source-resolver contract — must not regress).
#  (B) hermetic exec: the canonical snippet, run with CLAUDE_PLUGIN_ROOT
#      unset from a cwd that has NO ./scripts, still finds and sources a
#      resolver placed under a fake plugin cache; and a decoy
#      PIPELINE_PLUGIN_CACHE_DIR is IGNORED (location-only bootstrap is
#      hardcoded to ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SKILLS=$(find "$REPO_ROOT/skills" -maxdepth 2 -name SKILL.md | sort)

# (A)+(C) static checks against each Boot block (first 30 lines is the Boot region).
for skill_md in $SKILLS; do
  rel="${skill_md#$REPO_ROOT/}"
  head30="$(head -n 30 "$skill_md")"
  # (A) Must NOT use the chicken-and-egg form.
  if printf '%s' "$head30" | grep -qE '\$\{CLAUDE_PLUGIN_ROOT:-\.\}/scripts/_resolve-plugin-root\.sh'; then
    fail_msg "$rel still uses chicken-and-egg \${CLAUDE_PLUGIN_ROOT:-.}/scripts/_resolve-plugin-root.sh"
  else
    pass_msg "$rel has no chicken-and-egg resolver form"
  fi
  # (A) Must reference the cache-glob anchor.
  if printf '%s' "$head30" | grep -q 'plugins/cache/claude-pipeline/pipeline'; then
    pass_msg "$rel references the plugin-cache anchor"
  else
    fail_msg "$rel does NOT reference the plugin-cache anchor"
  fi
  # (C) Must still match the source-resolver contract regex (DO NOT regress).
  if printf '%s' "$head30" | grep -qE 'source [^ ]*_resolve-plugin-root\.sh'; then
    pass_msg "$rel Boot matches 'source [^ ]*_resolve-plugin-root.sh' contract regex"
  else
    fail_msg "$rel Boot does NOT match the source-resolver contract regex"
  fi
done

# (B) hermetic exec of the canonical snippet.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
CACHE="$FAKE_HOME/.claude/plugins/cache/claude-pipeline/pipeline/0.99.0/scripts"
mkdir -p "$CACHE"
cat > "$CACHE/_resolve-plugin-root.sh" <<'RESOLVER'
export CLAUDE_PLUGIN_ROOT="RESOLVED_OK"
RESOLVER
CWD="$TMP/consumer"   # consumer cwd with NO ./scripts
mkdir -p "$CWD"

run_snippet() {  # args: extra env assignments evaluated before the snippet
  (
    cd "$CWD"
    export HOME="$FAKE_HOME"
    unset CLAUDE_PLUGIN_ROOT
    eval "$1"
    # --- canonical Boot snippet under test (keep byte-identical to SKILL.md) ---
    _cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
    _cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
    source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
    # --- end snippet ---
    printf '%s' "${CLAUDE_PLUGIN_ROOT:-UNRESOLVED}"
  )
}

# B1: resolves via cache glob when CLAUDE_PLUGIN_ROOT unset + cwd has no ./scripts.
if [ "$(run_snippet ':')" = "RESOLVED_OK" ]; then
  pass_msg "canonical snippet sources resolver via cache glob (var unset, no ./scripts)"
else
  fail_msg "canonical snippet failed to source resolver (got '$(run_snippet ':')')"
fi

# B2: PIPELINE_PLUGIN_CACHE_DIR is deliberately IGNORED by the location-only snippet.
DECOY="$TMP/decoy/scripts"; mkdir -p "$DECOY"
cat > "$DECOY/_resolve-plugin-root.sh" <<'DECOYR'
export CLAUDE_PLUGIN_ROOT="DECOY_WINS"
DECOYR
if [ "$(run_snippet "export PIPELINE_PLUGIN_CACHE_DIR=$TMP/decoy")" = "RESOLVED_OK" ]; then
  pass_msg "snippet ignores PIPELINE_PLUGIN_CACHE_DIR (location-only bootstrap hardcodes \${HOME} cache)"
else
  fail_msg "snippet unexpectedly honored PIPELINE_PLUGIN_CACHE_DIR"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
