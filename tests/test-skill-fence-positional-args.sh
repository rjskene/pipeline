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
#   flagged  -> $1..$9, $10.., and the braced ${1}.. forms  (\$\{?[1-9][0-9]*\}?)
#   ignored  -> $0
# `$0` is awk's whole-record variable and bash's script name; neither is an argv
# index, and the harness substitutes indices only. Flagging it would red a large
# single-line awk over `$0` in skills/evaluate-issue-pr/SKILL.md for no hazard
# and would forbid the `split($0,f," ")` idiom that replaces the field refs.
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
      while (match(s, /\$\{?[1-9][0-9]*\}?/)) {
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
# ---------------------------------------------------------------------------
SELF_DIR="$(mktemp -d)"
trap 'rm -rf "$SELF_DIR"' EXIT
cat > "$SELF_DIR/SKILL.md" <<'SELFTEST'
# self-test fixture

Prose that names $1 and $3 outside any fence must be ignored by the scanner.

```bash
echo "the awk field is $2"
```

Trailing prose naming $1 again, still outside a fence.
SELFTEST

SELF_HITS="$(scan "$SELF_DIR/SKILL.md")"
SELF_N="$(printf '%s\n' "$SELF_HITS" | grep -c .)"
if [ "$SELF_N" = "1" ]; then
  pass_msg "self-test: scanner reports exactly 1 hit on the mktemp fixture (got $SELF_N)"
else
  fail_msg "self-test: scanner reported $SELF_N hits on the mktemp fixture (expected 1)"
fi
if printf '%s\n' "$SELF_HITS" | grep -qF '$2'; then
  pass_msg "self-test: the in-fence token \$2 is reported"
else
  fail_msg "self-test: the in-fence token \$2 was NOT reported (got: ${SELF_HITS:-<none>})"
fi
if printf '%s\n' "$SELF_HITS" | grep -qE '\$(1|3)$'; then
  fail_msg "self-test: a PROSE token (\$1/\$3) was reported (the scanner is not fence-scoped)"
else
  pass_msg "self-test: prose tokens outside every fence are ignored"
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
