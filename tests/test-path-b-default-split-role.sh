#!/bin/bash
set -uo pipefail

# Regression guard for #1057: split-role TDD lane is the shipped DEFAULT (opt-OUT),
# not opt-in. The structurally identical flip to #1042 (Sonnet-on-execute default),
# applied to the split-role axis (PIPELINE_PATH_B_SPLIT_ROLE). After the flip:
#   - pipeline.config.example documents the default as "true" (opt-OUT via =false)
#     and ships the read-site line ACTIVE at `PIPELINE_PATH_B_SPLIT_ROLE=true`
#     (was: commented `#PIPELINE_PATH_B_SPLIT_ROLE=false`).
#   - The two semantic "unset => off" prose read sites flip their polarity so an
#     UNSET/empty var RUNS the split-role lane (operator opts OUT with `=false`):
#       * skills/fullsend/SKILL.md (was: `PIPELINE_PATH_B_SPLIT_ROLE` (default `false`))
#       * skills/evaluate-issue-pr/SKILL.md 11.2b (was: when unset/`false`, skip)
#   - docs/split-role-tdd.md documents the default as `true` (was `false`).
#
# Static-grep/awk over the named source files only (no live dispatch) — mirrors the
# shape of tests/test-path-b-default-sonnet-routing.sh (the #1042 precedent). Per
# CLAUDE.md release-hygiene the named-file scans never compare version literals; this
# guard greps only the enumerated source files (no whole-repo grep), so no
# CHANGELOG/.git/.claude/logs exclusion is needed.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
FULLSEND="$ROOT/skills/fullsend/SKILL.md"
PREVAL="$ROOT/skills/evaluate-issue-pr/SKILL.md"
DOC="$ROOT/docs/split-role-tdd.md"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

for f in "$EXAMPLE" "$FULLSEND" "$PREVAL" "$DOC"; do
  if [ ! -f "$f" ]; then echo "ERROR: $f not found" >&2; exit 1; fi
done

echo "== test-path-b-default-split-role (issue #1057) =="

# awk helper: extract the "#881 Phase 2: split-role TDD lane" comment block of the
# config example (start at the header, stop at the PIPELINE_PATH_B_SPLIT_ROLE= line).
split_role_block() {
  awk '
    /#881 Phase 2: split-role TDD lane/ { inblock = 1 }
    inblock { print }
    inblock && /^[[:space:]]*#?[[:space:]]*PIPELINE_PATH_B_SPLIT_ROLE=/ { inblock = 0 }
  ' "$EXAMPLE"
}

# 1. pipeline.config.example: the read-site line is ACTIVE at the true default
#    (uncommented `PIPELINE_PATH_B_SPLIT_ROLE=true`, NOT commented, NOT =false).
inc
if grep -Eq '^[[:space:]]*PIPELINE_PATH_B_SPLIT_ROLE=true' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_PATH_B_SPLIT_ROLE=true active"
else
  fail_msg "example: PIPELINE_PATH_B_SPLIT_ROLE=true NOT active (still commented / =false?)"
fi

# 2. pipeline.config.example: NO commented `#PIPELINE_PATH_B_SPLIT_ROLE=false` residue.
inc
if ! grep -Eq '^[[:space:]]*#[[:space:]]*PIPELINE_PATH_B_SPLIT_ROLE=false' "$EXAMPLE"; then
  pass_msg "example: no commented #PIPELINE_PATH_B_SPLIT_ROLE=false residue"
else
  fail_msg "example: stale commented #PIPELINE_PATH_B_SPLIT_ROLE=false residue remains"
fi

# 3. pipeline.config.example: the split-role comment block documents default `true`
#    with opt-OUT framing, and the OLD `Default "false"` wording is GONE. The block
#    prose wraps across lines, so flatten the block to a single logical line (newlines
#    -> spaces, strip leading `# `) before the co-occurrence grep — the un-flipped
#    `Default\n"false".` spans two physical lines and a same-line grep would miss it.
split_role_block_flat() { split_role_block | tr '\n' ' '; }
inc
if split_role_block_flat | grep -Eiq 'default[^.]*\<true\>' \
   && split_role_block_flat | grep -Eiq 'opt[ -]?out|=false'; then
  pass_msg "example: split-role block documents default true with opt-OUT framing"
