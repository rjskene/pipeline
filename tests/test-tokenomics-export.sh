#!/bin/bash
set -uo pipefail
#
# Tests for scripts/tokenomics-export.sh (#1617) — the gated, redacted
# telemetry export behind `/pipeline:tokenomics --export [--post] [--dry-run]`.
#
# Hermetic: CLAUDE_PROJECT_DIR is a temp dir carrying a fixture
# .claude/logs/agent-costs.jsonl; a `gh` shim first on PATH records argv and
# answers `pr list` (the report's PR join) with [] and `issue comment` with a
# comment URL (exit ${GH_SHIM_RC:-0}, `issue comment` only).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPORT="$REPO_ROOT/scripts/tokenomics-export.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_case() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude/logs" "$TMP/bin"

# --- gh shim ---
cat > "$TMP/bin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SHIM_ARGV"
case "$1 ${2:-}" in
  "pr list")       echo '[]'; exit 0 ;;
  "issue comment") echo 'https://github.com/rjskene/pipeline/issues/1615#issuecomment-1'; exit "${GH_SHIM_RC:-0}" ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/gh"

# --- fixture: 6 schema_version:2 records -> 4 reconciled ---
# R1a/R1b share record_key rk1 (last write wins -> R1b); R2f/R2r share agent_id
# ag2 (max tokens.total -> R2r). Numbers chosen so no total / cost carries 4242.
{
  printf '%s\n' '{"schema_version":2,"agent_id":"ag1","session_id":"sess-1","record_key":"rk1","issue":"4242","description":"SECRET-DESC-zz9","stage":"plan","model":"claude-opus-4-8","agent_kind":"subagent","tokens":{"input":10,"output":20,"cache_creation":30,"cache_read":40,"total":100},"duration_ms":10,"ts_start":"2026-10-02T10:00:00Z"}'
  printf '%s\n' '{"schema_version":2,"agent_id":"ag1","session_id":"sess-1","record_key":"rk1","issue":"4242","description":"SECRET-DESC-zz9","stage":"plan","model":"claude-opus-4-8","agent_kind":"subagent","tokens":{"input":1000,"output":2000,"cache_creation":2000,"cache_read":4000,"total":9000},"duration_ms":1000,"ts_start":"2026-10-02T10:00:00Z"}'
  printf '%s\n' '{"schema_version":2,"agent_id":"ag2","session_id":"sess-2f","record_key":"rk2f","issue":"4242","description":"SECRET-DESC-zz9","stage":"execute","model":"claude-sonnet-4-6","agent_kind":"subagent","tokens":{"input":100,"output":100,"cache_creation":100,"cache_read":200,"total":500},"duration_ms":700,"ts_start":"2026-10-03T09:00:00Z"}'
  printf '%s\n' '{"schema_version":2,"agent_id":"ag2","session_id":"sess-2r","record_key":"rk2r","issue":"4242","description":"SECRET-DESC-zz9","stage":"execute","model":"claude-sonnet-4-6","agent_kind":"subagent","tokens":{"input":200,"output":300,"cache_creation":400,"cache_read":1000,"total":1900},"duration_ms":3000,"ts_start":"2026-10-03T09:00:05Z"}'
  printf '%s\n' '{"schema_version":2,"agent_id":"ag3","session_id":"sess-3","record_key":"rk3","issue":"4242","description":"SECRET-DESC-zz9","stage":"plan","model":"claude-opus-4-8","agent_kind":"main","tokens":{"input":2000,"output":1000,"cache_creation":0,"cache_read":6000,"total":9000},"duration_ms":5000,"ts_start":"2026-10-03T11:00:00Z"}'
  printf '%s\n' '{"schema_version":2,"agent_id":"ag4","session_id":"sess-4","record_key":"rk4","issue":"4242","description":"SECRET-DESC-zz9","stage":"plan","model":"","agent_kind":"main","tokens":{"input":50,"output":50,"cache_creation":0,"cache_read":0,"total":100},"duration_ms":200,"ts_start":"2026-10-05T10:00:00Z"}'
} > "$TMP/.claude/logs/agent-costs.jsonl"

