#!/bin/bash
set -uo pipefail

# Coverage for #624: doctor's dogfood_symlink_durable check.
#
# When the pipeline@claude-pipeline-local entry for THIS repo exists in
# installed_plugins.json, doctor verifies its installPath is a live symlink to
# the repo working tree:
#   (a) symlink → matching projectPath        ⇒ status=pass
#   (b) installPath is a real directory       ⇒ status=warn + heal hint
#   (c) installPath path missing (cache wiped) ⇒ status=warn + heal hint
#   (d) no local entry at all (consumer)       ⇒ NO check line emitted
#   (e) the warn cases record status=warn, never status=fail (warn is non-fatal;
#       consumer machines stay green).
#
# The check reads PIPELINE_INSTALLED_PLUGINS_JSON (test override). Modeled on
# tests/test-doctor-claude-plugin-root-local-override.sh — run the real doctor
# against a hermetic HOME + fake git repo and grep the CHECK line. Other doctor
# checks may exit non-zero in this harness; we only inspect our CHECK line.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Hermetic fake repo. doctor matches the local entry by git toplevel, so the
# fixture's projectPath must equal what doctor resolves for this repo.
FAKE_REPO="$TMP/repo"
mkdir -p "$FAKE_REPO/.claude-plugin"
printf '{}' > "$FAKE_REPO/.claude-plugin/plugin.json"
GIT_CONFIG_GLOBAL=/dev/null git -C "$FAKE_REPO" init -q
ROOT="$(cd "$FAKE_REPO" && git rev-parse --show-toplevel 2>/dev/null || echo "$FAKE_REPO")"

HHOME="$TMP/home"
mkdir -p "$HHOME"

write_ip() {
  # Args: <file> <projectPath> <installPath>   (installPath omitted ⇒ no local entry)
  local F="$1" PP="${2:-}" IP="${3:-}"
  if [ -z "$PP" ]; then
    cat > "$F" <<'JSON'
{ "plugins": { "some-other-plugin@market": [] } }
JSON
  else
    cat > "$F" <<JSON
{
  "plugins": {
    "pipeline@claude-pipeline-local": [
      { "projectPath": "$PP", "installPath": "$IP", "marketplace": "claude-pipeline-local" }
    ]
  }
}
JSON
  fi
}

run_doctor() {
  # Args: <installed_plugins_json>  → prints the dogfood_symlink_durable CHECK line(s)
  local IPJSON="$1"
  (
    cd "$FAKE_REPO"
    HOME="$HHOME" \
    PIPELINE_USE_LOCAL_PLUGIN=true \
    PIPELINE_BASE_BRANCH=staging \
    PIPELINE_INSTALLED_PLUGINS_JSON="$IPJSON" \
      bash "$REPO_ROOT/scripts/doctor.sh" 2>&1 || true
  ) | grep -E '^CHECK: dogfood_symlink_durable ' || true
}

# (a) symlink → matching projectPath ⇒ pass.
IPJSON="$TMP/ip-a.json"
INSTALL="$TMP/cache-a"
ln -s "$ROOT" "$INSTALL"
write_ip "$IPJSON" "$ROOT" "$INSTALL"
LINE="$(run_doctor "$IPJSON" | tail -n1)"
case "$LINE" in
  *"status=pass"*) pass_msg "(a) symlink → projectPath ⇒ status=pass" ;;
  *) fail_msg "(a) expected status=pass; got: $LINE" ;;
esac
rm -f "$INSTALL"

# (b) installPath is a real directory ⇒ warn + heal hint.
IPJSON="$TMP/ip-b.json"
INSTALL="$TMP/cache-b"
mkdir -p "$INSTALL"
write_ip "$IPJSON" "$ROOT" "$INSTALL"
LINE="$(run_doctor "$IPJSON" | tail -n1)"
case "$LINE" in
  *"status=warn"*"dogfood-heal-symlink.sh"*) pass_msg "(b) real dir ⇒ status=warn + heal hint" ;;
  *) fail_msg "(b) expected status=warn + heal hint; got: $LINE" ;;
esac
rm -rf "$INSTALL"

# (c) installPath missing (cache wiped) ⇒ warn + heal hint.
IPJSON="$TMP/ip-c.json"
INSTALL="$TMP/cache-c-missing"
write_ip "$IPJSON" "$ROOT" "$INSTALL"   # INSTALL never created
LINE="$(run_doctor "$IPJSON" | tail -n1)"
case "$LINE" in
  *"status=warn"*"dogfood-heal-symlink.sh"*) pass_msg "(c) missing path ⇒ status=warn + heal hint" ;;
  *) fail_msg "(c) expected status=warn + heal hint; got: $LINE" ;;
esac

# (d) no local entry (consumer) ⇒ no CHECK line emitted.
IPJSON="$TMP/ip-d.json"
write_ip "$IPJSON" ""   # no pipeline@claude-pipeline-local entry
OUT="$(run_doctor "$IPJSON")"
if [ -z "$OUT" ]; then
  pass_msg "(d) no local entry ⇒ no dogfood_symlink_durable CHECK line"
else
  fail_msg "(d) expected no CHECK line on consumer install; got: $OUT"
fi

# (e) warn cases never record status=fail.
if run_doctor "$TMP/ip-c.json" | grep -q "status=fail"; then
  fail_msg "(e) warn case must NOT record status=fail"
else
  pass_msg "(e) warn case records warn, never fail (non-fatal on consumer machines)"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
