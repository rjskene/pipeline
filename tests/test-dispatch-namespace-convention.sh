#!/bin/bash
set -uo pipefail

# Contract test for issue #1262 sub-defect (a) — the `subagent_type`
# bare-vs-namespaced CONVENTION.
#
# #1238 already flipped every literal in the tree (`tdd-implementer` ->
# `pipeline:tdd-implementer`) and pinned it with tests/test-subagent-type-namespace.sh.
# What #1238 did NOT do, and what #1262(a) actually asks for, is the residue:
#
#   (i)  there is no stated RULE — only per-line notes, so the next `Agent(...)`
#        shape somebody adds to a skill body is a fresh coin-flip; and
#   (ii) the #1238 guard is HARD-CODED to `tdd-implementer` and is structurally
#        blind to any future agent added to `.claude-plugin/plugin.json` `agents[]`.
#
# This guard closes both. N1 pins the convention block. N2/N6 are a compliance
# CLASSIFIER (built-in => bare, plugin-provided => namespaced) over every
# prescribing home. N3 is a DERIVED sweep: the forbidden bare-name set is read
# off the plugin manifest + each agent file's frontmatter `name:`, so adding a
# second agent to `agents[]` automatically extends coverage instead of silently
# escaping it.
#
# N4 and N5 are the MANDATORY negative controls: a guard that greps for "no bad
# string exists" passes vacuously the moment its regex breaks, so each matcher is
# proven to FIRE on a known-bad fixture (mirrors A6/A8 in
# tests/test-subagent-type-namespace.sh).
#
# NOTE on the RED/GREEN ledger: only N1 is red before the fix. N2/N3/N6 are
# FORWARD guards — #1238 already removed everything they would report, so they
# are green by construction and exist to catch the NEXT regression. N4/N5 run
# against synthetic fixtures and never touch the tree. Do not "fix" N2-N6 to
# make them red.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FULLSEND="skills/fullsend/SKILL.md"
MANIFEST=".claude-plugin/plugin.json"

PASS=0; FAIL=0; TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

cd "$ROOT" || { echo "FAIL: cannot cd to repo root $ROOT" >&2; exit 1; }

for f in "$FULLSEND" "$MANIFEST"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f not found under $ROOT" >&2
    exit 1
  fi
done

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Shared matchers.
#
# CAPTURE_RE keys on `subagent_type` adjacency and requires the value to START
# with a letter. That leading `[A-Za-z]` anchor is deliberate: it skips the
# placeholder shapes the skills legitimately use (`subagent_type=...`,
# `subagent_type: "${REVIEWER}"`) instead of reporting them as non-compliant
# values.
# ---------------------------------------------------------------------------
CAPTURE_RE="subagent_type[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z][A-Za-z0-9_:.-]*"
STRIP_RE="s/^subagent_type[[:space:]]*[:=][[:space:]]*['\"]?//"

# extract_subagent_values <file>...  -> one captured value per line
extract_subagent_values() {
  grep -ohE "$CAPTURE_RE" "$@" 2>/dev/null | sed -E "$STRIP_RE" || true
}

# noncompliant_values (stdin: captured values) -> one NON-compliant value per line.
# Compliant iff the value is a harness BUILT-IN (bare, no prefix) or carries a
# `<plugin>:` namespace segment.
noncompliant_values() {
  local v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
      general-purpose|Explore|Plan|claude|statusline-setup|task-runner) continue ;;
      *:*) continue ;;
    esac
    printf '%s\n' "$v"
  done
}

# bare_agent_hits <agent-name> <file>...  -> `file:line:text` per hit of a BARE
# `subagent_type`-adjacent dispatch of that plugin agent.
bare_agent_hits() {
  local agent="$1"; shift
  grep -I -H -nE "subagent_type[[:space:]]*[:=][[:space:]]*['\"]?${agent}" "$@" 2>/dev/null || true
}

echo "Dispatch subagent_type namespacing convention (#1262a)"

# =====================================================================
# N1 — fullsend states the convention ONCE, as a block, instead of
#      per-line notes. The block must name BOTH sides of the axis
#      (built-in => bare, plugin => namespaced) and the DERIVATION
#      sources (plugin manifest + agent frontmatter).
# =====================================================================
echo ""
echo "N1: fullsend carries the subagent_type namespacing convention block"

