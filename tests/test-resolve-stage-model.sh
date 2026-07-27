#!/bin/bash
set -uo pipefail

# Behavioral test for scripts/resolve-stage-model.sh (issue #1186).
#
# The resolver is the SINGLE SOURCE OF TRUTH for the per-stage model pin of the
# three QUALITY-CRITICAL dispatched stages — `plan`, `plan-eval`, `pr-eval`.
# Before #1186 those stages carried NO `model=` at all: they silently INHERITED
# the orchestrator session model, so the load-bearing W3 property ("pr-eval is
# always Opus") was an inheritance side-effect rather than a pin. Under a Fable
# session every one of those sites silently upshifts to Fable — doubling the
# most expensive lanes and routing the security-adjacent W2 carve-out onto the
# model most likely to return `stop_reason: refusal` mid-gate.
#
# This resolver replaces the assumption with an explicit pin. It mirrors
# scripts/resolve-execute-dispatch.sh (#1056 lesson: prose drifts, scripts
# don't): one token per line on stdout, ALWAYS exit 0 in normal operation
# (the verdict rides the tokens), exit 2 reserved for a usage error.
#
#   ISSUE=<N>
#   STAGE=<plan|plan-eval|pr-eval>
#   PATH=<A|B|C|D>
#   MODEL=<fable|opus|sonnet|haiku>   # ALWAYS named; `inherit` is NEVER emitted
#   REASON=<default-pin|path-c-fable|follows-producer|high-uncertainty|explicit-knob>
#
# Routing rules under test:
#   pr-eval   -> ${PIPELINE_STAGE_MODEL_PR_EVAL:-opus}. No carve-out lowers it.
#               An explicitly-set knob BELOW the resolved execute tier is
#               HONORED (REASON=explicit-knob) but emits a stderr WARN —
#               operator override is allowed, silence is not.
#   plan      -> PATH C ⇒ ${PIPELINE_PATH_C_MODEL_PLAN:-fable} (cross-unit
#               meshing); PATH A/B ⇒ opus. A W2 high-uncertainty match
#               (scripts/_high-uncertainty-match.sh — the regex is NEVER
#               redefined, #1039) ⇒ opus, overriding BOTH the fable default and
#               an explicit knob (the refusal-risk carve-out wins, same
#               precedence as the execute resolver).
#   plan-eval -> tier-max(this issue's resolved plan model,
#               ${PIPELINE_STAGE_MODEL_PLAN_EVAL:-opus}) so the gate NEVER lands
#               below its producer. REASON=follows-producer when the producer
#               tier decided it.
#   Tier order for max/WARN comparisons: haiku(1) < sonnet(2) < opus(3) < fable(4).
#
# PATH detection mirrors plan-issue Step 3a label precedence: `docs-only`⇒A,
# `quick-fix`⇒D, `multi-task`⇒C, else B — from ONE
# `gh issue view --json title,body,labels` fetch (which also feeds the W2 match).
#
# Test shape copied from tests/test-resolve-execute-dispatch.sh: a `gh` stub on
# PATH serving canned title/body/labels fixtures, plus a temp pipeline.config
# via PIPELINE_PROJECT_ROOT, plus an env scrub of every knob the resolver reads
# (a dogfood host exports the live config, #1144) so each case's cfgroot — or its
# intentional absence ⇒ shipped default — is authoritative.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/resolve-stage-model.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

echo "== test-resolve-stage-model (issue #1186) =="

# The helper's ABSENCE is itself a failure, but the cases below still run so the
# RED signal is per-case (each assert reports the token it wanted and got none)
# rather than a single opaque abort.
inc
if [ -f "$HELPER" ]; then
  pass_msg "helper exists at scripts/resolve-stage-model.sh"
else
  fail_msg "helper NOT found at $HELPER (resolve-stage-model.sh: No such file)"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"

# `gh` stub: emits a canned JSON document read from $GH_FIXTURE for the
# `gh issue view <N> --json title,body,labels` call (and its --jq variants).
# Mirrors tests/test-resolve-execute-dispatch.sh so the resolver's internal
# delegation to resolve-execute-dispatch.sh / path-b-execute-eligible.sh (the
# pr-eval WARN comparison) sees the SAME fixture.
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
# would not survive the command-substitution subshell) for the case-(11)
# never-emits-inherit sweep.
ALL_OUT_FILE="$WORKDIR/all-stage-outputs.txt"
: > "$ALL_OUT_FILE"