run_export() {
  env -u PIPELINE_TELEMETRY_REPO -u PIPELINE_TELEMETRY_ISSUE \
      -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_INPUT -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_OUTPUT \
      -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_CREATION -u PIPELINE_PRICE_CLAUDE_OPUS_4_8_CACHE_READ \
      -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_INPUT -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_OUTPUT \
      -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_CREATION -u PIPELINE_PRICE_CLAUDE_SONNET_4_6_CACHE_READ \
      PATH="$TMP/bin:$PATH" GH_SHIM_ARGV="$TMP/gh.argv" \
      CLAUDE_PROJECT_DIR="$TMP" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
      PIPELINE_REPO="fixture-owner/secret-repo-xyz" \
      "$@"
}

approx() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a != "" && d < 1e-6) }'; }

# --- (1) gated off ---
inc_case "(1) PIPELINE_LOGS_ENABLED=false -> SKIP_LOGGING_DISABLED, exit 0, no writes"
OUT1="$(run_export PIPELINE_LOGS_ENABLED=false bash "$EXPORT" 2>/dev/null)"
RC1=$?
if [ "$RC1" -eq 0 ] && printf '%s\n' "$OUT1" | grep -F 'SKIP_LOGGING_DISABLED' | grep -qF "PIPELINE_LOGS_ENABLED='false'"; then
  pass_msg "gated-off prints SKIP_LOGGING_DISABLED (PIPELINE_LOGS_ENABLED='false') and exits 0"
else
  fail_msg "gated-off should print the skip marker and exit 0 (rc=$RC1 out=$OUT1)"
fi
if [ ! -d "$TMP/.claude/scratch/telemetry" ]; then
  pass_msg "gated-off creates no .claude/scratch/telemetry/"
else
  fail_msg "gated-off must not create .claude/scratch/telemetry/"
fi

# --- (2) export run ---
inc_case "(2) gated on -> EXPORT line + json/md files"
OUT2="$(run_export PIPELINE_LOGS_ENABLED=true bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 2>"$TMP/err2")"
RC2=$?
EXPORT_LINE="$(printf '%s\n' "$OUT2" | grep -E '^EXPORT json=.* md=.* records=4 days=' | tail -1)"
if [ "$RC2" -eq 0 ] && [ -n "$EXPORT_LINE" ]; then
  pass_msg "stdout carries 'EXPORT json=... md=... records=4 days=...'"
else
  fail_msg "expected EXPORT line with records=4 (rc=$RC2 out=$OUT2 err=$(cat "$TMP/err2"))"
fi
JSON="$(printf '%s' "$EXPORT_LINE" | sed -E 's/.*json=([^ ]+).*/\1/')"
MD="$(printf '%s' "$EXPORT_LINE" | sed -E 's/.* md=([^ ]+).*/\1/')"
case "$JSON" in "$TMP/.claude/scratch/telemetry/"*.json) J_OK=1 ;; *) J_OK=0 ;; esac
case "$MD" in "$TMP/.claude/scratch/telemetry/"*.md) M_OK=1 ;; *) M_OK=0 ;; esac
if [ "$J_OK" = 1 ] && [ "$M_OK" = 1 ] && [ -f "$JSON" ] && [ -f "$MD" ]; then
  pass_msg "json + md exist under .claude/scratch/telemetry/"
else
  fail_msg "json/md missing under .claude/scratch/telemetry/ (json=$JSON md=$MD)"
  JSON="/dev/null"; MD="/dev/null"
fi

# --- (3) top-level schema ---
inc_case "(3) top-level keys, schema_version, plugin_version, repo_id"
KEYS3="$(jq -r 'keys_unsorted | join(",")' "$JSON" 2>/dev/null)"
if [ "$KEYS3" = "schema_version,plugin_version,exported_at,window,repo_id,records_n,days,stages,kinds" ]; then
  pass_msg "top-level keys are exactly the issue's schema (in order)"
else
  fail_msg "top-level keys mismatch: [$KEYS3]"
