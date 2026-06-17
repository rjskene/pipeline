#!/bin/bash
set -uo pipefail

# Behavioral test for scripts/resolve-execute-dispatch.sh (issue #1056).
#
# The resolver is the SINGLE SOURCE OF TRUTH for the inline execute dispatch
# spec: given an issue number and a path letter (B|D), it resolves the full
# dispatch spec the orchestrator must apply — the execute `model=`, the #881
# split-role shape, and an advisory eligibility/scope/reason audit — folding
# the #1042 model knob, the W2 high-uncertainty always-Opus carve-out, the
# needs-browser PATH-D always-Opus carve-out (#960), and the #881 split-role
# flag into ONE place so config + SKILL prose can no longer drift (the #1056
# root cause). It REUSES scripts/_high-uncertainty-match.sh and
# scripts/path-b-execute-eligible.sh — it never redefines the carve-out regex
# (that was bug #1039).
#
# The resolver emits one token per line on stdout and ALWAYS exits 0 (the
# verdict rides the tokens, mirroring scripts/path-b-execute-eligible.sh):
#
#   ISSUE=<N>
#   PATH=<B|D>
#   MODEL=<sonnet|opus|haiku|inherit>   # `inherit` => pass NO model= (Opus)
#   SPLIT_ROLE=<true|false>             # PATH B only; false for D
#   ROLES=<single | red:opus,green:<model>>
#   SCOPE=<all|low-blast>               # resolved PIPELINE_PATH_B_ELIGIBLE_SCOPE (B)
#   ELIGIBLE=<low-blast|high-blast>     # advisory passthrough (B only)
#   REASON=<token>                      # why MODEL resolved as it did (audit)
#
# Usage guard: reject any path letter but B/D with exit 2 + usage on stderr.
#
# This test stubs `gh` on PATH (same pattern as
# tests/test-path-b-execute-eligible.sh) so `gh issue view <N> --json
# title,body,labels` returns canned fixtures, and sources config from a temp
# pipeline.config via PIPELINE_PROJECT_ROOT so the per-path model/scope/split
# knobs are exercised without touching the host config.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/resolve-execute-dispatch.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: helper not found at $HELPER (resolve-execute-dispatch.sh: No such file)" >&2
  echo ""
  echo "== summary: 0 passed, 1 failed (of 1) =="
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"

# `gh` stub: emits a canned JSON document read from $GH_FIXTURE for the
# `gh issue view ... --json title,body,labels` call. Mirrors
# tests/test-path-b-execute-eligible.sh: shells out to the real `jq` against the
# fixture when a --jq expression is present, else cats the fixture verbatim.
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
JQ_EXPR=""
prev=""
for a in "$@"; do
  if [ "$prev" = "--jq" ]; then JQ_EXPR="$a"; fi
  prev="$a"
done
if [ -n "$JQ_EXPR" ]; then
  jq -r "$JQ_EXPR" < "$GH_FIXTURE"
else
  cat "$GH_FIXTURE"
fi
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Build a {title,body,labels} JSON fixture file and return its path.
make_fixture() {
  local title="$1" body="$2" labels_json="$3"
  local f="$WORKDIR/fixture-$RANDOM$RANDOM.json"
  jq -n --arg t "$title" --arg b "$body" --argjson l "$labels_json" \
    '{title:$t, body:$b, labels:$l}' > "$f"
  echo "$f"
}

# Build a temp pipeline.config + .git marker dir carrying the requested knobs,
# return its path (consumed via PIPELINE_PROJECT_ROOT by _resolve-config.sh).
# Args: each "VAR=value" assignment to write into the config.
make_config_root() {
  local root="$WORKDIR/cfgroot-$RANDOM$RANDOM"
  mkdir -p "$root"
  echo "gitdir: /tmp/fake" > "$root/.git"
  {
    echo "set -a"
    echo 'PIPELINE_REPO="owner/repo"'
    echo 'PIPELINE_BASE_BRANCH="staging"'
    local kv
    for kv in "$@"; do echo "$kv"; done
    echo "set +a"
  } > "$root/pipeline.config"
  echo "$root"
}

# Run the resolver against a fixture + config root + path letter; echo full
# stdout (multi-line token block).
run_resolver() {
  local fixture="$1" cfgroot="$2" pathletter="$3"
  PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fixture" \
    PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$cfgroot" \
    bash "$HELPER" 999 "$pathletter" 2>/dev/null
}

# Assert a token (literal "KEY=VALUE") is present on its own line in $out.
assert_tok() {
  local desc="$1" tok="$2" out="$3"
  inc
  if printf '%s\n' "$out" | grep -qxF "$tok"; then
    pass_msg "$desc -> has '$tok'"
  else
    fail_msg "$desc: expected line '$tok', got:
$out"
  fi
}

