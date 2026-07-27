#!/bin/bash
set -uo pipefail

# Regression guard for #1042: Sonnet-on-execute is the shipped DEFAULT (opt-OUT),
# not opt-in. Two layers, both required:
#   1. Read-site default flip in skills/fullsend/SKILL.md "Per-path execute MODEL
#      routing": unset PIPELINE_PATH_B_MODEL_EXECUTE / PIPELINE_PATH_D_MODEL_EXECUTE
#      => default `sonnet` (was: unset => Opus); unset PIPELINE_PATH_B_ELIGIBLE_SCOPE
#      => default `all` (was: low-blast). The W2 high-uncertainty carve-out and the
#      PATH D needs-browser carve-out (#960) STILL force Opus. pr-eval is NEVER
#      defaulted to Sonnet (W3).
#   2. The three knobs ship ACTIVE (=sonnet, scope=all) in pipeline.config.example
#      and scripts/init.sh's generated config, with opt-OUT framing.
#
# Static-grep/awk over the named source files only (no live dispatch) — mirrors the
# shape of tests/test-path-model-execute-routing.sh. Per CLAUDE.md release-hygiene
# the named-file scans never compare version literals; this guard greps only the
# enumerated source files (no whole-repo grep), so no CHANGELOG/.git/.claude/logs
# exclusion is needed.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
SKILL="$ROOT/skills/fullsend/SKILL.md"
INIT="$ROOT/scripts/init.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXAMPLE" "$SKILL" "$INIT"; do
  if [ ! -f "$f" ]; then echo "ERROR: $f not found" >&2; exit 1; fi
done

echo "== test-path-b-default-sonnet-routing (issue #1042) =="

# awk helper: extract the "Per-path execute MODEL routing" block of the SKILL
# (start at the heading, stop at the next top-level "## " heading).
routing_block() {
  awk '
    /Per-path execute MODEL routing/ { inblock = 1 }
    inblock && /^## / { inblock = 0 }
    inblock { print }
  ' "$SKILL"
}

# 1. SKILL routing block: B/D execute model DEFAULTS to sonnet when unset.
#    Require unset/empty + default(s) + sonnet to co-occur on the SAME line, so the
#    OLD un-flipped wording ("when unset/empty ... inherits Opus") does NOT spuriously
#    pass on the strewn-across-the-block presence of those words.
inc
if routing_block | grep -Ei "(unset|empty)[^.]*(default[s]?)[^.]*sonnet|(default[s]?)[^.]*(unset|empty)[^.]*sonnet|sonnet[^.]*(default[s]?)[^.]*(unset|empty)" >/dev/null; then
  pass_msg "skill: routing block documents unset B/D model => default sonnet"
else
  fail_msg "skill: routing block does NOT document unset => default sonnet"
fi

# 2. SKILL routing block: PIPELINE_PATH_B_ELIGIBLE_SCOPE defaults to `all` when unset.
#    Require the scope var, "default", and "all" to co-occur on the SAME line, so the
#    OLD "(default low-blast)" wording fails for the right reason.
inc
if routing_block | grep -Ei "PIPELINE_PATH_B_ELIGIBLE_SCOPE[^.]*default[^.]*\<all\>|default[^.]*\<all\>[^.]*PIPELINE_PATH_B_ELIGIBLE_SCOPE" >/dev/null; then
  pass_msg "skill: routing block documents PIPELINE_PATH_B_ELIGIBLE_SCOPE default => all"
else
  fail_msg "skill: routing block does NOT document scope default => all"
fi

# 3. SKILL routing block: W2 high-uncertainty carve-out STILL forces Opus.
#    The high-uncertainty vocabulary co-occurs with an inherit/Opus clause. Source
#    the SINGLE-SOURCE-OF-TRUTH helper (scripts/_high-uncertainty-match.sh, #1039)
#    for the regex rather than inlining a substring copy — the drift guard in
#    tests/test-high-uncertainty-match.sh forbids any stray inline copy of the vocab.
inc
# shellcheck source=/dev/null
. "$ROOT/scripts/_high-uncertainty-match.sh"
if [ -z "${HIGH_UNCERTAINTY_RE:-}" ]; then
  fail_msg "skill: could not source HIGH_UNCERTAINTY_RE from the shared helper"
elif routing_block | grep -Ei "$HIGH_UNCERTAINTY_RE" >/dev/null \
   && routing_block | grep -Ei "inherit|opus" >/dev/null; then
  pass_msg "skill: W2 carve-out still forces Opus (shared high-uncertainty regex + inherit/Opus)"
else
  fail_msg "skill: W2 carve-out -> Opus clause missing from the routing block"
fi

# 4. SKILL routing block: PATH D needs-browser carve-out (#960) STILL forces Opus.
#    #1186 changes the MECHANISM, not the carve-out: the branch now PINS the named
#    `model=opus` instead of suppressing model= and inheriting the session model
#    (which, under a Fable-ceiling session, would have upshifted browser/UI execute
#    to Fable — the opposite of the #960 intent). The old NO-model=/suppress/inherit
#    phrasings are no longer accepted.
inc
if routing_block | awk '
  /PATH D/ && /needs-browser/ {
    l = tolower($0)
    if (l ~ /model=opus/ || l ~ /pins opus/ || l ~ /pinned opus/ || l ~ /pin opus/) f = 1
  }
  END { exit (f ? 0 : 1) }
