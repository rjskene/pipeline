#!/bin/bash
set -uo pipefail
#
# #1444 — HOT-PATH SKILL MASS CEILINGS.
#
# `fullsend`, `evaluate-issue-pr` and `execute-issue-plan` are the three skills
# the pipeline loads on EVERY wave: fullsend into the orchestrator session, the
# other two into every dispatched Agent. Every word of their BODY is paid once
# per dispatch and competes with the dispatched agent's own working context, so
# each carries a hard mass ceiling. Conditional detail belongs in
# `skills/<name>/references/*.md`, read only when its trigger fires.
#
# TWO UNITS, both ceilinged, because they fail differently:
#   words   -> context cost. Measured against the BODY (frontmatter stripped)
#              via tests/_lib/skill-body.sh — a whole-file count is inflated by
#              the YAML `description:` line, and a whole-file GREP is
#              satisfiable by it alone (#1218). Body basis is the tighter test.
#   fences  -> `bash` fence count. A fence is a tool call the agent must make;
#              redundant fences are latency and failure surface, not prose.
#              Grammar is the #1281 one: /^[[:space:]]*```bash/ — INDENTED
#              fences count, because the fences nested under numbered list
#              items are exactly the ones that proliferate.
#
# Each row also carries a NON-VACUITY FLOOR so gutting a skill to a stub cannot
# pass the ceiling trivially. TRIM PROSE OR RELOCATE IT TO `references/` — never
# raise a ceiling to go green, and never re-inline a relocated section to keep
# some other test green (move that test's extractor to the new file instead).
#
# The `references/` files this refactor creates inherit the #1281 hazard: a
# relocated `bash` fence is still delivered to Bash with `$1`.. rewritten by the
# harness. The final scenario sweeps them for that token class. It is the same
# contract tests/test-skill-fence-positional-args.sh enforces over SKILL.md
# (widened by #1444 to cover `references/` too); this row is the hot-path
# tripwire, that test is the repo-wide one.
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=tests/_lib/skill-body.sh
source "$SCRIPT_DIR/_lib/skill-body.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc_scenario() { echo ""; echo "-- $1 --"; }

# body_words <file> -> BODY word count (frontmatter stripped).
body_words() { skill_body "$1" | wc -w; }

# bash_fences <file> -> count of OPEN bash fences under the #1281 grammar.
bash_fences() { grep -cE '^[[:space:]]*```bash' "$1"; }

# ---------------------------------------------------------------------------
# Ceilings. One row per hot-path skill:
#   <repo-relative path>|<max body words>|<min body words>|<max bash fences>
# ---------------------------------------------------------------------------
ROWS=(
  "skills/fullsend/SKILL.md|8000|4000|20"
  "skills/evaluate-issue-pr/SKILL.md|3000|1200|9"
  "skills/execute-issue-plan/SKILL.md|4000|1500|9"
)

for row in "${ROWS[@]}"; do
  IFS='|' read -r rel max_words min_words max_fences <<<"$row"
  inc_scenario "Scenario: $rel mass"

  file="$REPO_ROOT/$rel"
  if [ ! -f "$file" ]; then
    fail_msg "$rel does not exist"
    continue
  fi

  words="$(body_words "$file")"
  fences="$(bash_fences "$file")"
  echo "  $rel: body words=$words (ceiling $max_words, floor $min_words)  bash fences=$fences (ceiling $max_fences)"

  if [ "$words" -le "$max_words" ]; then
    pass_msg "$rel body is within the word ceiling ($words <= $max_words)"
  else
    fail_msg "$rel body EXCEEDS the word ceiling ($words > $max_words) — relocate conditional detail to references/, never raise the ceiling"
  fi

  if [ "$words" -ge "$min_words" ]; then
    pass_msg "$rel body is non-vacuous ($words >= $min_words)"
  else
    fail_msg "$rel body is vacuous ($words < $min_words) — a stub must not pass the ceiling"
  fi

  if [ "$fences" -le "$max_fences" ]; then
    pass_msg "$rel is within the bash-fence ceiling ($fences <= $max_fences)"
  else
    fail_msg "$rel EXCEEDS the bash-fence ceiling ($fences > $max_fences) — merge redundant fences or relocate them, never raise the ceiling"
  fi