else
  fail_msg "example: split-role block does NOT document default true / opt-OUT"
fi
inc
# Tolerate the comment-prefix `# ` and quote noise the line-wrap injects between the
# `Default` token and `false` (flattened: `Default # "false".`) — match any run of
# non-alphanumeric chars (NO intervening period, so it can't bridge into the next
# sentence) so the un-flipped wording is genuinely caught.
if ! split_role_block_flat | grep -Eiq 'default[^.a-z0-9]+false'; then
  pass_msg "example: split-role block no longer documents Default \"false\""
else
  fail_msg "example: split-role block still documents Default \"false\""
fi

# awk helper: extract the resolver-defaults paragraph of the fullsend SKILL that
# names PIPELINE_PATH_B_SPLIT_ROLE's default (the "SINGLE-SOURCE resolver" routing
# block, where the split-role default polarity is documented). Scope from the
# "Per-path execute MODEL routing" header to the next top-level routing heading.
fullsend_routing_block() {
  awk '
    /Per-path execute MODEL routing/ { inblock = 1 }
    inblock && /^   - \*\*/ && !/Per-path execute MODEL routing/ { inblock = 0 }
    inblock { print }
  ' "$FULLSEND"
}

# 4. skills/fullsend/SKILL.md: the split-role default is documented as `true` (require
#    PIPELINE_PATH_B_SPLIT_ROLE + default + true to co-occur on the SAME line so the
#    OLD `(default `false`)` wording does not spuriously pass), and the OLD literal
#    `PIPELINE_PATH_B_SPLIT_ROLE` (default `false`) wording is ABSENT.
inc
if fullsend_routing_block | grep -Eiq 'PIPELINE_PATH_B_SPLIT_ROLE[^.]*default[^.]*\<true\>|default[^.]*\<true\>[^.]*PIPELINE_PATH_B_SPLIT_ROLE'; then
  pass_msg "fullsend: split-role default documented as true (same-line)"
else
  fail_msg "fullsend: split-role default NOT documented as true"
fi
inc
if ! grep -Fq 'PIPELINE_PATH_B_SPLIT_ROLE` (default `false`)' "$FULLSEND"; then
  pass_msg "fullsend: stale '(default \`false\`)' split-role literal is gone"
else
  fail_msg "fullsend: stale 'PIPELINE_PATH_B_SPLIT_ROLE\` (default \`false\`)' literal remains"
fi

# 5. skills/evaluate-issue-pr/SKILL.md 11.2b: the skip clause is opt-OUT — the OLD
#    `unset/`false`, skip` phrasing is GONE and an explicit-only skip clause is present
#    (skip ONLY when explicitly =false; unset/empty RUNS the gate).
inc
if ! grep -Fq 'unset/`false`, skip' "$PREVAL"; then
  pass_msg "evaluate-issue-pr: stale 'unset/\`false\`, skip' phrasing is gone"
else
  fail_msg "evaluate-issue-pr: stale 'unset/\`false\`, skip' phrasing remains"
fi
inc
if grep -Eiq 'skip[^.]*(only|explicit)[^.]*=false|=false[^.]*skip[^.]*(only|explicit)' "$PREVAL"; then
  pass_msg "evaluate-issue-pr: explicit-only skip clause (=false) present"
else
  fail_msg "evaluate-issue-pr: explicit-only skip-when-=false clause missing"
fi

# 6. docs/split-role-tdd.md: documents the default as `true` and NOT `false`.
inc
if grep -Eiq 'default[^.]*\<true\>' "$DOC"; then
  pass_msg "doc: split-role-tdd documents default true"
else
  fail_msg "doc: split-role-tdd does NOT document default true"
fi
inc
if ! grep -Fq '(default `false`)' "$DOC"; then
  pass_msg "doc: stale '(default \`false\`)' literal is gone"
else
  fail_msg "doc: stale '(default \`false\`)' literal remains"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
