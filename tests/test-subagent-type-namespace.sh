#!/usr/bin/env bash
set -euo pipefail

# Regression guard for issue #1238 — the `subagent_type` dispatch string used
# for the plugin-registered tdd-implementer agent.
#
# The agent registry exposes the agent under its PLUGIN-NAMESPACED name,
# `<plugin.json name>:<agent frontmatter name>` = `pipeline:tdd-implementer`.
# A dispatch that uses the BARE `tdd-implementer` string does not resolve and
# hard-fails, so every PATH C fan-out / PATH D collapsed dispatch that follows
# the skill prose dies before a single leaf starts.
#
# TWO structurally different matchers are required, because the two classes of
# site look nothing alike:
#
#   A2 — "prescribes a dispatch value". Keys on `subagent_type`-adjacency,
#        e.g. `Agent(subagent_type='tdd-implementer', ...)` in skill prose.
#   A7 — "consumes a dispatch value". Keys on COMPARISON SHAPE in executable
#        code, because the runtime consumers compare a variable that was read
#        out of the log record ~170 lines earlier — the field name is nowhere
#        near the literal (`[ "$st" = "tdd-implementer" ]`).
#
# A6 and A8 are the mandatory negative controls: a guard that greps for "no bad
# string exists" passes vacuously the moment its regex breaks, so each matcher
# is proven to FIRE on a known-bad fixture.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

cd "$ROOT"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# --- matcher A2: a BARE `subagent_type` dispatch literal ------------------
# `subagent_type` + `:`/`=` + optional quote + `tdd-implementer`. The namespaced
# form (`'pipeline:tdd-implementer'`, `"pipeline:tdd-implementer"`, unquoted)
# does NOT match, because `pipeline:` sits between the quote and the agent name.
A2_RE="subagent_type[[:space:]]*[:=][[:space:]]*['\"]?tdd-implementer"
a2_hits() {
  grep -I -H -nE "$A2_RE" "$@" 2>/dev/null || true
}

# --- matcher A7: an exact-equality comparison against the BARE literal -----
# Scoped to executable code (scripts/ + hooks/). Lines that already suffix-
# normalize (`${x##*:}` in sh, `.rsplit(":", 1)` in python) are exempt: they
# accept BOTH forms and are the intended fix shape.
A7_RE='(==|!=|[^<>=!~+-]=)[[:space:]]*"tdd-implementer"'
a7_hits() {
  grep -I -H -nE "$A7_RE" "$@" 2>/dev/null | grep -vE '##\*:|rsplit\(":"' || true
}

echo "Subagent-type namespace resolution (#1238)"

