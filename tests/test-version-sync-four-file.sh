#!/bin/bash
set -euo pipefail
# 4-file version-sync linchpin (#982, Leg 3 of the Codex dual-target migration).
#
# release-please bumps four version fields in lockstep on every cut:
#   1. .claude-plugin/plugin.json            $.version
#   2. .claude-plugin/marketplace.json       $.metadata.version
#   3. .claude-plugin/marketplace.json       $.plugins[0].version
#   4. .codex-plugin/plugin.json             $.version          <- added by this leg
#
# BINDING CONSTRAINT (docs/release-cadence.md self-destruct rule): assert the four
# fields are SEMVER-shaped (regex) AND equal TO EACH OTHER — NEVER compare to a
# hard-coded version literal, which would self-destruct on the first release-please
# bump (the literal goes stale the moment the version changes).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO_ROOT/.claude-plugin/plugin.json"
MARKET="$REPO_ROOT/.claude-plugin/marketplace.json"
CODEX="$REPO_ROOT/.codex-plugin/plugin.json"
CFG="$REPO_ROOT/release-please-config.json"
PASS=0; FAIL=0
assert() { if eval "$2"; then echo "  PASS: $1"; PASS=$((PASS+1)); else echo "  FAIL: $1"; FAIL=$((FAIL+1)); fi; }

# Pre-reqs: all four version-bearing files exist and parse.
assert "plugin.json exists" "[ -f '$PLUGIN' ]"
assert "marketplace.json exists" "[ -f '$MARKET' ]"
assert "codex plugin.json exists" "[ -f '$CODEX' ]"
assert "release-please-config.json exists" "[ -f '$CFG' ]"

# (a) all four version fields are semver-shaped (REGEX) AND equal to each other.
#     Semver regex: ^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$ (allows pre-release).
#     NEVER a literal — equality is field-to-field so it survives every bump.
SYNC_PY='
import json,re,sys
semver=re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
plugin=json.load(open(sys.argv[1]))
market=json.load(open(sys.argv[2]))
codex=json.load(open(sys.argv[3]))
vals={
  "plugin.json $.version": plugin.get("version"),
  "marketplace.json $.metadata.version": market.get("metadata",{}).get("version"),
  "marketplace.json $.plugins[0].version": market.get("plugins",[{}])[0].get("version"),
  ".codex-plugin/plugin.json $.version": codex.get("version"),
}
# Every field must be a semver string.
for name,v in vals.items():
    if not (isinstance(v,str) and semver.match(v)):
        print(f"NOT-SEMVER: {name} = {v!r}", file=sys.stderr); sys.exit(1)
# All four must be EQUAL to each other (field-equality, no literal).
uniq=set(vals.values())
if len(uniq)!=1:
    print(f"MISMATCH: {vals}", file=sys.stderr); sys.exit(1)
sys.exit(0)
'
assert "all four version fields are semver-shaped AND equal (no literal)" \
  "python3 -c \"\$SYNC_PY\" '$PLUGIN' '$MARKET' '$CODEX' 2>/dev/null"

# (b) config guard: release-please extra-files contains the .codex-plugin/plugin.json $.version entry.
assert "extra-files bumps .codex-plugin/plugin.json (jsonpath \$.version)" \
  "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".codex-plugin/plugin.json\" and e.get(\"jsonpath\") in (\"\$.version\",\"\$[\\\"version\\\"]\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"

# (c) regression: the original three extra-file targets remain wired.
assert "regression: extra-files still bumps .claude-plugin/plugin.json \$.version" \
  "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/plugin.json\" and e.get(\"jsonpath\") in (\"\$.version\",\"\$[\\\"version\\\"]\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "regression: extra-files still bumps marketplace.json metadata.version" \
  "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and \"metadata\" in (e.get(\"jsonpath\") or \"\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"
assert "regression: extra-files still bumps marketplace.json plugins[0].version" \
  "python3 -c 'import json,sys; ef=json.load(open(\"$CFG\"))[\"packages\"][\".\"].get(\"extra-files\",[]); ok=any(isinstance(e,dict) and e.get(\"path\")==\".claude-plugin/marketplace.json\" and \"plugins\" in (e.get(\"jsonpath\") or \"\") for e in ef); sys.exit(0 if ok else 1)' 2>/dev/null"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
