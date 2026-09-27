#!/bin/bash
set -uo pipefail

# Removal invariant for issue #1418 — block_deletions.py and restrict_paths.py
# are retired. This test is the single place that pins every consequence of the
# removal so a partial revert (hook file back but manifest entry gone, or the
# doctor array drifting from the SKILL.md prose) fails loudly.
#
# Assertions (a)-(h) mirror the issue's checklist:
#   (a) neither hook file exists
#   (b) the plugin manifest names neither basename
#   (c) the manifest still registers all four surviving guards
#   (d) doctor.sh's LOAD_BEARING_HOOKS drops the retired names, keeps survivors
#   (e) doctor.sh's array and skills/doctor/SKILL.md stay in lockstep
#   (f) the consumer-writes allow-list drops restrict_paths.py and every
#       remaining entry resolves on disk
#   (g) no surviving TRACKED file under hooks/ mentions either basename
#   (h) tests/test-command-mask-unittest.sh is the sole discoverable runner for
#       tests/test_command_mask.py (the deleted test-block-deletions-hook.sh was
#       its only entrypoint; the suite runner globs test*.sh, never *.py)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF_BASENAME="$(basename "$0")"

RETIRED=(block_deletions.py restrict_paths.py)

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required by this test" >&2
  exit 1
fi

MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
DOCTOR_SKILL="$REPO_ROOT/skills/doctor/SKILL.md"
ALLOW="$REPO_ROOT/tests/no-consumer-claude-writes.allow"

# --- (a) neither hook file exists -------------------------------------------
echo "(a) retired hook files are gone"
for h in "${RETIRED[@]}"; do
  if [ -e "$REPO_ROOT/hooks/$h" ]; then
    fail_msg "(a) hooks/$h still exists"
  else
    pass_msg "(a) hooks/$h is gone"
  fi
done

# --- (b) manifest names neither basename ------------------------------------
echo "(b) plugin manifest names neither retired hook"
MANIFEST_CMDS="$(jq -r '.hooks | to_entries[] | .value[]? | .hooks[]? | .command' "$MANIFEST")"
for h in "${RETIRED[@]}"; do
  if printf '%s\n' "$MANIFEST_CMDS" | grep -qF "$h"; then
    fail_msg "(b) plugin.json still registers a command containing $h"
  else
    pass_msg "(b) plugin.json registers no command containing $h"
  fi
done

# --- (c) four survivors still registered ------------------------------------
echo "(c) the four surviving guards are still registered"
# <event>|<matcher>|<basename>
SURVIVORS=(
  "PreToolUse|Bash|enforce-base-branch.py"
  "PreToolUse|Bash|check-ci-skip-markers.py"
  "PreToolUse|Edit|enforce-path-c-delegation.py"
  "PreToolUse|Write|enforce-path-c-delegation.py"
  "Stop|*|enforce-ci-wait.py"
)
for row in "${SURVIVORS[@]}"; do
  IFS="|" read -r ev matcher base <<<"$row"
  found="$(jq -r --arg ev "$ev" --arg m "$matcher" --arg b "$base" '
      (.hooks[$ev] // [])
      | map(select(.matcher == $m))
      | map(.hooks[]? | .command)
      | map(select(contains("${CLAUDE_PLUGIN_ROOT}") and contains("/hooks/" + $b)))
      | length
    ' "$MANIFEST")"
  if [ "${found:-0}" -ge 1 ]; then
    pass_msg "(c) $ev/$matcher registers $base"
  else
    fail_msg "(c) $ev/$matcher does NOT register $base"
  fi
done

# --- (d) doctor.sh LOAD_BEARING_HOOKS ---------------------------------------
echo "(d) doctor.sh LOAD_BEARING_HOOKS drops retired, keeps survivors"
LB_LINE="$(grep -m1 '^LOAD_BEARING_HOOKS=' "$DOCTOR" || true)"
if [ -z "$LB_LINE" ]; then
  fail_msg "(d) no LOAD_BEARING_HOOKS= line in scripts/doctor.sh"
else
  for h in "${RETIRED[@]}"; do
    if printf '%s' "$LB_LINE" | grep -qF "$h"; then
      fail_msg "(d) LOAD_BEARING_HOOKS still lists $h"
    else
      pass_msg "(d) LOAD_BEARING_HOOKS does not list $h"
    fi
  done
  for h in enforce-base-branch.py enforce-path-c-delegation.py; do
    if printf '%s' "$LB_LINE" | grep -qF "$h"; then
      pass_msg "(d) LOAD_BEARING_HOOKS still lists $h"
    else
      fail_msg "(d) LOAD_BEARING_HOOKS lost $h"
    fi
  done
fi

# --- (e) doctor.sh array <-> SKILL.md prose lockstep ------------------------
echo "(e) doctor.sh array and skills/doctor/SKILL.md stay in lockstep"
SKILL_LINE="$(grep -m1 'LOAD_BEARING_HOOKS' "$DOCTOR_SKILL" || true)"
if [ -z "$SKILL_LINE" ]; then
  fail_msg "(e) no LOAD_BEARING_HOOKS line in skills/doctor/SKILL.md"
elif [ -z "$LB_LINE" ]; then
  fail_msg "(e) skipped — doctor.sh has no LOAD_BEARING_HOOKS= line"
else
  # Parse the array members out of the doctor.sh assignment.
  LB_MEMBERS="$(printf '%s' "$LB_LINE" \
    | sed -e 's/^LOAD_BEARING_HOOKS=(//' -e 's/)[[:space:]]*$//' \
    | tr -d '"' | tr ' ' '\n' | grep -v '^$')"
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    if printf '%s' "$SKILL_LINE" | grep -qF "$m"; then
      pass_msg "(e) SKILL.md names load-bearing hook $m"
    else
      fail_msg "(e) SKILL.md omits load-bearing hook $m"
    fi
  done <<<"$LB_MEMBERS"
  for h in "${RETIRED[@]}"; do
    if printf '%s' "$SKILL_LINE" | grep -qF "$h"; then
      fail_msg "(e) SKILL.md LOAD_BEARING_HOOKS line still names $h"
    else
      pass_msg "(e) SKILL.md LOAD_BEARING_HOOKS line does not name $h"
    fi
  done
fi

# --- (f) allow-list -------------------------------------------------------
echo "(f) no-consumer-claude-writes.allow drops restrict_paths.py; entries resolve"
if grep -qE '^hooks/restrict_paths\.py[[:space:]]*$' "$ALLOW"; then
  fail_msg "(f) allow-list still carries hooks/restrict_paths.py"
else
  pass_msg "(f) allow-list has no hooks/restrict_paths.py entry"
fi
missing_entries=""
while IFS= read -r entry; do
  case "$entry" in
    ''|'#'*) continue ;;
  esac
  if [ ! -e "$REPO_ROOT/$entry" ]; then
    missing_entries="$missing_entries $entry"
  fi