# Shared env scrub: every knob the resolver (and its internal execute-tier
# delegation) reads.
run_stage_raw() {
  # run_stage_raw <fixture> <cfgroot> <stage> <redirect-mode: out|err>
  local fixture="$1" cfgroot="$2" stage="$3" mode="$4"
  if [ "$mode" = "err" ]; then
    PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fixture" \
      PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$cfgroot" \
      env -u PIPELINE_STAGE_MODEL_PLAN_EVAL \
          -u PIPELINE_STAGE_MODEL_PR_EVAL \
          -u PIPELINE_PATH_C_MODEL_PLAN \
          -u PIPELINE_PATH_A_MODEL_EXECUTE \
          -u PIPELINE_PATH_B_MODEL_EXECUTE \
          -u PIPELINE_PATH_C_MODEL_EXECUTE \
          -u PIPELINE_PATH_D_MODEL_EXECUTE \
          -u PIPELINE_PATH_B_ELIGIBLE_SCOPE \
          -u PIPELINE_PATH_B_SPLIT_ROLE \
      bash "$HELPER" 999 "$stage" 2>&1 >/dev/null
  else
    PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fixture" \
      PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$cfgroot" \
      env -u PIPELINE_STAGE_MODEL_PLAN_EVAL \
          -u PIPELINE_STAGE_MODEL_PR_EVAL \
          -u PIPELINE_PATH_C_MODEL_PLAN \
          -u PIPELINE_PATH_A_MODEL_EXECUTE \
          -u PIPELINE_PATH_B_MODEL_EXECUTE \
          -u PIPELINE_PATH_C_MODEL_EXECUTE \
          -u PIPELINE_PATH_D_MODEL_EXECUTE \
          -u PIPELINE_PATH_B_ELIGIBLE_SCOPE \
          -u PIPELINE_PATH_B_SPLIT_ROLE \
      bash "$HELPER" 999 "$stage" 2>/dev/null
  fi
}

# Run the resolver, record stdout in the sweep file, echo it back.
run_stage() {
  local out
  out="$(run_stage_raw "$1" "$2" "$3" out)"
  printf '%s\n' "$out" >> "$ALL_OUT_FILE"
  printf '%s\n' "$out"
}