done

# ---------------------------------------------------------------------------
# Positional-argument token sweep over skills/*/references/*.md.
#
# scan <file> -> one `<line>\t<token>` record per OCCURRENCE inside a bash
# fence. Token class and fence grammar are lifted verbatim from
# tests/test-skill-fence-positional-args.sh (#1281/#1287): `$0`, `$1`..`$9`,
# `$10`.. and the braced `${0}`.. forms, flagged only INSIDE a fence.
# ---------------------------------------------------------------------------
scan() {
  awk '
    function is_open(l)  { return l ~ /^[[:space:]]*```bash[[:space:]]*$/ }
    function is_close(l) { return l ~ /^[[:space:]]*```[[:space:]]*$/ }
    {
      if (!inb) { if (is_open($0)) inb = 1; next }
      if (is_close($0)) { inb = 0; next }
      s = $0
      while (match(s, /\$\{?[0-9]+\}?/)) {
        tok = substr(s, RSTART, RLENGTH)
        if (tok !~ /^\$\{/) sub(/\}$/, "", tok)
        printf "%d\t%s\n", FNR, tok
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

inc_scenario "Scenario: scanner self-test (non-vacuity)"

# The fixture lives under mktemp, NEVER under skills/ — a deliberately dirty
# reference file inside the sweep root below could never go green.
SELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SELF_DIR"' EXIT
cat > "$SELF_DIR/fixture.md" <<'SELFTEST'
# self-test fixture

Prose naming $1 outside any fence is ignored (PROSE-FIXTURE).

```bash
echo "the awk field is $2"   # FENCE-FIXTURE
```

Trailing prose naming $0 again, still outside a fence (PROSE-FIXTURE).
SELFTEST

SELF_HITS="$(scan "$SELF_DIR/fixture.md")"
SELF_N="$(printf '%s\n' "$SELF_HITS" | grep -c .)"
FENCE_LN="$(grep -n 'FENCE-FIXTURE' "$SELF_DIR/fixture.md" | cut -d: -f1)"

if [ "$SELF_N" = "1" ]; then
  pass_msg "scanner reports exactly 1 in-fence hit on the mktemp fixture"
else
  fail_msg "scanner reported $SELF_N hits on the mktemp fixture (expected 1) — the sweep below is not trustworthy"
fi

if printf '%s\n' "$SELF_HITS" | grep -qxF "$(printf '%s\t$2' "$FENCE_LN")"; then
  pass_msg "scanner reports the in-fence token \$2 at fixture line $FENCE_LN"
else
  fail_msg "scanner did NOT report \$2 at fixture line $FENCE_LN (got: ${SELF_HITS:-<none>})"
fi

inc_scenario "Scenario: skills/*/references/*.md carry no positional-argument token in a bash fence"

REF_FILES="$(find "$REPO_ROOT/skills" -mindepth 3 -maxdepth 3 -path '*/references/*.md' | sort)"
REF_N="$(printf '%s\n' "$REF_FILES" | grep -c .)"
echo "  swept $REF_N file(s) under skills/*/references/"

if [ "$REF_N" -ge 1 ]; then
  pass_msg "the sweep root is non-empty ($REF_N reference file(s))"
else
  fail_msg "no skills/*/references/*.md found — the sweep is vacuous"
fi

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  rel="${ref#"$REPO_ROOT"/}"
  hits="$(scan "$ref")"
  if [ -z "$hits" ]; then
    pass_msg "$rel: no positional-argument token in any bash fence"
    continue
  fi
  while IFS=$'\t' read -r ln tok; do
    [ -n "$ln" ] || continue
    fail_msg "$rel:$ln: $tok is a positional-argument token inside a bash fence — the harness rewrites it with the invocation args (#1281)"
  done <<< "$hits"
done <<< "$REF_FILES"

# --- Summary ---
echo ""
echo "=============================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=============================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