fi
if [ "$(jq -r '.schema_version' "$JSON" 2>/dev/null)" = "1" ]; then
  pass_msg "schema_version == 1"
else
  fail_msg "schema_version should be 1"
fi
PV="$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")"
if [ "$(jq -r '.plugin_version' "$JSON" 2>/dev/null)" = "$PV" ]; then
  pass_msg "plugin_version == .claude-plugin/plugin.json .version ($PV)"
else
  fail_msg "plugin_version should be $PV, got $(jq -r '.plugin_version' "$JSON" 2>/dev/null)"
fi
RID="$(printf '%s' "fixture-owner/secret-repo-xyz" | sha256sum | cut -c1-12)"
if [ "$(jq -r '.repo_id' "$JSON" 2>/dev/null)" = "$RID" ]; then
  pass_msg "repo_id == first 12 hex of sha256(PIPELINE_REPO)"
else
  fail_msg "repo_id should be $RID, got $(jq -r '.repo_id' "$JSON" 2>/dev/null)"
fi
if [ "$(jq -r '"\(.window.since) \(.window.until)"' "$JSON" 2>/dev/null)" = "2026-10-01 2026-10-07" ] \
   && jq -r '.exported_at' "$JSON" 2>/dev/null | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  pass_msg "window {since, until} + exported_at UTC ISO-8601 Z"
else
  fail_msg "window / exported_at malformed: $(jq -c '{window, exported_at}' "$JSON" 2>/dev/null)"
fi

# --- (4) hand-computed aggregates ---
inc_case "(4) per-{stage,model} and per-agent_kind aggregates match hand-computed values"
stage_field() { jq -r --arg s "$1" --arg m "$2" ".stages[] | select(.stage==\$s and .model==\$m) | $3" "$JSON" 2>/dev/null; }
# (plan, claude-opus-4-8): R1b + R3
G1="$(stage_field plan claude-opus-4-8 '"\(.n) \(.tokens.input) \(.tokens.output) \(.tokens.cache_creation) \(.tokens.cache_read) \(.tokens.total) \(.duration_ms_p50)"')"
if [ "$G1" = "2 3000 3000 2000 10000 18000 3000" ] && approx "$(stage_field plan claude-opus-4-8 .cost_usd)" 0.1075; then
  pass_msg "(plan, claude-opus-4-8): n=2 tokens 3000/3000/2000/10000/18000 cost 0.1075 p50 3000"
else
  fail_msg "(plan, claude-opus-4-8) mismatch: [$G1] cost=$(stage_field plan claude-opus-4-8 .cost_usd)"
fi
# (execute, claude-sonnet-4-6): R2r only (the pair collapses)
G2="$(stage_field execute claude-sonnet-4-6 '"\(.n) \(.tokens.input) \(.tokens.output) \(.tokens.cache_creation) \(.tokens.cache_read) \(.tokens.total) \(.duration_ms_p50)"')"
if [ "$G2" = "1 200 300 400 1000 1900 3000" ] && approx "$(stage_field execute claude-sonnet-4-6 .cost_usd)" 0.0069; then
  pass_msg "(execute, claude-sonnet-4-6): n=1 tokens 200/300/400/1000/1900 cost 0.0069 p50 3000"
else
  fail_msg "(execute, claude-sonnet-4-6) mismatch: [$G2] cost=$(stage_field execute claude-sonnet-4-6 .cost_usd)"
fi
# (plan, ""): unpriced -> cost 0
G3="$(stage_field plan '' '"\(.n) \(.tokens.total) \(.duration_ms_p50)"')"
if [ "$G3" = "1 100 200" ] && approx "$(stage_field plan '' .cost_usd)" 0; then
  pass_msg "(plan, \"\"): n=1 total 100 cost 0 (unpriced) p50 200"
else
  fail_msg "(plan, \"\") mismatch: [$G3] cost=$(stage_field plan '' .cost_usd)"