# Run the resolver and echo STDERR only (the WARN channel).
run_stage_err() {
  run_stage_raw "$1" "$2" "$3" err
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

# Clean single-module body (no W2 signal).
BODY_LOW=$'## Summary\nadjust a helper\n\n## Affected areas\n- `scripts/foo.sh`\n'
# W2 high-uncertainty body (security/auth vocab — the shared #1039 regex).
BODY_W2=$'## Summary\nHarden the authentication and security path.\n\n## Affected areas\n- `scripts/foo.sh`\n'
# PATH C decomposition body (leaf targets).
BODY_C=$'## Summary\nsplit across leaves\n\n## Tasks\n- target=scripts/\n- target=skills/\n'
# PATH C body carrying W2 vocab (the refusal-risk downgrade case).
BODY_C_W2=$'## Summary\nSplit the authentication/security migration across leaves.\n\n## Tasks\n- target=scripts/\n- target=skills/\n'

LBL_NONE='[]'
LBL_A='[{"name":"docs-only"}]'
LBL_C='[{"name":"multi-task"}]'
LBL_D='[{"name":"quick-fix"}]'

# ---- pr-eval: the W3 pin ----------------------------------------------------

# (1) pr-eval, knobs unset -> opus by DEFAULT PIN (not by inheritance).
CFG1=$(make_config_root)
FIX1=$(make_fixture "fix(foo): tweak" "$BODY_LOW" "$LBL_NONE")
OUT1=$(run_stage "$FIX1" "$CFG1" pr-eval)
assert_tok "(1) pr-eval default" "MODEL=opus" "$OUT1"
assert_tok "(1) pr-eval default" "REASON=default-pin" "$OUT1"
assert_tok "(1) pr-eval default" "STAGE=pr-eval" "$OUT1"
assert_tok "(1) pr-eval default" "PATH=B" "$OUT1"
assert_tok "(1) pr-eval default" "ISSUE=999" "$OUT1"

# (2) pr-eval, PIPELINE_STAGE_MODEL_PR_EVAL=sonnet on a PATH B issue whose
#     EXECUTE tier resolves opus (W2 vocab body). knob-tier sonnet(2) <
#     execute-tier opus(3) => the knob is HONORED verbatim (operator override)
#     but the resolver MUST emit a stderr WARN. Silence is the bug.
CFG2=$(make_config_root 'PIPELINE_STAGE_MODEL_PR_EVAL=sonnet')
FIX2=$(make_fixture "fix(auth): harden" "$BODY_W2" "$LBL_NONE")
OUT2=$(run_stage "$FIX2" "$CFG2" pr-eval)
assert_tok "(2) pr-eval explicit sonnet knob" "MODEL=sonnet" "$OUT2"
assert_tok "(2) pr-eval explicit sonnet knob" "REASON=explicit-knob" "$OUT2"
ERR2=$(run_stage_err "$FIX2" "$CFG2" pr-eval)
inc
if printf '%s' "$ERR2" | grep -q "WARN"; then
  pass_msg "(2) pr-eval knob below execute tier -> stderr WARN (override honored, never silent)"
else
  fail_msg "(2) pr-eval knob below execute tier: expected a stderr WARN, got err='$ERR2'"
fi

# ---- plan: opus floor, PATH C fable, W2 downgrade ---------------------------

# (3a) plan, PATH A (docs-only) -> opus default pin.
CFG3A=$(make_config_root)
FIX3A=$(make_fixture "docs: update readme" "$BODY_LOW" "$LBL_A")
OUT3A=$(run_stage "$FIX3A" "$CFG3A" plan)
assert_tok "(3a) plan PATH A" "MODEL=opus" "$OUT3A"
assert_tok "(3a) plan PATH A" "REASON=default-pin" "$OUT3A"
assert_tok "(3a) plan PATH A" "PATH=A" "$OUT3A"

# (3b) plan, PATH B (no path label) -> opus default pin.
CFG3B=$(make_config_root)
FIX3B=$(make_fixture "fix(foo): tweak" "$BODY_LOW" "$LBL_NONE")
OUT3B=$(run_stage "$FIX3B" "$CFG3B" plan)
assert_tok "(3b) plan PATH B" "MODEL=opus" "$OUT3B"
assert_tok "(3b) plan PATH B" "REASON=default-pin" "$OUT3B"
assert_tok "(3b) plan PATH B" "PATH=B" "$OUT3B"

# (3c) plan, PATH D (quick-fix) — never dispatched through this resolver (the
#      collapsed inline D dispatch carries the resolved EXECUTE model), but the
#      script still resolves defensively and exits 0 rather than erroring.
CFG3C=$(make_config_root)
FIX3C=$(make_fixture "fix(foo): quick" "$BODY_LOW" "$LBL_D")
OUT3C=$(run_stage "$FIX3C" "$CFG3C" plan)
assert_tok "(3c) plan PATH D defensive" "MODEL=opus" "$OUT3C"
assert_tok "(3c) plan PATH D defensive" "REASON=default-pin" "$OUT3C"
assert_tok "(3c) plan PATH D defensive" "PATH=D" "$OUT3C"

# (4) plan, PATH C (multi-task) -> fable (cross-unit meshing is Fable's edge).
CFG4=$(make_config_root)
FIX4=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_C" "$LBL_C")
OUT4=$(run_stage "$FIX4" "$CFG4" plan)
assert_tok "(4) plan PATH C" "MODEL=fable" "$OUT4"
assert_tok "(4) plan PATH C" "REASON=path-c-fable" "$OUT4"
assert_tok "(4) plan PATH C" "PATH=C" "$OUT4"

# (5) plan, PATH C + W2 vocab -> DOWNGRADE to opus. Deliberate: security-vocab
#     issues on Fable risk stop_reason:refusal mid-pipeline, and Fable's review
#     gains explicitly exclude security analysis.
CFG5=$(make_config_root)
FIX5=$(make_fixture "feat(auth): security migration rollout" "$BODY_C_W2" "$LBL_C")
OUT5=$(run_stage "$FIX5" "$CFG5" plan)
assert_tok "(5) plan PATH C + W2" "MODEL=opus" "$OUT5"
assert_tok "(5) plan PATH C + W2" "REASON=high-uncertainty" "$OUT5"

# (5b) The W2 carve-out beats an EXPLICIT fable knob too (refusal-risk wins,
#      same precedence as the execute resolver's W2 carve-out).
CFG5B=$(make_config_root 'PIPELINE_PATH_C_MODEL_PLAN=fable')
FIX5B=$(make_fixture "feat(auth): security migration rollout" "$BODY_C_W2" "$LBL_C")
OUT5B=$(run_stage "$FIX5B" "$CFG5B" plan)
assert_tok "(5b) plan PATH C + W2 overrides explicit fable knob" "MODEL=opus" "$OUT5B"
assert_tok "(5b) plan PATH C + W2 overrides explicit fable knob" "REASON=high-uncertainty" "$OUT5B"

# (6) plan, PATH C + PIPELINE_PATH_C_MODEL_PLAN=opus -> honored verbatim.
CFG6=$(make_config_root 'PIPELINE_PATH_C_MODEL_PLAN=opus')
FIX6=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_C" "$LBL_C")
OUT6=$(run_stage "$FIX6" "$CFG6" plan)
assert_tok "(6) plan PATH C explicit knob" "MODEL=opus" "$OUT6"
assert_tok "(6) plan PATH C explicit knob" "REASON=explicit-knob" "$OUT6"

# ---- plan-eval: gate never below producer -----------------------------------

# (7) plan-eval, PATH C -> follows its plan producer (fable), so the gate is not
#     evaluating a fable-produced plan from a lower tier.
CFG7=$(make_config_root)
FIX7=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_C" "$LBL_C")
OUT7=$(run_stage "$FIX7" "$CFG7" plan-eval)
assert_tok "(7) plan-eval PATH C" "MODEL=fable" "$OUT7"
assert_tok "(7) plan-eval PATH C" "REASON=follows-producer" "$OUT7"
assert_tok "(7) plan-eval PATH C" "STAGE=plan-eval" "$OUT7"

# (8) plan-eval, PATH B -> opus default pin (producer is opus; tier-max is opus).
CFG8=$(make_config_root)
FIX8=$(make_fixture "fix(foo): tweak" "$BODY_LOW" "$LBL_NONE")
OUT8=$(run_stage "$FIX8" "$CFG8" plan-eval)
assert_tok "(8) plan-eval PATH B" "MODEL=opus" "$OUT8"
assert_tok "(8) plan-eval PATH B" "REASON=default-pin" "$OUT8"

# (9) plan-eval, PATH C + PIPELINE_STAGE_MODEL_PLAN_EVAL=sonnet -> the knob
#     CANNOT drop the gate below its producer: tier-max(fable, sonnet) = fable.
CFG9=$(make_config_root 'PIPELINE_STAGE_MODEL_PLAN_EVAL=sonnet')
FIX9=$(make_fixture "feat(x): multi-leaf rollout" "$BODY_C" "$LBL_C")
OUT9=$(run_stage "$FIX9" "$CFG9" plan-eval)
assert_tok "(9) plan-eval PATH C, knob below producer" "MODEL=fable" "$OUT9"
assert_tok "(9) plan-eval PATH C, knob below producer" "REASON=follows-producer" "$OUT9"

# (10) plan-eval, PATH C + W2 -> the producer downgraded to opus, so the gate
#      lands on opus too (never below its producer, never on the refusal-risk
#      model for security-vocab work).
CFG10=$(make_config_root)
FIX10=$(make_fixture "feat(auth): security migration rollout" "$BODY_C_W2" "$LBL_C")
OUT10=$(run_stage "$FIX10" "$CFG10" plan-eval)
assert_tok "(10) plan-eval PATH C + W2" "MODEL=opus" "$OUT10"

# ---- (11) never-emits-inherit sweep -----------------------------------------
# `inherit` is NOT a valid emission of this resolver in ANY configuration — that
# is the whole point of #1186 (an unpinned dispatch silently becomes the session
# model). Sweep EVERY stdout block produced above.
# The sweep must never pass VACUOUSLY: it asserts a MODEL= line was captured for
# every resolver invocation above (13), so "no output at all" fails here too.
MODEL_LINES="$(grep -c '^MODEL=' "$ALL_OUT_FILE" 2>/dev/null || echo 0)"
inc
if [ "$MODEL_LINES" -ge 13 ]; then
  pass_msg "(11) sweep substrate non-vacuous ($MODEL_LINES MODEL= emissions captured)"
else
  fail_msg "(11) sweep substrate vacuous: expected >= 13 MODEL= emissions, captured $MODEL_LINES"
fi

inc
if [ "$MODEL_LINES" -ge 13 ] && ! grep -q "inherit" "$ALL_OUT_FILE"; then
  pass_msg "(11a) no case emitted 'inherit' (MODEL= is ALWAYS a named model)"
else
  fail_msg "(11a) resolver emitted 'inherit' (or produced no output):
$(grep -n 'inherit' "$ALL_OUT_FILE" 2>/dev/null || echo '<no output captured>')"
fi

# Every emitted MODEL= must be one of the four named models.
inc
BAD_MODELS="$(grep '^MODEL=' "$ALL_OUT_FILE" 2>/dev/null | grep -vE '^MODEL=(fable|opus|sonnet|haiku)$' || true)"
if [ "$MODEL_LINES" -ge 13 ] && [ -z "$BAD_MODELS" ]; then
  pass_msg "(11b) every MODEL= is one of fable|opus|sonnet|haiku"
else
  fail_msg "(11b) non-named MODEL= emissions: '${BAD_MODELS:-<no output captured>}'"
fi

# ---- (12) usage guard + exit-code contract ----------------------------------

run_usage_case() {
  # run_usage_case <label> <args...> ; asserts exit 2 + usage on stderr.
  local label="$1"; shift
  local cfg fix err rc
  cfg=$(make_config_root)
  fix=$(make_fixture "x" "$BODY_LOW" "$LBL_NONE")
  inc
  err=$(PATH="$STUB_DIR:$PATH" GH_FIXTURE="$fix" \
        PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$cfg" \
        env -u PIPELINE_STAGE_MODEL_PLAN_EVAL \
            -u PIPELINE_STAGE_MODEL_PR_EVAL \
            -u PIPELINE_PATH_C_MODEL_PLAN \
        bash "$HELPER" "$@" 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -qiE 'usage'; then
    pass_msg "(12) $label -> exit 2 + usage on stderr"
  else
    fail_msg "(12) $label: expected exit 2 + usage, got rc=$rc err='$err'"
  fi
}

run_usage_case "no args"
run_usage_case "issue only" 999
run_usage_case "bad stage 'execute'" 999 execute
run_usage_case "bad stage 'pr_eval'" 999 pr_eval
run_usage_case "bad stage 'B'" 999 B

# Exit-0 contract on a normal verdict (the token carries the verdict).
inc
CFGE=$(make_config_root)
FIXE=$(make_fixture "fix(foo): tweak" "$BODY_LOW" "$LBL_NONE")
PATH="$STUB_DIR:$PATH" GH_FIXTURE="$FIXE" \
  PIPELINE_REPO="owner/repo" PIPELINE_PROJECT_ROOT="$CFGE" \
  env -u PIPELINE_STAGE_MODEL_PLAN_EVAL \
      -u PIPELINE_STAGE_MODEL_PR_EVAL \
      -u PIPELINE_PATH_C_MODEL_PLAN \
  bash "$HELPER" 999 pr-eval >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass_msg "exit 0 on normal verdict (token carries verdict, not exit code)"
else
  fail_msg "exit $rc on normal verdict (expected 0)"
fi

echo ""
echo "== summary: $PASS passed, $FAIL failed (of $TESTS) =="
[ "$FAIL" -eq 0 ]
