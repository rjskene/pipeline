#!/bin/bash
set -uo pipefail

# Behavioral test for scripts/resolve-execute-dispatch.sh (issue #1056).
#
# The resolver is the SINGLE SOURCE OF TRUTH for the inline execute dispatch
# spec: given an issue number and a path letter (A|B|C|D), it resolves the full
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
#   PATH=<A|B|C|D>
#   MODEL=<sonnet|opus|haiku|fable>     # ALWAYS a NAMED model (#1186)
#   SPLIT_ROLE=<true|false>             # PATH B only; false for A/C/D
#   ROLES=<single | red:opus,green:<model>>
#   SCOPE=<all|low-blast>               # resolved PIPELINE_PATH_B_ELIGIBLE_SCOPE (B)
#   ELIGIBLE=<low-blast|high-blast>     # advisory passthrough (B only)
#   REASON=<token>                      # why MODEL resolved as it did (audit)
#
# #1186 — `inherit` is RETIRED as an emission. Under a Fable-ceiling session an
# unpinned dispatch silently becomes Fable, so "inherit the strong safe model"
# stopped being true: the two carve-out branches that emitted `MODEL=inherit`
# (`scope-low-blast-gated` and PATH-D `needs-browser`) now emit the NAMED
# `MODEL=opus` they always meant. The resolver additionally accepts PATH A and
# PATH C — previously those dispatched with no `model=` at all (no knob existed)
# — reading PIPELINE_PATH_{A,C}_MODEL_EXECUTE, unset ⇒ `opus`
# (`REASON=default-opus`), with no eligibility predicate and no carve-outs
# (execute's opus ceiling is already the default there).
#
# Usage guard: reject any argument that is not a path letter (A|B|C|D) with
# exit 2 + usage on stderr. Stage words (`pr-eval`, `plan`) stay refused — the
# W3 structural guard that pr-eval is NEVER routed through this resolver.
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

# Every stdout block the resolver produced, accumulated in a FILE (a variable
# would not survive the command-substitution subshell) for the #1186
# never-emits-inherit sweep at the end of the file.
ALL_OUT_FILE="$WORKDIR/all-dispatch-outputs.txt"
: > "$ALL_OUT_FILE"