fi
if [ "$(jq -r '.stages | length' "$JSON" 2>/dev/null)" = "3" ] \
   && [ "$(jq -r '[.stages[].cost_usd] == ([.stages[].cost_usd] | sort | reverse)' "$JSON" 2>/dev/null)" = "true" ]; then
  pass_msg "3 stage groups, sorted by cost_usd desc"
else
  fail_msg "stages should be 3 groups sorted by cost desc: $(jq -c '.stages' "$JSON" 2>/dev/null)"
fi
kind_field() { jq -r --arg k "$1" ".kinds[] | select(.agent_kind==\$k) | $2" "$JSON" 2>/dev/null; }
if [ "$(kind_field subagent .n)" = "2" ] && approx "$(kind_field subagent .cost_usd)" 0.0764 \
   && [ "$(kind_field main .n)" = "2" ] && approx "$(kind_field main .cost_usd)" 0.038; then
  pass_msg "kinds: subagent n=2 cost 0.0764; main n=2 cost 0.038"
else
  fail_msg "kinds mismatch: $(jq -c '.kinds' "$JSON" 2>/dev/null)"
fi
if [ "$(jq -r '[.days[].date] | join(",")' "$JSON" 2>/dev/null)" = "2026-10-02,2026-10-03,2026-10-05" ] \
   && [ "$(jq -r '.records_n' "$JSON" 2>/dev/null)" = "4" ]; then
  pass_msg "days[].date == {2026-10-02, 2026-10-03, 2026-10-05}; records_n == 4"
else
  fail_msg "days / records_n mismatch: $(jq -c '{records_n, d: [.days[].date]}' "$JSON" 2>/dev/null)"
fi

# --- (5) redaction ---
inc_case "(5) redaction: no ids, issue numbers, descriptions, repo name or paths"
for tok in agent_id session_id record_key '"issue"' 4242 secret-repo-xyz SECRET-DESC-zz9 "$TMP" /home/; do
  hits="$(cat "$JSON" "$MD" | grep -cF -- "$tok")"
  if [ "$hits" = "0" ]; then
    pass_msg "no '$tok' in json or md"
  else
    fail_msg "'$tok' leaked into the export ($hits hit(s))"
  fi
done

# --- (6) markdown shape ---
inc_case "(6) md header line + stages table + days table"
L1="$(head -1 "$MD")"
if printf '%s' "$L1" | grep -qF "plugin $PV" && printf '%s' "$L1" | grep -qF '2026-10-01' \
   && printf '%s' "$L1" | grep -qF '2026-10-07' && printf '%s' "$L1" | grep -qF "repo_id $RID" \
   && printf '%s' "$L1" | grep -qF 'records 4'; then
  pass_msg "md first line names plugin version, window, repo_id, records"
else
  fail_msg "md first line malformed: [$L1]"
fi
ST_LN="$(grep -n '^| stage |' "$MD" | head -1 | cut -d: -f1)"
DY_LN="$(grep -n '^| date |' "$MD" | head -1 | cut -d: -f1)"
if [ -n "$ST_LN" ] && [ -n "$DY_LN" ] && [ "$ST_LN" -lt "$DY_LN" ] \
   && grep -q '^| 2026-10-03 |' "$MD" && grep -q '^| plan | claude-opus-4-8 |' "$MD"; then
  pass_msg "md carries a stages table followed by a days table"
else
  fail_msg "md should carry a stages table then a days table: $(cat "$MD")"
fi

# --- (7) --post --dry-run ---
inc_case "(7) --post --dry-run prints the body + the exact gh command, calls no gh comment"
: > "$TMP/gh.argv"
OUT7="$(run_export PIPELINE_LOGS_ENABLED=true bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 --post --dry-run 2>/dev/null)"
RC7=$?
BODY7="$(printf '%s\n' "$OUT7" | grep -oE 'gh issue comment 1615 --repo rjskene/pipeline --body-file [^ ]+$' | sed -E 's/.*--body-file //')"
if [ "$RC7" -eq 0 ] && [ -n "$BODY7" ] && [ -f "$BODY7" ]; then
  pass_msg "dry-run prints 'gh issue comment 1615 --repo rjskene/pipeline --body-file <path>' (path exists)"
