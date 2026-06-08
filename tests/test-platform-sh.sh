#!/bin/bash
set -uo pipefail

# Tests for scripts/platform.sh — sourceable harness-detection primitive that
# exports PIPELINE_HARNESS=claude|codex. Leg 1 of the Codex dual-target migration
# (issue #980). The precedence ladder is:
#   1. pipeline.config PIPELINE_HARNESS override (authoritative; read by GREP, not source)
#   2. env sniff: CODEX_HOME present -> codex; else CLAUDE_PLUGIN_ROOT present -> claude
#   3. default claude
#
# Each case runs in a hermetic `env -i` subshell so no inherited env (CODEX_HOME,
# CLAUDE_PLUGIN_ROOT, CLAUDE_PROJECT_DIR) leaks in. The script is sourced under
# `set -e` in one case to prove every command keeps exit status 0.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/platform.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_msg "$label"
  else
    fail_msg "$label (expected='$expected' actual='$actual')"
  fi
}

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Write a pipeline.config carrying an (optional) PIPELINE_HARNESS line into a
# fresh project dir; echo the dir path. With no arg, writes a config WITHOUT the
# override line (so detection must fall through to the env sniff / default).
make_projdir() {
  local override="${1:-}"
  local d; d="$(mktemp -d "$TMP/proj.XXXXXX")"
  {
    echo '# fake pipeline.config'
    echo 'PIPELINE_REPO=rjskene/pipeline'
    # Host-specific $(...) MUST NOT execute during detection — detection greps,
    # never sources. If platform.sh sources this, the subshell dies here.
    echo 'PIPELINE_EXAMPLE_PATH=$(exit 7)'
    [ -n "$override" ] && echo "$override"
  } > "$d/pipeline.config"
  echo "$d"
}

# Run platform.sh in a hermetic env -i subshell (only PATH + the named vars),
# source it, echo $PIPELINE_HARNESS. Args: KEY=VALUE pairs for the clean env.
detect() {
  env -i PATH="$PATH" "$@" "$BASH_BIN" -c "source '$SCRIPT'; printf '%s' \"\$PIPELINE_HARNESS\""
}

# ---------------- Case a: config override wins over any env ----------------
# Override says claude even though CODEX_HOME is set -> override wins.
PROJ=$(make_projdir 'PIPELINE_HARNESS=claude')
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ" CODEX_HOME=/some/codex CLAUDE_PLUGIN_ROOT=/some/claude)
assert_eq "Case a: config override 'claude' beats CODEX_HOME env" "claude" "$ACTUAL"

# And the inverse: override says codex even though only CLAUDE_PLUGIN_ROOT is set.
PROJ=$(make_projdir 'PIPELINE_HARNESS=codex')
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT=/some/claude)
assert_eq "Case a': config override 'codex' beats CLAUDE_PLUGIN_ROOT env" "codex" "$ACTUAL"

# ---------------- Case b: CODEX_HOME-only -> codex ----------------
PROJ=$(make_projdir)   # no override line
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ" CODEX_HOME=/some/codex)
assert_eq "Case b: CODEX_HOME present, no override -> codex" "codex" "$ACTUAL"

# ---------------- Case c: CLAUDE_PLUGIN_ROOT-only -> claude ----------------
PROJ=$(make_projdir)
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ" CLAUDE_PLUGIN_ROOT=/some/claude)
assert_eq "Case c: CLAUDE_PLUGIN_ROOT present, no override -> claude" "claude" "$ACTUAL"

# ---------------- Case d: both env vars set -> codex wins the sniff ----------------
PROJ=$(make_projdir)
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ" CODEX_HOME=/some/codex CLAUDE_PLUGIN_ROOT=/some/claude)
assert_eq "Case d: CODEX_HOME + CLAUDE_PLUGIN_ROOT both set -> codex wins sniff" "codex" "$ACTUAL"

# ---------------- Case e: neither -> default claude ----------------
PROJ=$(make_projdir)
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ")
assert_eq "Case e: no override, no env -> default claude" "claude" "$ACTUAL"

# ---------------- Case f: last override assignment wins, quotes stripped ----------------
# Two override lines; the LAST one is authoritative. Value is double-quoted to
# prove one layer of quotes is stripped.
PROJ=$(make_projdir)
{ echo 'PIPELINE_HARNESS=claude'; echo 'PIPELINE_HARNESS="codex"'; } >> "$PROJ/pipeline.config"
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ")
assert_eq "Case f: last PIPELINE_HARNESS assignment wins + one quote layer stripped" "codex" "$ACTUAL"

# ---------------- Case g: leading-whitespace / indented assignment is read ----------------
PROJ=$(make_projdir)
printf '   PIPELINE_HARNESS = codex\n' >> "$PROJ/pipeline.config"
ACTUAL=$(detect CLAUDE_PROJECT_DIR="$PROJ")
assert_eq "Case g: indented 'PIPELINE_HARNESS = codex' (spaces around =) is honored" "codex" "$ACTUAL"

# ---------------- Case h: sourced under set -e stays exit-status 0 ----------------
# platform.sh is sourced into scripts running `set -e`; a non-zero command in it
# would abort the host. Source it under set -e and prove the process exits 0.
PROJ=$(make_projdir)   # no override -> exercises the full sniff/default path
set +e
env -i PATH="$PATH" CLAUDE_PROJECT_DIR="$PROJ" "$BASH_BIN" -c "set -e; source '$SCRIPT'; exit 0"
RC=$?
set -e
assert_eq "Case h: sourcing under 'set -e' keeps exit status 0" "0" "$RC"

# ---------------- Case i: CLAUDE_PROJECT_DIR unset -> falls back to \$PWD ----------------
# No CLAUDE_PROJECT_DIR; cd into the project dir so PWD carries the config.
PROJ=$(make_projdir 'PIPELINE_HARNESS=codex')
ACTUAL=$(env -i PATH="$PATH" "$BASH_BIN" -c "cd '$PROJ'; source '$SCRIPT'; printf '%s' \"\$PIPELINE_HARNESS\"")
assert_eq "Case i: no CLAUDE_PROJECT_DIR -> config read from \$PWD" "codex" "$ACTUAL"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