# Run the resolver against a fixture + config root + path letter; echo full
# stdout (multi-line token block).
run_resolver() {
  local fixture="$1" cfgroot="$2" pathletter="$3"
  local out
  # Hermeticity (#1144, #1199): a dogfood host exports PIPELINE_REPO+
  # PIPELINE_BASE_BRANCH (run-test-suite.sh sources the live config). This
  # function itself re-sets PIPELINE_REPO="owner/repo" below, so once
  # PIPELINE_BASE_BRANCH is ALSO non-empty (inherited from the host), BOTH
  # halves of _resolve-config.sh's early-return predicate
  # (`[ -n "$PIPELINE_REPO" ] && [ -n "$PIPELINE_BASE_BRANCH" ]`) are true and
  # it no-ops — the temp make_config_root config is never sourced, so every
  # case's cfgroot is silently skipped in favor of shipped defaults (#1199).
  # PIPELINE_BASE_BRANCH is NOT just another leaked knob like the PATH-*
  # ones below: it is one of the two PREDICATE vars that gate whether the
  # fixture config is read AT ALL. Scrubbing the PATH-* knobs alone (the
  # #1144 remedy) cannot fix this — only unsetting PIPELINE_BASE_BRANCH (or
  # PIPELINE_REPO) restores the predicate to false so _resolve-config.sh
  # sources the cfgroot config, whose own PIPELINE_REPO/PIPELINE_BASE_BRANCH
  # lines (see make_config_root) then apply. If a future author adds a new
  # per-path or per-stage knob to this scrub list, that is
  # necessary for THAT knob's value but does nothing for this mechanism —
  # PIPELINE_BASE_BRANCH must stay scrubbed regardless of knob churn.
  # #1186 adds PIPELINE_PATH_{A,C}_MODEL_EXECUTE to the scrub set.
  out="$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fixture" \
    PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$cfgroot" \
    env -u PIPELINE_BASE_BRANCH \
        -u PIPELINE_PATH_A_MODEL_EXECUTE \
        -u PIPELINE_PATH_B_MODEL_EXECUTE \
        -u PIPELINE_PATH_C_MODEL_EXECUTE \
        -u PIPELINE_PATH_D_MODEL_EXECUTE \
        -u PIPELINE_PATH_B_ELIGIBLE_SCOPE \
        -u PIPELINE_PATH_B_SPLIT_ROLE \
    bash "$HELPER" 999 "$pathletter" 2>/dev/null)"
  printf '%s\n' "$out" >> "$ALL_OUT_FILE"
  printf '%s\n' "$out"
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

# Assert NO line of $out starts with the given "KEY=" prefix (#1186: PATH A/C
# have no eligibility predicate, so they emit neither SCOPE= nor ELIGIBLE=).
assert_no_key() {
  local desc="$1" key="$2" out="$3"
  inc
  if printf '%s\n' "$out" | grep -qE "^${key}="; then
    fail_msg "$desc: expected NO '${key}=' line, got:
$out"
  else
    pass_msg "$desc -> emits no '${key}=' line"
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

# (1) PATH B, knobs unset -> sonnet default, default-on split shape, scope all.
CFG1=$(make_config_root)
FIX1=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT1=$(run_resolver "$FIX1" "$CFG1" B)
assert_tok "(1) B knobs unset" "MODEL=sonnet" "$OUT1"
assert_tok "(1) B knobs unset" "SPLIT_ROLE=true" "$OUT1"
assert_tok "(1) B knobs unset" "ROLES=red:opus,green:sonnet" "$OUT1"
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

# (5) PATH B, scope=low-blast, high-blast (multi-module) issue -> the conservative
#     lane PINS opus (#1186: was MODEL=inherit — the reason token is unchanged,
#     only the emission is now the NAMED model the branch always meant).
CFG5=$(make_config_root 'PIPELINE_PATH_B_ELIGIBLE_SCOPE=low-blast')
FIX5=$(make_fixture "feat(x): big" "$BODY_HIGH" '[]')
OUT5=$(run_resolver "$FIX5" "$CFG5" B)
assert_tok "(5) B scope=low-blast high-blast" "MODEL=opus" "$OUT5"
assert_tok "(5) B scope=low-blast high-blast" "REASON=scope-low-blast-gated" "$OUT5"
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

# (8) PATH D, needs-browser label -> opus (#1186: the #960 carve-out semantics are
#     preserved verbatim; only the emission changes inherit -> the named model).
CFG8=$(make_config_root)
FIX8=$(make_fixture "fix(ui): quick" "$BODY_LOW" '[{"name":"needs-browser"}]')
OUT8=$(run_resolver "$FIX8" "$CFG8" D)
assert_tok "(8) D needs-browser" "MODEL=opus" "$OUT8"
assert_tok "(8) D needs-browser" "REASON=needs-browser" "$OUT8"

# (9) PATH D, W2 vocab (concurrency/deadlock) -> opus, reason high-uncertainty.
CFG9=$(make_config_root)
FIX9=$(make_fixture "fix(foo): contention" "$BODY_W2D" '[]')
OUT9=$(run_resolver "$FIX9" "$CFG9" D)
assert_tok "(9) D W2 vocab" "MODEL=opus" "$OUT9"
assert_tok "(9) D W2 vocab" "REASON=high-uncertainty" "$OUT9"

# (10) GENUINELY invalid arguments -> exit 2 + usage on stderr. #1186 narrows this
#      set: `A` and `C` are now ACCEPTED path letters (cases 16-19 below), so the
#      loop keeps only a non-path letter plus the STAGE words — the W3 structural
#      guard that pr-eval/plan are never routed through the execute resolver.
for bad in E pr-eval plan plan-eval; do
  inc
  CFGX=$(make_config_root)
  FIXX=$(make_fixture "x" "$BODY_LOW" '[]')
  ERR=$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIXX" \
        PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$CFGX" \
        env -u PIPELINE_PATH_A_MODEL_EXECUTE \
            -u PIPELINE_PATH_B_MODEL_EXECUTE \
            -u PIPELINE_PATH_C_MODEL_EXECUTE \
            -u PIPELINE_PATH_D_MODEL_EXECUTE \
            -u PIPELINE_PATH_B_ELIGIBLE_SCOPE \
            -u PIPELINE_PATH_B_SPLIT_ROLE \
        bash "$HELPER" 999 "$bad" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$ERR" | grep -qiE 'usage'; then
    pass_msg "(10) invalid arg '$bad' -> exit 2 + usage"
  else
    fail_msg "(10) invalid arg '$bad': expected exit 2 + usage, got rc=$rc err='$ERR'"
  fi
done

# Exit-0 contract on a normal verdict.
inc
CFGE=$(make_config_root)
FIXE=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIXE" \
  PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$CFGE" \
  env -u PIPELINE_PATH_B_MODEL_EXECUTE \
      -u PIPELINE_PATH_D_MODEL_EXECUTE \
      -u PIPELINE_PATH_B_ELIGIBLE_SCOPE \
      -u PIPELINE_PATH_B_SPLIT_ROLE \
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

# (14) PATH B, split-role unset -> default-on split shape.
CFG14=$(make_config_root)
FIX14=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT14=$(run_resolver "$FIX14" "$CFG14" B)
assert_tok "(14) B split-role unset" "SPLIT_ROLE=true" "$OUT14"
assert_tok "(14) B split-role unset" "ROLES=red:opus,green:sonnet" "$OUT14"

# (15) PATH D, split-role flag set -> still single (split-role is B-only).
CFG15=$(make_config_root 'PIPELINE_PATH_B_SPLIT_ROLE=true')
FIX15=$(make_fixture "fix(foo): quick" "$BODY_LOW" '[]')
OUT15=$(run_resolver "$FIX15" "$CFG15" D)
assert_tok "(15) D split-role flag set" "SPLIT_ROLE=false" "$OUT15"
assert_tok "(15) D split-role flag set" "ROLES=single" "$OUT15"

# ---- #1186: PATH A / PATH C acceptance --------------------------------------
# Before #1186 PATH A execute and every PATH C `tdd-implementer` leaf dispatched
# with NO `model=` at all (no knob existed), so they silently rode the session
# model. They now resolve through this same resolver: unset knob ⇒ the `opus`
# execute ceiling (REASON=default-opus), an explicit knob honored verbatim
# (REASON=explicit-knob). No eligibility predicate, no W2/needs-browser
# carve-outs (the default IS already the carve-out target), never split-role.

# (16) PATH A, knobs unset -> opus default, single shape.
CFG16=$(make_config_root)
FIX16=$(make_fixture "docs: update readme" "$BODY_LOW" '[{"name":"docs-only"}]')
OUT16=$(run_resolver "$FIX16" "$CFG16" A)
assert_tok "(16) A knobs unset" "PATH=A" "$OUT16"
assert_tok "(16) A knobs unset" "MODEL=opus" "$OUT16"
assert_tok "(16) A knobs unset" "REASON=default-opus" "$OUT16"
assert_tok "(16) A knobs unset" "SPLIT_ROLE=false" "$OUT16"
assert_tok "(16) A knobs unset" "ROLES=single" "$OUT16"
assert_no_key "(16) A knobs unset" "SCOPE" "$OUT16"
assert_no_key "(16) A knobs unset" "ELIGIBLE" "$OUT16"

# (17) PATH A + explicit PIPELINE_PATH_A_MODEL_EXECUTE=sonnet -> honored verbatim
#      (an operator override is honored, consistent with the B/D explicit-knob rule).
CFG17=$(make_config_root 'PIPELINE_PATH_A_MODEL_EXECUTE=sonnet')
FIX17=$(make_fixture "docs: update readme" "$BODY_LOW" '[{"name":"docs-only"}]')
OUT17=$(run_resolver "$FIX17" "$CFG17" A)
assert_tok "(17) A explicit sonnet" "MODEL=sonnet" "$OUT17"
assert_tok "(17) A explicit sonnet" "REASON=explicit-knob" "$OUT17"

# (18) PATH C, knobs unset -> opus default (applied to EVERY leaf dispatch),
#      single shape (split-role is PATH B only).
CFG18=$(make_config_root)
FIX18=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_HIGH" '[{"name":"multi-task"}]')
OUT18=$(run_resolver "$FIX18" "$CFG18" C)
assert_tok "(18) C knobs unset" "PATH=C" "$OUT18"
assert_tok "(18) C knobs unset" "MODEL=opus" "$OUT18"
assert_tok "(18) C knobs unset" "REASON=default-opus" "$OUT18"
assert_tok "(18) C knobs unset" "SPLIT_ROLE=false" "$OUT18"
assert_tok "(18) C knobs unset" "ROLES=single" "$OUT18"
assert_no_key "(18) C knobs unset" "SCOPE" "$OUT18"
assert_no_key "(18) C knobs unset" "ELIGIBLE" "$OUT18"

# (19) PATH C + explicit PIPELINE_PATH_C_MODEL_EXECUTE=sonnet -> honored verbatim.
CFG19=$(make_config_root 'PIPELINE_PATH_C_MODEL_EXECUTE=sonnet')
FIX19=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_HIGH" '[{"name":"multi-task"}]')
OUT19=$(run_resolver "$FIX19" "$CFG19" C)
assert_tok "(19) C explicit sonnet" "MODEL=sonnet" "$OUT19"
assert_tok "(19) C explicit sonnet" "REASON=explicit-knob" "$OUT19"

# (20) NEVER-EMITS-INHERIT sweep over EVERY case output above. `inherit` is
#      retired as an emission (#1186): under a Fable-ceiling session an unpinned
#      dispatch silently becomes Fable, so every carve-out must name its model.
#      The sweep also asserts its own substrate is non-vacuous, so "no output at
#      all" cannot pass it.
MODEL_LINES="$(grep -c '^MODEL=' "$ALL_OUT_FILE" 2>/dev/null || echo 0)"
inc
if [ "$MODEL_LINES" -ge 18 ]; then
  pass_msg "(20) sweep substrate non-vacuous ($MODEL_LINES MODEL= emissions captured)"
else
  fail_msg "(20) sweep substrate vacuous: expected >= 18 MODEL= emissions, captured $MODEL_LINES"
fi
inc
if [ "$MODEL_LINES" -ge 18 ] && ! grep -q 'inherit' "$ALL_OUT_FILE"; then
  pass_msg "(20a) no case emitted 'inherit' (MODEL= is ALWAYS a named model)"
else
  fail_msg "(20a) resolver emitted 'inherit' (or produced no output):
$(grep -n 'inherit' "$ALL_OUT_FILE" 2>/dev/null || echo '<no output captured>')"
fi
inc
BAD_MODELS="$(grep '^MODEL=' "$ALL_OUT_FILE" 2>/dev/null | grep -vE '^MODEL=(fable|opus|sonnet|haiku)$' || true)"
if [ "$MODEL_LINES" -ge 18 ] && [ -z "$BAD_MODELS" ]; then
  pass_msg "(20b) every MODEL= is one of fable|opus|sonnet|haiku"
else
  fail_msg "(20b) non-named MODEL= emissions: '${BAD_MODELS:-<no output captured>}'"
fi

# (21) Suite hermeticity regression guard (#1199): with PIPELINE_BASE_BRANCH
#      exported in THIS test process's own environment (simulating a dogfood
#      host that has sourced the live pipeline.config into the calling
#      shell), a representative explicit-knob case must still resolve from
#      its make_config_root fixture, not silently fall back to the shipped
#      default. Before #1199, run_resolver() re-set PIPELINE_REPO but never
#      scrubbed the inherited PIPELINE_BASE_BRANCH, so BOTH halves of
#      _resolve-config.sh's early-return predicate were true, the fixture
#      config was never sourced, and this case's MODEL=opus fell back to
#      MODEL=sonnet (the shipped PATH B default) instead.
export PIPELINE_BASE_BRANCH="staging"
CFG21=$(make_config_root 'PIPELINE_PATH_B_MODEL_EXECUTE=opus')
FIX21=$(make_fixture "fix(foo): tweak" "$BODY_LOW" '[]')
OUT21=$(run_resolver "$FIX21" "$CFG21" B)
unset PIPELINE_BASE_BRANCH
assert_tok "(21) hermeticity guard: explicit knob survives host PIPELINE_BASE_BRANCH" "MODEL=opus" "$OUT21"
assert_tok "(21) hermeticity guard: explicit knob survives host PIPELINE_BASE_BRANCH" "REASON=explicit-knob" "$OUT21"

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