else
  fail_msg "dry-run should print the exact gh command line (rc=$RC7 out=$OUT7)"
fi
MD_LN7="$(printf '%s\n' "$OUT7" | grep -n '^plugin ' | head -1 | cut -d: -f1)"
FENCE_LN7="$(printf '%s\n' "$OUT7" | grep -n '^```json$' | head -1 | cut -d: -f1)"
if [ -n "$MD_LN7" ] && [ -n "$FENCE_LN7" ] && [ "$MD_LN7" -lt "$FENCE_LN7" ] \
   && printf '%s\n' "$OUT7" | grep -q '"schema_version"'; then
  pass_msg "dry-run prints the body: md, then a \`\`\`json fenced block holding the JSON"
else
  fail_msg "dry-run body should be md then a json fence: $OUT7"
fi
if grep -q '^issue comment' "$TMP/gh.argv"; then
  fail_msg "dry-run must not call gh issue comment ($(cat "$TMP/gh.argv"))"
else
  pass_msg "dry-run makes no gh issue comment call"
fi

# --- (8) --post ---
inc_case "(8) --post files the body on rjskene/pipeline#1615"
: > "$TMP/gh.argv"
OUT8="$(run_export PIPELINE_LOGS_ENABLED=true bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 --post 2>/dev/null)"
RC8=$?
if grep -qE '^issue comment 1615 --repo rjskene/pipeline --body-file [^ ]+\.body\.md$' "$TMP/gh.argv"; then
  pass_msg "gh shim recorded 'issue comment 1615 --repo rjskene/pipeline --body-file <path>'"
else
  fail_msg "--post should call gh issue comment 1615 --repo rjskene/pipeline --body-file <path> (argv: $(cat "$TMP/gh.argv"))"
fi
if [ "$RC8" -eq 0 ] && printf '%s\n' "$OUT8" | grep -qxF 'POSTED url=https://github.com/rjskene/pipeline/issues/1615#issuecomment-1'; then
  pass_msg "stdout carries POSTED url=<comment url>"
else
  fail_msg "expected POSTED url=... (rc=$RC8 out=$OUT8)"
fi

# --- (9) POST-FAILED ---
inc_case "(9) a failing gh issue comment -> POST-FAILED rc=1, exit 0, files kept"
OUT9="$(run_export PIPELINE_LOGS_ENABLED=true GH_SHIM_RC=1 bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 --post 2>/dev/null)"
RC9=$?
J9="$(printf '%s\n' "$OUT9" | grep '^EXPORT ' | sed -E 's/.*json=([^ ]+).*/\1/')"
M9="$(printf '%s\n' "$OUT9" | grep '^EXPORT ' | sed -E 's/.* md=([^ ]+).*/\1/')"
if [ "$RC9" -eq 0 ] && printf '%s\n' "$OUT9" | grep -qxF 'POST-FAILED rc=1' && [ -f "$J9" ] && [ -f "$M9" ]; then
  pass_msg "POST-FAILED rc=1, exit 0, json/md still exist"
else
  fail_msg "expected POST-FAILED rc=1 + exit 0 + files kept (rc=$RC9 out=$OUT9)"
fi
if printf '%s\n' "$OUT9" | grep -q '^POSTED'; then
  fail_msg "a failed post must not print POSTED"
else
  pass_msg "a failed post prints no POSTED line"
fi

# --- (10) knob override ---
inc_case "(10) PIPELINE_TELEMETRY_REPO / PIPELINE_TELEMETRY_ISSUE retarget the post"
: > "$TMP/gh.argv"
run_export PIPELINE_LOGS_ENABLED=true PIPELINE_TELEMETRY_REPO=o/r PIPELINE_TELEMETRY_ISSUE=7 \
  bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 --post >/dev/null 2>&1
if grep -qE '^issue comment 7 --repo o/r --body-file ' "$TMP/gh.argv"; then
  pass_msg "post targets 'issue comment 7 --repo o/r'"