N1_ANCHOR='**Agent `subagent_type` namespacing convention'

N1_BLOCK="$(awk '
  index($0, "**Agent `subagent_type` namespacing convention") { inblock = 1; print; next }
  inblock && (/^   \*\*/ || /^\*\*/) { inblock = 0 }
  inblock { print }
' "$FULLSEND")"

inc
if [ -z "$N1_BLOCK" ]; then
  fail_msg "N1: fullsend has no $N1_ANCHOR block (absent, or markers moved?)"
else
  pass_msg "N1: fullsend carries the $N1_ANCHOR block"
fi

# Content of the block. Each needle is its own assertion so a partial block is
# reported precisely rather than as one opaque miss. When the block is absent
# these fail too — that is the intended RED signal, not a cascade bug.
for needle in 'general-purpose' '.claude-plugin/plugin.json' 'pipeline:tdd-implementer' 'frontmatter'; do
  inc
  if printf '%s' "$N1_BLOCK" | grep -Fq -- "$needle"; then
    pass_msg "N1: convention block names \"$needle\""
  else
    fail_msg "N1: convention block missing \"$needle\" (block empty => markers moved?)"
  fi
done

# =====================================================================
# N2 — compliance classifier over fullsend itself. EVERY captured
#      `subagent_type` value must be a known harness built-in (bare) or
#      carry a namespace segment. Non-vacuity: at least 5 values.
# =====================================================================
echo ""
echo "N2: every fullsend subagent_type value is built-in-bare or namespaced"

N2_VALUES="$(extract_subagent_values "$FULLSEND")"
N2_COUNT=$(printf '%s\n' "$N2_VALUES" | grep -c . || true)

inc
if [ "${N2_COUNT:-0}" -ge 5 ]; then
  pass_msg "N2: captured $N2_COUNT subagent_type values from $FULLSEND (>= 5, not vacuous)"
else
  fail_msg "N2: captured only ${N2_COUNT:-0} subagent_type values from $FULLSEND — expected >= 5; the classifier would pass vacuously"
fi

N2_BAD="$(printf '%s\n' "$N2_VALUES" | noncompliant_values)"
inc
if [ -z "$N2_BAD" ]; then
  pass_msg "N2: all $N2_COUNT values comply (built-in bare, or namespaced)"
else
  fail_msg "N2: non-compliant subagent_type value(s) in $FULLSEND: $(printf '%s' "$N2_BAD" | tr '\n' ' ')"
fi

# =====================================================================
# N3 — generalized plugin-agent sweep, DERIVED not hard-coded. The
#      forbidden bare-name set comes from `.claude-plugin/plugin.json`
#      `agents[]` -> each agent file's frontmatter `name:`. Adding a
#      second agent to the manifest extends this guard for free.
# =====================================================================
echo ""
echo "N3: no BARE dispatch of any manifest-declared plugin agent (derived set)"

AGENT_NAMES=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  rel="${rel#./}"
  [ -f "$rel" ] || continue
  nm=$(sed -n 's/^name:[[:space:]]*//p' "$rel" | head -n1)
  [ -n "$nm" ] && AGENT_NAMES+=("$nm")
