#!/usr/bin/env bash
# test-doctor-on-update-detector.sh — contract test for the thin, read-only
# plugin-version-change detector hook (hooks/doctor-on-update.sh, issue #1038).
#
# The hook is wired into UserPromptSubmit (primary, no lag) + SessionStart
# (backstop). On EVERY invocation it must:
#   - be a CHEAP no-op when the resolved plugin version == the cached marker
#     (pure string compare; NO network, no marker rewrite, no injection);
#   - on a version DELTA, emit stdout-JSON injection with
#     hookSpecificOutput.additionalContext (model-facing directive to run the
#     /pipeline:doctor reconcile) AND systemMessage (operator banner), then
#     update the marker so it fires once per update;
#   - honor PIPELINE_DOCTOR_ON_UPDATE_ENABLED (default true); false -> no-op;
#   - FAIL OPEN: exit 0 on EVERY error (corrupt plugin.json, missing marker
#     dir, unset CLAUDE_PLUGIN_ROOT) and NEVER block a prompt/session.
#
# Hermetic: a temp fixture CLAUDE_PLUGIN_ROOT with its own plugin.json and a
# temp CLAUDE_PROJECT_DIR for the marker under .claude/logs/.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO_ROOT/hooks/doctor-on-update.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HOOK" ]; then
  echo "ERROR: $HOOK not found" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PLUGIN="$WORK/plugin"
PROJ="$WORK/project"
mkdir -p "$PLUGIN/.claude-plugin" "$PROJ/.claude/logs"
MARKER="$PROJ/.claude/logs/.doctor-on-update-version"

write_plugin_version() {
  printf '{\n  "name": "pipeline",\n  "version": "%s"\n}\n' "$1" > "$PLUGIN/.claude-plugin/plugin.json"
}

# run_hook <stdin-json> — invokes the hook with the fixture env. Echoes stdout.
run_hook() {
  CLAUDE_PLUGIN_ROOT="$PLUGIN" \
  CLAUDE_PROJECT_DIR="$PROJ" \
  printf '%s' "${1:-}" \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK"
}

# ---------------------------------------------------------------------------
# Case 1: version DELTA -> injection emitted, marker updated, exit 0.
# ---------------------------------------------------------------------------
write_plugin_version "0.0.2"
printf '0.0.1' > "$MARKER"
OUT="$(run_hook '{"hook_event_name":"UserPromptSubmit","prompt":"hi"}')"
RC=$?

[ "$RC" -eq 0 ] && pass_msg "delta: exit 0" || fail_msg "delta: expected exit 0, got $RC"

if printf '%s' "$OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  pass_msg "delta: stdout is valid JSON"
else
  fail_msg "delta: stdout is NOT valid JSON"
fi
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("hookSpecificOutput",{}).get("additionalContext") else 1)' 2>/dev/null; then
  pass_msg "delta: hookSpecificOutput.additionalContext present"
else
  fail_msg "delta: hookSpecificOutput.additionalContext missing"
fi
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ac=d.get("hookSpecificOutput",{}).get("additionalContext",""); sys.exit(0 if "doctor" in ac.lower() else 1)' 2>/dev/null; then
  pass_msg "delta: additionalContext directs the doctor reconcile"
else
  fail_msg "delta: additionalContext does not mention doctor"
fi
# systemMessage is dead code for UserPromptSubmit/SessionStart (Claude Code does
# not render it to the operator for those events) — assert it is ABSENT (#1047).
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if "systemMessage" not in d else 1)' 2>/dev/null; then
  pass_msg "delta: no dead systemMessage field"
else
  fail_msg "delta: systemMessage field still present (dead channel)"
fi
# The working operator surface is the model relaying additionalContext, so the
# directive must instruct a distinct, recognizable header line (#1047).
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ac=d.get("hookSpecificOutput",{}).get("additionalContext",""); sys.exit(0 if "🔄 plugin updated" in ac else 1)' 2>/dev/null; then
  pass_msg "delta: additionalContext instructs the recognizable header"
else
  fail_msg "delta: additionalContext missing the recognizable header"
fi
if printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); ac=d.get("hookSpecificOutput",{}).get("additionalContext",""); sys.exit(0 if ("0.0.1" in ac and "0.0.2" in ac) else 1)' 2>/dev/null; then
  pass_msg "delta: header names the v0.0.1 -> v0.0.2 delta"
else
  fail_msg "delta: header does not name the version delta"
fi
if [ "$(cat "$MARKER")" = "0.0.2" ]; then
  pass_msg "delta: marker updated to 0.0.2"
else
  fail_msg "delta: marker not updated (got '$(cat "$MARKER")')"
fi

# ---------------------------------------------------------------------------
# Case 2: SAME version -> cheap silent no-op (no injection), exit 0.
# Marker already 0.0.2 from case 1. Capture marker mtime to assert no rewrite.
# ---------------------------------------------------------------------------
MTIME_BEFORE="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER")"
sleep 1
OUT2="$(run_hook '{"hook_event_name":"UserPromptSubmit","prompt":"again"}')"
RC2=$?
[ "$RC2" -eq 0 ] && pass_msg "no-op: exit 0" || fail_msg "no-op: expected exit 0, got $RC2"
if [ -z "$OUT2" ]; then
  pass_msg "no-op: empty stdout (no injection on unchanged version)"
else
  # Allow whitespace-only, but no JSON injection.
  if printf '%s' "$OUT2" | grep -q 'additionalContext\|systemMessage'; then
    fail_msg "no-op: injection emitted on unchanged version"
  else
    pass_msg "no-op: no injection emitted on unchanged version"
  fi