echo "== test-resolve-execute-dispatch (issue #1056) =="

# Low-blast single-source body (single module, no W2 signal): used wherever a
# clean PATH B issue is needed.
BODY_LOW=$'## Summary\nadjust a helper\n\n## Affected areas\n- `scripts/foo.sh`\n'
# Multi-module body => high-blast eligibility.
BODY_HIGH=$'## Affected areas\n- `scripts/a.sh`\n- `skills/x/SKILL.md`\n'
# W2 high-uncertainty body (security/auth vocab).
BODY_W2=$'## Summary\nHarden the authentication and security path.\n\n## Affected areas\n- `scripts/foo.sh`\n'
# W2 high-uncertainty for PATH D (concurrency/deadlock vocab).
BODY_W2D=$'## Summary\nFix a deadlock in the concurrency path.\n'

# ---- Task 1: model resolution + carve-outs ----------------------------------

# (1) PATH B, knobs unset -> sonnet default, single shape, scope all.
CFG1=$(make_config_root)
FIX1=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT1=$(run_resolver "$FIX1" "$CFG1" B)
assert_tok "(1) B knobs unset" "MODEL=sonnet" "$OUT1"
assert_tok "(1) B knobs unset" "SPLIT_ROLE=false" "$OUT1"
assert_tok "(1) B knobs unset" "ROLES=single" "$OUT1"
assert_tok "(1) B knobs unset" "SCOPE=all" "$OUT1"
assert_tok "(1) B knobs unset" "PATH=B" "$OUT1"
assert_tok "(1) B knobs unset" "ISSUE=999" "$OUT1"

# (2) PATH B, explicit opus -> honored verbatim.
CFG2=$(make_config_root 'PIPELINE_PATH_B_MODEL_EXECUTE=opus')
FIX2=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT2=$(run_resolver "$FIX2" "$CFG2" B)
assert_tok "(2) B explicit opus" "MODEL=opus" "$OUT2"

# (3) PATH B, W2 vocab in body, knobs default -> opus, reason high-uncertainty.
CFG3=$(make_config_root)
FIX3=$(make_fixture "fix(auth): harden" "$BODY_W2" '[]')
OUT3=$(run_resolver "$FIX3" "$CFG3" B)
assert_tok "(3) B W2 vocab" "MODEL=opus" "$OUT3"
assert_tok "(3) B W2 vocab" "REASON=high-uncertainty" "$OUT3"

# (4) PATH B, needs-browser label -> opus, reason needs-browser.
CFG4=$(make_config_root)
FIX4=$(make_fixture "fix(ui): table tweak" "$BODY_LOW" '[{"name":"needs-browser"}]')
OUT4=$(run_resolver "$FIX4" "$CFG4" B)
assert_tok "(4) B needs-browser" "MODEL=opus" "$OUT4"
assert_tok "(4) B needs-browser" "REASON=needs-browser" "$OUT4"

# (5) PATH B, scope=low-blast, high-blast (multi-module) issue -> inherit, ELIGIBLE=high-blast.
CFG5=$(make_config_root 'PIPELINE_PATH_B_ELIGIBLE_SCOPE=low-blast')
FIX5=$(make_fixture "feat(x): big" "$BODY_HIGH" '[]')
OUT5=$(run_resolver "$FIX5" "$CFG5" B)
assert_tok "(5) B scope=low-blast high-blast" "MODEL=inherit" "$OUT5"
assert_tok "(5) B scope=low-blast high-blast" "ELIGIBLE=high-blast" "$OUT5"
assert_tok "(5) B scope=low-blast high-blast" "SCOPE=low-blast" "$OUT5"

# (6) PATH B, scope=low-blast, low-blast (single module) issue -> sonnet, ELIGIBLE=low-blast.
CFG6=$(make_config_root 'PIPELINE_PATH_B_ELIGIBLE_SCOPE=low-blast')
FIX6=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT6=$(run_resolver "$FIX6" "$CFG6" B)
assert_tok "(6) B scope=low-blast low-blast" "MODEL=sonnet" "$OUT6"
assert_tok "(6) B scope=low-blast low-blast" "ELIGIBLE=low-blast" "$OUT6"