else
  fail_msg "override should target issue comment 7 --repo o/r (argv: $(cat "$TMP/gh.argv"))"
fi

# --- (11) consent contract ---
inc_case "(11) without --post no gh issue comment is ever made"
: > "$TMP/gh.argv"
run_export PIPELINE_LOGS_ENABLED=true bash "$EXPORT" --since 2026-10-01 --until 2026-10-07 >/dev/null 2>&1
if grep -q '^issue comment' "$TMP/gh.argv"; then
  fail_msg "export without --post called gh issue comment ($(cat "$TMP/gh.argv"))"
else
  pass_msg "no --post -> no gh issue comment"
fi

# --- (12) pipeline.config.example knobs ---
inc_case "(12) pipeline.config.example documents the telemetry knobs; script reads them with defaults"
EXAMPLE="$REPO_ROOT/pipeline.config.example"
if grep -qxF '#PIPELINE_TELEMETRY_REPO="rjskene/pipeline"' "$EXAMPLE" \
   && grep -qxF '#PIPELINE_TELEMETRY_ISSUE=1615' "$EXAMPLE"; then
  pass_msg "example carries the commented #PIPELINE_TELEMETRY_REPO / #PIPELINE_TELEMETRY_ISSUE keys"
else
  fail_msg "example must carry #PIPELINE_TELEMETRY_REPO=\"rjskene/pipeline\" and #PIPELINE_TELEMETRY_ISSUE=1615"
fi
BLOCK12="$(sed -n '/^# --- Telemetry export (#1617) ---/,/^#PIPELINE_TELEMETRY_ISSUE=/p' "$EXAMPLE")"
if printf '%s' "$BLOCK12" | grep -qF -- '--post' && printf '%s' "$BLOCK12" | grep -qiF 'public' \
   && printf '%s' "$BLOCK12" | grep -qF 'gh identity'; then
  pass_msg "the telemetry comment block mentions --post, public and gh identity"
else
  fail_msg "the '# --- Telemetry export (#1617) ---' block must mention --post, public and gh identity"
fi
if grep -qF '${PIPELINE_TELEMETRY_REPO:-rjskene/pipeline}' "$EXPORT" \
   && grep -qF '${PIPELINE_TELEMETRY_ISSUE:-1615}' "$EXPORT"; then
  pass_msg "script reads \${PIPELINE_TELEMETRY_REPO:-rjskene/pipeline} / \${PIPELINE_TELEMETRY_ISSUE:-1615}"
else
  fail_msg "script must read the telemetry knobs with :- defaults"
fi

# --- (13) skill surface ---
inc_case "(13) skills/tokenomics/SKILL.md documents --export"
SKILL13="$REPO_ROOT/skills/tokenomics/SKILL.md"
DESC13="$(awk 'NR==1 && /^---$/ {fm=1; next} fm && /^---$/ {exit} fm && /^description:/ {print}' "$SKILL13")"
if printf '%s' "$DESC13" | grep -qF -- '--export'; then
  pass_msg "frontmatter description names --export"
else
  fail_msg "frontmatter description must name --export (got: $DESC13)"
fi
for tok in EXPORT POSTED POST-FAILED; do
  if grep -qw -- "$tok" "$SKILL13"; then
    pass_msg "SKILL.md body names $tok"
  else
    fail_msg "SKILL.md body must name $tok"
  fi
done

# --- (14) a trailing --since / --until with no value fails fast ---
inc_case "(14) a trailing --since / --until with no value exits 1 (no hang)"
for flag in --since --until; do
  timeout 20 env PIPELINE_LOGS_ENABLED=true PIPELINE_REPO=o/r CLAUDE_PROJECT_DIR="$TMP" bash "$EXPORT" "$flag" >/dev/null 2>&1
  RC14=$?
  if [ "$RC14" -eq 1 ]; then
    pass_msg "trailing $flag -> exit 1"
  else
    fail_msg "trailing $flag should exit 1, got rc=$RC14 (124 = hung)"
  fi
done

echo ""
echo "== RESULTS =="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