fi
MTIME_AFTER="$(stat -c %Y "$MARKER" 2>/dev/null || stat -f %m "$MARKER")"
if [ "$MTIME_BEFORE" = "$MTIME_AFTER" ]; then
  pass_msg "no-op: marker not rewritten on unchanged version"
else
  fail_msg "no-op: marker rewritten on unchanged version"
fi

# ---------------------------------------------------------------------------
# Case 3: opt-out -> PIPELINE_DOCTOR_ON_UPDATE_ENABLED=false suppresses even a
# real delta.
# ---------------------------------------------------------------------------
write_plugin_version "0.0.3"
OUT3="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJ" PIPELINE_DOCTOR_ON_UPDATE_ENABLED=false \
        bash -c 'printf "%s" "{}" | bash "$0"' "$HOOK")"
RC3=$?
[ "$RC3" -eq 0 ] && pass_msg "opt-out: exit 0" || fail_msg "opt-out: expected exit 0, got $RC3"
if printf '%s' "$OUT3" | grep -q 'additionalContext\|systemMessage'; then
  fail_msg "opt-out: injection emitted despite opt-out"
else
  pass_msg "opt-out: no injection when disabled"
fi
# Marker must NOT have advanced to 0.0.3 (the detector did nothing).
if [ "$(cat "$MARKER")" != "0.0.3" ]; then
  pass_msg "opt-out: marker not advanced when disabled"
else
  fail_msg "opt-out: marker advanced despite opt-out"
fi

# ---------------------------------------------------------------------------
# Case 4: fail-open — corrupt plugin.json -> exit 0, no crash, no injection.
# ---------------------------------------------------------------------------
printf 'not-json{' > "$PLUGIN/.claude-plugin/plugin.json"
OUT4="$(run_hook '{}')"; RC4=$?
[ "$RC4" -eq 0 ] && pass_msg "fail-open(corrupt json): exit 0" || fail_msg "fail-open(corrupt json): exit $RC4"
if printf '%s' "$OUT4" | grep -q 'additionalContext\|systemMessage'; then
  fail_msg "fail-open(corrupt json): emitted injection from unparseable version"
else
  pass_msg "fail-open(corrupt json): no injection"
fi

# ---------------------------------------------------------------------------
# Case 5: fail-open — unset CLAUDE_PLUGIN_ROOT -> exit 0, no crash.
# ---------------------------------------------------------------------------
OUT5="$(env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$PROJ" bash -c 'printf "%s" "{}" | bash "$0"' "$HOOK")"
RC5=$?
[ "$RC5" -eq 0 ] && pass_msg "fail-open(unset root): exit 0" || fail_msg "fail-open(unset root): exit $RC5"

# ---------------------------------------------------------------------------
# Case 6: first-run bootstrap — no marker file yet, real version present.
# Should emit injection (treat absent marker as a change) and CREATE the marker,
# without crashing. mkdir -p of .claude/logs is the hook's responsibility.
# ---------------------------------------------------------------------------
PROJ2="$WORK/project2"
mkdir -p "$PROJ2"
write_plugin_version "1.2.3"
OUT6="$(CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$PROJ2" bash -c 'printf "%s" "{}" | bash "$0"' "$HOOK")"
RC6=$?
[ "$RC6" -eq 0 ] && pass_msg "bootstrap: exit 0" || fail_msg "bootstrap: exit $RC6"
if [ -f "$PROJ2/.claude/logs/.doctor-on-update-version" ] \
   && [ "$(cat "$PROJ2/.claude/logs/.doctor-on-update-version")" = "1.2.3" ]; then
  pass_msg "bootstrap: marker created at 1.2.3 under .claude/logs/"
else
  fail_msg "bootstrap: marker not created under .claude/logs/"
fi

# ---------------------------------------------------------------------------
# Case 7: registration — the PUBLISHED manifest registers the detector on BOTH
# UserPromptSubmit and SessionStart, and the dogfood settings.json mirrors it.
# ---------------------------------------------------------------------------
MANIFEST="$REPO_ROOT/.claude-plugin/plugin.json"
SETTINGS="$REPO_ROOT/.claude/settings.json"

if command -v jq >/dev/null 2>&1; then
  # Published manifest parses as JSON.
  if jq -e . "$MANIFEST" >/dev/null 2>&1; then
    pass_msg "published manifest is valid JSON"
  else
    fail_msg "published manifest is not valid JSON"
  fi
  for evt in UserPromptSubmit SessionStart; do
    if jq -e --arg e "$evt" \
         '.hooks[$e][]?.hooks[]?.command | select(test("doctor-on-update.sh"))' \
         "$MANIFEST" >/dev/null 2>&1; then
      pass_msg "manifest registers doctor-on-update.sh on $evt"
    else
      fail_msg "manifest does NOT register doctor-on-update.sh on $evt"
    fi
  done
  # Dogfood settings mirrors both events (read via git blob if the live file is
  # hook-protected from a plain read; here a direct jq is fine in CI).
  if [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
    for evt in UserPromptSubmit SessionStart; do
      if jq -e --arg e "$evt" \
           '.hooks[$e][]?.hooks[]?.command | select(test("doctor-on-update.sh"))' \
           "$SETTINGS" >/dev/null 2>&1; then
        pass_msg "dogfood settings registers doctor-on-update.sh on $evt"
      else
        fail_msg "dogfood settings does NOT register doctor-on-update.sh on $evt"
      fi
    done
  else
    fail_msg "dogfood settings.json missing or invalid JSON"
  fi
else
  echo "  SKIP: jq not available — registration assertions skipped"
fi

echo ""
echo "================================"
echo "  test-doctor-on-update-detector: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