'; then
  pass_msg "skill: PATH D needs-browser carve-out pins opus (#960 preserved, #1186 named)"
else
  fail_msg "skill: PATH D needs-browser -> pinned-opus carve-out missing from the block (#1186)"
fi

# 5. SKILL routing block: pr-eval is NEVER gated / stays Opus (W3 backstop).
#    Re-use the test-path-model-execute-routing.sh test-6 regex.
inc
if grep -iEq "pr-eval dispatch is (not|never) gated|pr-eval .* not gated|pr-eval stays on .*opus" "$SKILL"; then
  pass_msg "skill: pr-eval dispatch NEVER gated / stays Opus (W3)"
else
  fail_msg "skill: missing the 'pr-eval not gated' W3 invariant"
fi

# 6. pipeline.config.example: #1052 (defaults-in-code) — the three knobs are now
#    COMMENTED at their documented defaults (the Sonnet/all default is single-sourced
#    at the scripts/resolve-execute-dispatch.sh read site, so --fix config must NOT seed
#    them). Assert each is documented as a commented knob (NOT a live line). The Sonnet
#    default itself is asserted at the SKILL/resolver read site by the checks above.
inc
if grep -Eq '^[[:space:]]*#[[:space:]]*PIPELINE_PATH_B_MODEL_EXECUTE=sonnet' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_PATH_B_MODEL_EXECUTE=sonnet documented (commented) per #1052"
else
  fail_msg "example: PIPELINE_PATH_B_MODEL_EXECUTE=sonnet not documented as commented (#1052)"
fi
inc
if grep -Eq '^[[:space:]]*#[[:space:]]*PIPELINE_PATH_D_MODEL_EXECUTE=sonnet' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_PATH_D_MODEL_EXECUTE=sonnet documented (commented) per #1052"
else
  fail_msg "example: PIPELINE_PATH_D_MODEL_EXECUTE=sonnet not documented as commented (#1052)"
fi
inc
if grep -Eq '^[[:space:]]*#[[:space:]]*PIPELINE_PATH_B_ELIGIBLE_SCOPE="?all"?' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_PATH_B_ELIGIBLE_SCOPE=all documented (commented) per #1052"
else
  fail_msg "example: PIPELINE_PATH_B_ELIGIBLE_SCOPE=all not documented as commented (#1052)"
fi

# 7. pipeline.config.example: the model-routing knob comment block reads as opt-OUT,
#    naming both opt-out values (=opus and low-blast). Scope to the routing knob block
#    (from its "per-path execute MODEL routing" header down to the SCOPE knob line) so
#    unrelated "opt out" comments elsewhere in the example do NOT spuriously pass.
routing_knob_block() {
  awk '
    /per-path execute MODEL routing/ { inblock = 1 }
    inblock { print }
    inblock && /^[[:space:]]*#?[[:space:]]*PIPELINE_PATH_B_ELIGIBLE_SCOPE=/ { inblock = 0 }
  ' "$EXAMPLE"
}
inc
if routing_knob_block | grep -Ei "opt[ -]out" >/dev/null; then
  pass_msg "example: routing knob comments reframed as opt-OUT"
else
  fail_msg "example: routing knob comments do NOT use opt-out framing"
fi
inc
if routing_knob_block | grep -Ei "opus" >/dev/null && routing_knob_block | grep -E "low-blast" >/dev/null; then
  pass_msg "example: both opt-out values named (opus and low-blast) in the routing knob block"
else
  fail_msg "example: opt-out values (opus / low-blast) not both named in the routing knob block"
fi

# 8. scripts/init.sh: the generated-config heredoc emits the three knobs ACTIVE at
#    the Sonnet defaults inside the `cat > pipeline.config` body.
heredoc_body() {
  awk '
    /cat > pipeline.config <<EOF/ { inheredoc = 1; next }
    inheredoc && /^EOF$/ { inheredoc = 0 }
    inheredoc { print }
  ' "$INIT"
}
inc
if heredoc_body | grep -E '^[[:space:]]*PIPELINE_PATH_B_MODEL_EXECUTE=sonnet' >/dev/null; then
  pass_msg "init.sh: heredoc emits PIPELINE_PATH_B_MODEL_EXECUTE=sonnet"
else
  fail_msg "init.sh: heredoc does NOT emit PIPELINE_PATH_B_MODEL_EXECUTE=sonnet"
fi
inc
if heredoc_body | grep -E '^[[:space:]]*PIPELINE_PATH_D_MODEL_EXECUTE=sonnet' >/dev/null; then
  pass_msg "init.sh: heredoc emits PIPELINE_PATH_D_MODEL_EXECUTE=sonnet"
else
  fail_msg "init.sh: heredoc does NOT emit PIPELINE_PATH_D_MODEL_EXECUTE=sonnet"
fi
inc
if heredoc_body | grep -E '^[[:space:]]*PIPELINE_PATH_B_ELIGIBLE_SCOPE="?all"?' >/dev/null; then
  pass_msg "init.sh: heredoc emits PIPELINE_PATH_B_ELIGIBLE_SCOPE=all"
else
  fail_msg "init.sh: heredoc does NOT emit PIPELINE_PATH_B_ELIGIBLE_SCOPE=all"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