# (7) PATH D, knobs unset -> sonnet default, single shape (no eligibility predicate).
CFG7=$(make_config_root)
FIX7=$(make_fixture "fix(foo): quick" "$BODY_LOW" '[]')
OUT7=$(run_resolver "$FIX7" "$CFG7" D)
assert_tok "(7) D knobs unset" "MODEL=sonnet" "$OUT7"
assert_tok "(7) D knobs unset" "SPLIT_ROLE=false" "$OUT7"
assert_tok "(7) D knobs unset" "ROLES=single" "$OUT7"
assert_tok "(7) D knobs unset" "PATH=D" "$OUT7"

# (8) PATH D, needs-browser label -> inherit, reason needs-browser.
CFG8=$(make_config_root)
FIX8=$(make_fixture "fix(ui): quick" "$BODY_LOW" '[{"name":"needs-browser"}]')
OUT8=$(run_resolver "$FIX8" "$CFG8" D)
assert_tok "(8) D needs-browser" "MODEL=inherit" "$OUT8"
assert_tok "(8) D needs-browser" "REASON=needs-browser" "$OUT8"

# (9) PATH D, W2 vocab (concurrency/deadlock) -> opus, reason high-uncertainty.
CFG9=$(make_config_root)
FIX9=$(make_fixture "fix(foo): contention" "$BODY_W2D" '[]')
OUT9=$(run_resolver "$FIX9" "$CFG9" D)
assert_tok "(9) D W2 vocab" "MODEL=opus" "$OUT9"
assert_tok "(9) D W2 vocab" "REASON=high-uncertainty" "$OUT9"

# (10) invalid path letter A / C / pr-eval -> exit 2 + usage on stderr.
for bad in A C pr-eval; do
  inc
  CFGX=$(make_config_root)
  FIXX=$(make_fixture "x" "$BODY_LOW" '[]')
  ERR=$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIXX" \
        PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$CFGX" \
        bash "$HELPER" 999 "$bad" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$ERR" | grep -qiE 'usage|B\|D|B or D'; then
    pass_msg "(10) invalid path '$bad' -> exit 2 + usage"
  else
    fail_msg "(10) invalid path '$bad': expected exit 2 + usage, got rc=$rc err='$ERR'"
  fi
done

# Exit-0 contract on a normal verdict.
inc
CFGE=$(make_config_root)
FIXE=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIXE" \
  PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$CFGE" \
  bash "$HELPER" 999 B >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "exit 0 on normal verdict (token carries verdict, not exit code)"
else
  fail_msg "exit $rc on normal verdict (expected 0)"
fi

# ---- Task 2: split-role (#881) dispatch shape -------------------------------

# (11) PATH B, split-role true, knobs default -> red:opus,green:sonnet.
CFG11=$(make_config_root 'PIPELINE_PATH_B_SPLIT_ROLE=true')
FIX11=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT11=$(run_resolver "$FIX11" "$CFG11" B)
assert_tok "(11) B split-role default" "SPLIT_ROLE=true" "$OUT11"
assert_tok "(11) B split-role default" "ROLES=red:opus,green:sonnet" "$OUT11"

# (12) PATH B, split-role true + explicit opus -> red:opus,green:opus.
CFG12=$(make_config_root 'PIPELINE_PATH_B_SPLIT_ROLE=true' 'PIPELINE_PATH_B_MODEL_EXECUTE=opus')
FIX12=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT12=$(run_resolver "$FIX12" "$CFG12" B)
assert_tok "(12) B split-role explicit opus" "ROLES=red:opus,green:opus" "$OUT12"

# (13) PATH B, split-role true + W2 vocab -> implementer forced opus.
CFG13=$(make_config_root 'PIPELINE_PATH_B_SPLIT_ROLE=true')
FIX13=$(make_fixture "fix(auth): harden" "$BODY_W2" '[]')
OUT13=$(run_resolver "$FIX13" "$CFG13" B)
assert_tok "(13) B split-role W2" "ROLES=red:opus,green:opus" "$OUT13"

# (14) PATH B, split-role unset -> single shape.
CFG14=$(make_config_root)
FIX14=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT14=$(run_resolver "$FIX14" "$CFG14" B)
assert_tok "(14) B split-role unset" "SPLIT_ROLE=false" "$OUT14"
assert_tok "(14) B split-role unset" "ROLES=single" "$OUT14"

# (15) PATH D, split-role flag set -> still single (split-role is B-only).
CFG15=$(make_config_root 'PIPELINE_PATH_B_SPLIT_ROLE=true')
FIX15=$(make_fixture "fix(foo): quick" "$BODY_LOW" '[]')
OUT15=$(run_resolver "$FIX15" "$CFG15" D)
assert_tok "(15) D split-role flag set" "SPLIT_ROLE=false" "$OUT15"
assert_tok "(15) D split-role flag set" "ROLES=single" "$OUT15"

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