done < <(python3 -c '
import json
m = json.load(open(".claude-plugin/plugin.json"))
for p in m.get("agents", []):
    print(p)
' 2>/dev/null || true)

inc
if [ "${#AGENT_NAMES[@]}" -gt 0 ]; then
  pass_msg "N3: derived ${#AGENT_NAMES[@]} agent name(s) from $MANIFEST agents[]: ${AGENT_NAMES[*]}"
else
  fail_msg "N3: derived ZERO agent names from $MANIFEST agents[] — the sweep would pass vacuously"
fi

N3_FILES=()
while IFS= read -r f; do
  case "$f" in
    tests/*|CHANGELOG.md) continue ;;
  esac
  [ -f "$f" ] || continue
  N3_FILES+=("$f")
done < <(git ls-files)

inc
if [ "${#N3_FILES[@]}" -gt 0 ]; then
  pass_msg "N3: scanning ${#N3_FILES[@]} tracked non-test files"
else
  fail_msg "N3: git ls-files produced zero scannable files — the sweep would pass vacuously"
fi

if [ "${#AGENT_NAMES[@]}" -gt 0 ] && [ "${#N3_FILES[@]}" -gt 0 ]; then
  for agent in "${AGENT_NAMES[@]}"; do
    inc
    N3_OUT="$(bare_agent_hits "$agent" "${N3_FILES[@]}")"
    if [ -z "$N3_OUT" ]; then
      pass_msg "N3: zero BARE subagent_type dispatches of plugin agent '$agent'"
    else
      fail_msg "N3: BARE subagent_type dispatch(es) of plugin agent '$agent' ($(printf '%s\n' "$N3_OUT" | wc -l | tr -d ' ') hit(s)):"
      printf '%s\n' "$N3_OUT" | cut -c1-140 | sed 's/^/    /'
    fi
  done
fi

# =====================================================================
# N4 — negative control for N3 (mandatory). Prove the sweep's matcher
#      FIRES on a known-bad fixture; otherwise a broken regex makes N3
#      pass silently forever.
# =====================================================================
echo ""
echo "N4: negative control — the N3 matcher fires on a known-bad fixture"
inc
N4_FIXTURE="$TMPD/n4-bad-dispatch.md"
printf '%s\n' "dispatch inline via \`Agent(subagent_type='tdd-implementer', description='x')\`" > "$N4_FIXTURE"
N4_AGENT="${AGENT_NAMES[0]:-tdd-implementer}"
N4_OUT="$(bare_agent_hits "$N4_AGENT" "$N4_FIXTURE")"
if [ -n "$N4_OUT" ]; then
  pass_msg "N4: N3 matcher reports a hit for '$N4_AGENT' on the known-bad fixture (not vacuous)"
else
  fail_msg "N4: N3 matcher did NOT fire for '$N4_AGENT' on a known-bad fixture — the regex is broken and N3 passes vacuously"
fi

# =====================================================================
# N5 — negative control for N2 (mandatory). Prove the classifier marks
#      a bare plugin-agent value NON-compliant.
# =====================================================================
echo ""
echo "N5: negative control — the N2 classifier rejects a bare plugin-agent value"
inc
N5_FIXTURE="$TMPD/n5-bad-classify.md"
printf '%s\n' "Agent(subagent_type='tdd-implementer', description='x')" > "$N5_FIXTURE"
N5_BAD="$(extract_subagent_values "$N5_FIXTURE" | noncompliant_values)"
if printf '%s' "$N5_BAD" | grep -Fq 'tdd-implementer'; then
  pass_msg "N5: classifier marks the bare plugin-agent value NON-compliant (not vacuous)"
else
  fail_msg "N5: classifier did NOT flag the bare plugin-agent fixture value — N2 passes vacuously (got '$(printf '%s' "$N5_BAD" | tr '\n' ' ')')"
fi

# =====================================================================
# N6 — the same classifier over the OTHER prescribing homes, as an
#      explicit fixed list. A missing file FAILs so a rename cannot
#      silently shrink coverage.
# =====================================================================
echo ""
echo "N6: the convention holds across every other prescribing home"

N6_SITES=(
  "skills/execute-issue-plan/SKILL.md"
  "skills/plan-issue/SKILL.md"
  "skills/hotfix/SKILL.md"
  "skills/analyze-issues/SKILL.md"
  "docs/architecture.md"
)

for site in "${N6_SITES[@]}"; do
  inc
  if [ ! -f "$site" ]; then
    fail_msg "N6: prescribing site missing from the tree: $site (renamed? coverage silently shrank)"
    continue
  fi
  SITE_BAD="$(extract_subagent_values "$site" | noncompliant_values)"
  if [ -z "$SITE_BAD" ]; then
    pass_msg "N6: $site — all subagent_type values comply"
  else
    fail_msg "N6: $site — non-compliant subagent_type value(s): $(printf '%s' "$SITE_BAD" | tr '\n' ' ')"
  fi
done

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
