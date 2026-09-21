#!/bin/bash
set -uo pipefail

# #1281 — no skills/*/SKILL.md may reference a POSITIONAL-ARGUMENT token from
# inside an executable bash fence. When the harness loads a skill body it
# rewrites `$1`, `$2`, … with the arguments the skill was invoked with, so a
# fence that means "awk field 7" or "the shell's first argument" is delivered to
# Bash with `--cycles` / `2` / … already substituted in. Same mechanical family
# as tests/test-skill-unassigned-vars.sh: a substitution hazard, not prose
# pinning. Nothing here reads SKILL.md PROSE — only code fences.
#
# TOKEN CLASS (deliberate scope, widening it is a decision, not a cleanup):
#   flagged  -> $0, $1..$9, $10.., and the braced ${0}.. forms  (\$\{?[0-9]+\}?)
#   ignored  -> nothing
# #1287 WIDENED the class to include `$0`. #1281 exempted it on the theory that
# `$0` is awk's whole-record variable / bash's script name and therefore "not an
# argv index" — cycle-1 disproved that: the harness rewrites `$0` too, and
# Step 11.2b of evaluate-issue-pr arrived at Bash as
# `awk '{sub(/\r$/,"",1281)}'`. A fence can therefore never carry ANY awk field
# reference, and the `split($0,f," ")` idiom is banned alongside `$1`–`$9`.
# Anything needing `$<n>` belongs in a script file, which the harness never
# rewrites. The `sub(/\}$/,"",tok)` normalisation is unchanged — `${0}` is
# already covered by the braced alternative.
#
# FENCE GRAMMAR: open on /^[[:space:]]*```bash[[:space:]]*$/, close on the next
# /^[[:space:]]*```[[:space:]]*$/. INDENTED fences are included on purpose — a
# column-0-only matcher would exempt the fences nested under numbered list items
# in classify-issue / plan-issue / status, which are exactly where the
# pre-existing hazards live.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_ROOT="$REPO_ROOT/skills"

PASS=0; FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# scan <file> -> one `<line>\t<token>` record per OCCURRENCE, in file order.
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
        if (tok !~ /^\$\{/) sub(/\}$/, "", tok)   # `{print $2}` reports `$2`, not `$2}`
        printf "%d\t%s\n", FNR, tok
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# Non-vacuity self-test, asserted BEFORE the repo sweep.
#
# The fixture lives under `mktemp -d`, NEVER under skills/: a deliberately dirty
# SKILL.md inside the sweep root would be picked up by the repo pass below and
# could never go green. This proves the scanner both FINDS an in-fence token and
# IGNORES prose, so a repo sweep reporting zero hits means "clean", not "broken".
#
# WHY THE PROSE EXEMPTION KEYS ON THE LINE, NOT THE TOKEN (#1287): once `$0` is
# flagged, the token alone no longer carries context — `$0` is simultaneously
# LEGAL in prose and ILLEGAL in a fence, so any regex over the token half of a
# `<line>\t<token>` record necessarily also matches the fixture's own intended
# in-fence `$0` hit (the pre-#1287 `\$(1|3)$` exemption widened to `\$(0|1|3)$`
# is red at RED and can never go green). The assertions below therefore derive
# the prose and fence line sets from the `PROSE-FIXTURE` / `FENCE-FIXTURE`
# sentinels and assert on the reported <line> field. The sentinels are
# load-bearing: they must stay unique and the `zero-token` marker must contain
# no `$`, or the hit count changes.
# ---------------------------------------------------------------------------
SELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SELF_DIR"' EXIT
cat > "$SELF_DIR/SKILL.md" <<'SELFTEST'
# self-test fixture

Prose that names $0, $1 and $3 outside any fence is ignored (PROSE-FIXTURE).

```bash
echo "the awk field is $2"   # FENCE-FIXTURE
awk '{print $0}'             # FENCE-FIXTURE zero-token
```

Trailing prose naming $0 again, still outside a fence (PROSE-FIXTURE).
SELFTEST

SELF_HITS="$(scan "$SELF_DIR/SKILL.md")"
SELF_N="$(printf '%s\n' "$SELF_HITS" | grep -c .)"
PROSE_LNS="$(grep -n 'PROSE-FIXTURE' "$SELF_DIR/SKILL.md" | cut -d: -f1 | paste -sd'|' -)"
FENCE_LNS="$(grep -n 'FENCE-FIXTURE' "$SELF_DIR/SKILL.md" | cut -d: -f1 | paste -sd'|' -)"
FENCE_L2="$(grep -n 'FENCE-FIXTURE zero-token' "$SELF_DIR/SKILL.md" | cut -d: -f1)"
HIT_LNS="$(printf '%s\n' "$SELF_HITS" | cut -f1 | sort -nu | paste -sd'|' -)"

if [ "$SELF_N" = "2" ]; then
  pass_msg "self-test: scanner reports exactly 2 hits on the mktemp fixture (got $SELF_N)"
else
  fail_msg "self-test: scanner reported $SELF_N hits on the mktemp fixture (expected 2)"
fi

if [ "$HIT_LNS" = "$FENCE_LNS" ]; then
  pass_msg "self-test: every reported hit sits on a FENCE-FIXTURE line ($FENCE_LNS)"
else
  fail_msg "self-test: reported hit lines ($HIT_LNS) are not exactly the FENCE-FIXTURE lines ($FENCE_LNS)"
fi

if printf '%s\n' "$SELF_HITS" | grep -qxF "$(printf '%s\t$0' "$FENCE_L2")"; then
  pass_msg "self-test: the in-fence token \$0 is reported at fixture line $FENCE_L2"
else
  fail_msg "self-test: the in-fence token \$0 was NOT reported at fixture line $FENCE_L2 (got: ${SELF_HITS:-<none>})"
fi

if printf '%s\n' "$SELF_HITS" | cut -f1 | grep -qxE "$PROSE_LNS"; then
  fail_msg "self-test: a token on a PROSE-FIXTURE line ($PROSE_LNS) was reported (the scanner is not fence-scoped)"
else
  pass_msg "self-test: tokens on prose lines ($PROSE_LNS) outside every fence are ignored"
fi

# ---------------------------------------------------------------------------
# Repo sweep
# ---------------------------------------------------------------------------
HITS=0
OCC=0
FIRST_HIT=""

while IFS= read -r skill_md; do
  [ -n "$skill_md" ] || continue
  rel="${skill_md#$REPO_ROOT/}"
  hits="$(scan "$skill_md")"
  if [ -z "$hits" ]; then
    pass_msg "$rel: no positional-argument token in any bash fence"
    continue
  fi
  prev=""
  while IFS=$'\t' read -r ln tok; do
    [ -n "$ln" ] || continue
    OCC=$((OCC + 1))
    [ "$ln" = "$prev" ] && continue
    prev="$ln"
    HITS=$((HITS + 1))
    [ -n "$FIRST_HIT" ] || FIRST_HIT="$rel:$ln: $tok"
    fail_msg "$rel:$ln: $tok is a positional-argument token inside a bash fence — the harness rewrites it with the invocation args (#1281)"
  done <<< "$hits"
done <<< "$(find "$SKILL_ROOT" -maxdepth 2 -name SKILL.md | sort)"

# Both units are printed so a future drift is legible: a hit is a <file>:<line>
# pair, an occurrence is a single token (one line can carry several).
echo ""
echo "SWEEP: $HITS <file>:<line> hits covering $OCC positional-argument occurrences"
[ -n "$FIRST_HIT" ] && echo "SWEEP: first hit $FIRST_HIT"

echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