# =====================================================================
# A1 — the canonical form is DERIVED from the plugin manifest, not
#      hard-coded. `pipeline` is plugin.json's `name` (NOT the marketplace
#      name in marketplace.json).
# =====================================================================
echo "A1: canonical subagent_type form derived from the plugin manifest"
inc
PLUGIN_NAME=$(python3 -c 'import json; print(json.load(open(".claude-plugin/plugin.json"))["name"])' 2>/dev/null || echo "")
AGENT_REL=$(python3 -c '
import json, os
m = json.load(open(".claude-plugin/plugin.json"))
hits = [p for p in m.get("agents", []) if os.path.basename(p) == "tdd-implementer.md"]
print(hits[0] if hits else "")
' 2>/dev/null || echo "")
AGENT_NAME=""
if [ -n "$AGENT_REL" ] && [ -f "$AGENT_REL" ]; then
  AGENT_NAME=$(sed -n 's/^name:[[:space:]]*//p' "$AGENT_REL" | head -n1)
fi
CANONICAL="${PLUGIN_NAME}:${AGENT_NAME}"
if [ "$CANONICAL" = "pipeline:tdd-implementer" ]; then
  pass_msg "derived canonical form = $CANONICAL"
else
  fail_msg "derived form '$CANONICAL' != 'pipeline:tdd-implementer' (plugin='$PLUGIN_NAME' agents[]='$AGENT_REL' frontmatter name='$AGENT_NAME')"
fi

# =====================================================================
# A2 — no BARE dispatch literal survives in any tracked non-test source.
#      `git ls-files` is the file source (it excludes untracked scratch
#      dirs for free); `tests/` is excluded because this guard and the
#      repinned tests necessarily contain the bare literal, and
#      CHANGELOG.md is excluded as immutable release history.
# =====================================================================
echo "A2: no BARE subagent_type=tdd-implementer literal outside tests/"
inc
SCAN_FILES=()
while IFS= read -r f; do
  case "$f" in
    tests/*|CHANGELOG.md) continue ;;
  esac
  [ -f "$f" ] || continue
  SCAN_FILES+=("$f")
done < <(git ls-files)
if [ "${#SCAN_FILES[@]}" -eq 0 ]; then
  fail_msg "A2: git ls-files produced zero scannable files — the guard would pass vacuously"
else
  A2_OUT=$(a2_hits "${SCAN_FILES[@]}")
  if [ -z "$A2_OUT" ]; then
    pass_msg "zero bare subagent_type=tdd-implementer literals across ${#SCAN_FILES[@]} tracked non-test files"
  else
    fail_msg "bare subagent_type=tdd-implementer literal(s) still present ($(printf '%s\n' "$A2_OUT" | wc -l | tr -d ' ') hit(s)):"
    printf '%s\n' "$A2_OUT" | cut -c1-140 | sed 's/^/    /'
  fi
fi

# =====================================================================
# A3 — non-vacuity: each prescribing site must CARRY the namespaced
#      literal. Without this, deleting a site would satisfy A2.
# =====================================================================
echo "A3: each prescribing site carries the namespaced literal"
A3_SITES=(
  "skills/fullsend/SKILL.md"
  "skills/execute-issue-plan/SKILL.md"
  "skills/plan-issue/SKILL.md"
  "skills/hotfix/SKILL.md"
  "hooks/enforce-path-c-delegation.py"
  "docs/architecture.md"
)
for site in "${A3_SITES[@]}"; do
  inc
  if [ ! -f "$site" ]; then
    fail_msg "A3: prescribing site missing from the tree: $site"
  elif grep -n 'subagent_type' "$site" | grep -qF 'pipeline:tdd-implementer'; then
    pass_msg "A3: $site carries a subagent_type + pipeline:tdd-implementer line"
  else
    fail_msg "A3: $site has NO line carrying both subagent_type and pipeline:tdd-implementer"
  fi
done

# =====================================================================
# A4 — partial-edit guard: fullsend carries FOUR bare dispatch literals
#      today (the PATH C fan-out sentence and the PATH D sentence share a
#      line, plus the PATH C and PATH D dispatch bullets). All four must
#      flip together.
# =====================================================================
echo "A4: fullsend carries >= 4 namespaced dispatch literals"
inc
A4_COUNT=$( { grep -o "subagent_type='pipeline:tdd-implementer'" skills/fullsend/SKILL.md || true; } | wc -l | tr -d ' ')
if [ "${A4_COUNT:-0}" -ge 4 ]; then
  pass_msg "skills/fullsend/SKILL.md has $A4_COUNT subagent_type='pipeline:tdd-implementer' literals (>= 4)"
else
  fail_msg "skills/fullsend/SKILL.md has only $A4_COUNT subagent_type='pipeline:tdd-implementer' literals, expected >= 4 (partial edit)"
fi

# =====================================================================
# A5 — the actively-wrong instruction is gone, and replaced by prose that
#      names the form which actually resolves.
# =====================================================================
echo "A5: the 'NOT a namespaced form' instruction is gone"
inc
if grep -qF 'NOT a namespaced form' skills/fullsend/SKILL.md; then
  fail_msg "skills/fullsend/SKILL.md still directs dispatchers with 'NOT a namespaced form' (#1238)"
else
  pass_msg "'NOT a namespaced form' instruction removed from fullsend"
fi
inc
if grep -F 'pipeline:tdd-implementer' skills/fullsend/SKILL.md | grep -qi 'resolv'; then
  pass_msg "fullsend names pipeline:tdd-implementer as the form that resolves"
else
  fail_msg "fullsend has no sentence naming pipeline:tdd-implementer as the resolving form"
fi

# =====================================================================
# A6 — negative control for A2 (mandatory).
# =====================================================================
echo "A6: negative control — the A2 matcher fires on a known-bad fixture"
inc
A6_FIXTURE="$TMPD/a6-bad-dispatch.md"
printf '%s\n' "dispatch inline via \`Agent(subagent_type='tdd-implementer', description='x')\`" > "$A6_FIXTURE"
A6_OUT=$(a2_hits "$A6_FIXTURE")
if [ -n "$A6_OUT" ]; then
  pass_msg "A2 matcher reports a hit on the known-bad dispatch fixture (not vacuous)"
else
  fail_msg "A2 matcher did NOT fire on a known-bad dispatch fixture — the regex is broken and A2 passes vacuously"
fi

# =====================================================================
# A7 — runtime-consumer sweep. A2 is structurally blind to these: the
#      field name is read ~170 lines away from the comparison, so there is
#      no `subagent_type` adjacency to key on.
#      Expected offenders at HEAD (pre-fix): exactly 2 —
#        hooks/enforce-path-c-delegation.py  (collect_authorized_dirs)
#        scripts/review-audits.sh            (PATH C dispatch counter)
# =====================================================================
echo "A7: no runtime consumer exact-matches the BARE literal"
inc
CONSUMER_FILES=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  CONSUMER_FILES+=("$f")
done < <(git ls-files 'scripts/*' 'hooks/*')
if [ "${#CONSUMER_FILES[@]}" -eq 0 ]; then
  fail_msg "A7: git ls-files scripts/ hooks/ produced zero files — the guard would pass vacuously"
else
  A7_OUT=$(a7_hits "${CONSUMER_FILES[@]}")
  if [ -z "$A7_OUT" ]; then
    pass_msg "zero bare-literal equality comparisons across ${#CONSUMER_FILES[@]} scripts/ + hooks/ files"
  else
    fail_msg "runtime consumer(s) still exact-match the BARE literal ($(printf '%s\n' "$A7_OUT" | wc -l | tr -d ' ') hit(s)):"
    printf '%s\n' "$A7_OUT" | cut -c1-140 | sed 's/^/    /'
  fi
fi

# Per-consumer pinned literals — byte-for-byte agreement with the two
# replacement lines, so a reformat that silently changes the fix shape is
# caught rather than tolerated.
A7_HOOK="hooks/enforce-path-c-delegation.py"
echo "A7: runtime consumer #1 — $A7_HOOK"
inc
if grep -qF 'data.get("subagent_type") != "tdd-implementer"' "$A7_HOOK"; then
  fail_msg "A7: $A7_HOOK still carries the bare-equality predicate data.get(\"subagent_type\") != \"tdd-implementer\""
else
  pass_msg "A7: bare-equality hook predicate is gone"
fi
inc
if grep -qF '.rsplit(":", 1)[-1] != "tdd-implementer"' "$A7_HOOK"; then
  pass_msg "A7: hook uses the suffix-match predicate .rsplit(\":\", 1)[-1]"
else
  fail_msg "A7: $A7_HOOK missing the suffix-match predicate '.rsplit(\":\", 1)[-1] != \"tdd-implementer\"'"
fi

A7_AUDIT="scripts/review-audits.sh"
echo "A7: runtime consumer #2 — $A7_AUDIT"
inc
if grep -qF '[ "$st" = "tdd-implementer" ]' "$A7_AUDIT"; then
  fail_msg "A7: $A7_AUDIT still carries the bare-equality PATH C dispatch counter [ \"\$st\" = \"tdd-implementer\" ]"
else
  pass_msg "A7: bare-equality PATH C dispatch counter is gone"
fi
inc
if grep -qF '[ "${st##*:}" = "tdd-implementer" ]' "$A7_AUDIT"; then
  pass_msg "A7: PATH C dispatch counter uses the suffix-match \${st##*:}"
else
  fail_msg "A7: $A7_AUDIT missing the suffix-match counter '[ \"\${st##*:}\" = \"tdd-implementer\" ]'"
fi

# =====================================================================
# A8 — negative control for A7 (mandatory, same rationale as A6).
# =====================================================================
echo "A8: negative control — the A7 matcher fires on a known-bad comparison"
inc
A8_FIXTURE="$TMPD/a8-bad-compare.sh"
printf '%s\n' '[ "$x" = "tdd-implementer" ]' > "$A8_FIXTURE"
A8_OUT=$(a7_hits "$A8_FIXTURE")
if [ -n "$A8_OUT" ]; then
  pass_msg "A7 matcher reports a hit on the known-bad comparison fixture (not vacuous)"
else
  fail_msg "A7 matcher did NOT fire on a known-bad comparison fixture — the regex is broken and A7 passes vacuously"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