done < "$ALLOW"
if [ -z "$missing_entries" ]; then
  pass_msg "(f) every allow-list entry resolves to an existing path"
else
  fail_msg "(f) allow-list entries do not exist:$missing_entries"
fi

# --- (g) no TRACKED file under hooks/ mentions either basename --------------
# Bare stems count too: docstrings that name `restrict_paths` as the example
# _deny_log stem, or command_mask.py's "shared by" list, are stale references
# to code the plugin no longer ships.
#
# Scope is TRACKED files only (`git ls-files hooks/`). Generated Python bytecode
# (hooks/__pycache__/*.pyc) is EXCLUDED for the same reason
# scripts/check-no-consumer-claude-writes.sh:30-43 excludes it: it is compiled
# output, not source, and its binary content embeds the module name of every
# hook that was ever imported in the worktree. Python materializes those .pyc
# files on import and `git merge` never removes gitignored files, so a stale
# block_deletions / restrict_paths .pyc outlives the merge on any checkout that
# ran the guards before they were retired — scanning it would red this test
# forever over code the plugin no longer ships.
echo "(g) no tracked file under hooks/ mentions a retired basename or stem"
HOOK_FILES="$(cd "$REPO_ROOT" && git ls-files -- hooks/ 2>/dev/null || true)"
if [ -z "$HOOK_FILES" ]; then
  # Not a git checkout (tarball install): fall back to a filesystem walk that
  # applies the same bytecode exclusion, so the assertion is never vacuous.
  HOOK_FILES="$(cd "$REPO_ROOT" && find hooks -type f \
    -not -path '*/__pycache__/*' -not -name '*.pyc' 2>/dev/null || true)"
fi
if [ -z "$HOOK_FILES" ]; then
  fail_msg "(g) no tracked file under hooks/ to scan — the assertion would be vacuous"
else
  for h in "${RETIRED[@]}" "${RETIRED[@]%.py}"; do
    hits=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$REPO_ROOT/$f" ] || continue
      if grep -qF -- "$h" "$REPO_ROOT/$f" 2>/dev/null; then
        hits="$hits $f"
      fi
    done <<<"$HOOK_FILES"
    if [ -z "$hits" ]; then
      pass_msg "(g) no tracked file under hooks/ mentions $h"
    else
      fail_msg "(g) $h still referenced by tracked file(s) under hooks/:$hits"
    fi
  done
fi

# --- (h) sole discoverable runner for tests/test_command_mask.py ------------
echo "(h) tests/test-command-mask-unittest.sh is the sole command_mask runner"
SHIM="$REPO_ROOT/tests/test-command-mask-unittest.sh"
if [ -f "$SHIM" ]; then
  pass_msg "(h) tests/test-command-mask-unittest.sh exists"
else
  fail_msg "(h) tests/test-command-mask-unittest.sh is missing"
fi
# A "runner" is a suite-discoverable shell test (the runner globs test*.sh /
# test_*.sh, never *.py) that invokes the unittest module on the file. This
# invariant test is excluded: it names the file only in assertions.
runners=""
while IFS= read -r f; do
  [ "$(basename "$f")" = "$SELF_BASENAME" ] && continue
  if grep -qE 'unittest.*test_command'"_"'mask' "$f" 2>/dev/null; then
    runners="$runners $(basename "$f")"
  fi
done < <(find "$REPO_ROOT/tests" -maxdepth 1 -type f \
           \( -name 'test*.sh' -o -name 'test_*.sh' \) | sort)
runners="${runners# }"
if [ "$runners" = "test-command-mask-unittest.sh" ]; then
  pass_msg "(h) exactly one discoverable runner: $runners"
else
  fail_msg "(h) expected sole runner test-command-mask-unittest.sh, got: '${runners:-<none>}'"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
