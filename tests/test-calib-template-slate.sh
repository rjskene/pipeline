#!/bin/bash
# Tests for the calibration sandbox assets under dev/calib:
#
#   dev/calib/template/ — a consumer-shaped sandbox project the pipeline can be
#                         pointed at (its own pipeline.config, its own test
#                         runner, its own CI workflow).
#   dev/calib/slate/    — five canned issues (title/body/reference test/expected
#                         files) covering the routing shapes the calibration
#                         run needs: docs-only, quick-fix, plain feature,
#                         high-uncertainty (race + auth), and multi-directory.
#
# Nothing here shells out to the network or to `gh`; every assertion is a
# filesystem / content / exit-code check, plus a live run of the template test
# suite and of each slate reference test against a pristine copy of the
# template (each reference test MUST fail there — that is what makes it a
# usable acceptance check once the sandbox issue is fixed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALIB_DIR="$ROOT/dev/calib"
TEMPLATE_DIR="$CALIB_DIR/template"
SLATE_DIR="$CALIB_DIR/slate"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

JSON_LOAD='import json,sys; json.load(open(sys.argv[1]))'

# ---------------------------------------------------------------------------
echo "== (a) template layout =="
# ---------------------------------------------------------------------------

for rel in pipeline.config claude-settings.local.json .gitignore README.md \
           tests/run.sh .github/workflows/ci.yml docs/usage.md docs/architecture.md; do
  if [ -f "$TEMPLATE_DIR/$rel" ]; then
    pass_msg "template carries $rel"
  else
    fail_msg "template missing $rel"
  fi
done

if [ -x "$TEMPLATE_DIR/tests/run.sh" ]; then
  pass_msg "template tests/run.sh is executable"
else
  fail_msg "template tests/run.sh is not executable"
fi

if [ -x "$TEMPLATE_DIR/bin/calibctl" ]; then
  pass_msg "template bin/calibctl is executable"
else
  fail_msg "template bin/calibctl is not executable"
fi

code_count=$(find "$TEMPLATE_DIR/bin" "$TEMPLATE_DIR/lib" -type f 2>/dev/null | wc -l)
if [ "$code_count" -ge 3 ]; then
  pass_msg "template has $code_count files under bin/ + lib/ (>= 3)"
else
  fail_msg "template has only $code_count files under bin/ + lib/ (want >= 3)"
fi

case_count=$(find "$TEMPLATE_DIR/tests" -name 'case-*.sh' -type f 2>/dev/null | wc -l)
if [ "$case_count" -ge 4 ]; then
  pass_msg "template has $case_count tests/case-*.sh files (>= 4)"
else
  fail_msg "template has only $case_count tests/case-*.sh files (want >= 4)"
fi

if grep -q 'tests/run.sh' "$TEMPLATE_DIR/.github/workflows/ci.yml" 2>/dev/null; then
  pass_msg "template CI workflow runs tests/run.sh"
else
  fail_msg "template CI workflow does not run tests/run.sh"
fi

if [ -d "$TEMPLATE_DIR/.claude" ]; then
  fail_msg "template must not carry a nested .claude/ directory"
else
  pass_msg "template carries no nested .claude/ directory"
fi

# ---------------------------------------------------------------------------
echo "== (b) sandbox pipeline.config values =="
# ---------------------------------------------------------------------------

cfg="$TEMPLATE_DIR/pipeline.config"
check_cfg() {
  local var="$1" want="$2" got
  got=$(grep -E "^${var}=" "$cfg" 2>/dev/null | tail -1 | sed -e "s/^${var}=//" -e "s/[[:space:]]*#.*$//" -e "s/^['\"]//" -e "s/['\"]$//")
  if [ "$got" = "$want" ]; then
    pass_msg "pipeline.config $var=$want"
  else
    fail_msg "pipeline.config $var is '$got' (want '$want')"
  fi
}
check_cfg PIPELINE_REPO "rjskene/pipeline-calib"
check_cfg PIPELINE_BASE_BRANCH "main"
check_cfg PIPELINE_TEST_CMD "bash tests/run.sh"
check_cfg PIPELINE_LOGS_ENABLED "true"
check_cfg PIPELINE_TEST_FILE_GLOBS "case-*.sh"

# The sandbox config carries EXACTLY the knobs the sandbox consumes, and every
# one of them is declared in pipeline.config.example. Pinning the SET (rather
# than naming the knobs that were dropped) keeps this file free of tokens the
# config-drift lint would flag, and catches any future inert knob for free.
want_knobs="PIPELINE_BASE_BRANCH PIPELINE_INSTALL_CMD PIPELINE_LOGS_ENABLED PIPELINE_REPO PIPELINE_SEED_CMD PIPELINE_TEST_CMD PIPELINE_TEST_FILE_GLOBS PIPELINE_WORKTREE_PREFIX"
got_knobs=$(grep -oE '^[[:space:]]*PIPELINE_[A-Z0-9_]+=' "$cfg" | sed 's/[[:space:]]//g; s/=$//' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
if [ "$got_knobs" = "$want_knobs" ]; then
  pass_msg "pipeline.config knob set is exactly the eight declared knobs"
else
  fail_msg "pipeline.config knob set is '$got_knobs' (want '$want_knobs')"
fi

# The headless calibration session reads this file; a comment telling it a human
# will close the loop is an instruction to stop and wait for one.
if grep -qi 'human closes' "$cfg"; then
  fail_msg "pipeline.config still tells the session a human closes the loop"
else
  pass_msg "pipeline.config carries no 'human closes' comment"
fi

# ---------------------------------------------------------------------------
echo "== (c) sandbox claude settings disable both marketplace plugins =="
# ---------------------------------------------------------------------------

settings="$TEMPLATE_DIR/claude-settings.local.json"
if python3 -c "$JSON_LOAD" "$settings" >/dev/null 2>&1; then
  pass_msg "claude-settings.local.json is valid JSON"
else
  fail_msg "claude-settings.local.json is not valid JSON"
fi

for plugin in "pipeline@claude-pipeline" "pipeline@claude-pipeline-local"; do
  got=$(python3 - "$settings" "$plugin" <<'PY' 2>/dev/null
import json, sys
data = json.load(open(sys.argv[1]))
plugins = data.get("enabledPlugins", {})
print(repr(plugins.get(sys.argv[2], "MISSING")))
PY
)
  if [ "$got" = "False" ]; then
    pass_msg "enabledPlugins['$plugin'] is false"
  else
    fail_msg "enabledPlugins['$plugin'] is $got (want False)"
  fi
done

# ---------------------------------------------------------------------------
echo "== (c2) sandbox claude settings register the plugin logging hooks =="
# ---------------------------------------------------------------------------
# The sandbox must record tool use, subagent dispatches and agent cost, or a
# calibration run grades `cost=` as n/a. The hooks live in the plugin build
# under calibration, so every command is rooted at the plugin root — the
# sandbox project has no hooks/ directory of its own. The dogfood-only hooks
# (comment-trust, dogfood refresh/heal, doctor-on-update) are NOT carried.

hooks_report=$(python3 - "$settings" <<'PY' 2>/dev/null
import json, sys

data = json.load(open(sys.argv[1]))
hooks = data.get("hooks")
if not isinstance(hooks, dict) or not hooks:
    print("no-hooks-key")
    sys.exit(0)


def commands(event, matcher):
    out = []
    for entry in hooks.get(event, []):
        if entry.get("matcher") != matcher:
            continue
        for hook in entry.get("hooks", []):
            out.append(hook.get("command", ""))
    return out


def every_command():
    for entries in hooks.values():
        for entry in entries:
            for hook in entry.get("hooks", []):
                yield hook.get("command", "")


def has(cmds, needle):
    return any(needle in cmd for cmd in cmds)


post_star = commands("PostToolUse", "*")
post_agent = commands("PostToolUse", "Agent")
stop_star = commands("Stop", "*")

print("has-hooks True")
print("post-star-tool-use", has(post_star, "log-tool-use.sh"))
print("post-agent-subagent", has(post_agent, "log_subagent.py"))
print("post-agent-cost", has(post_agent, "capture_agent_cost.py"))
print("stop-cost", has(stop_star, "capture_agent_cost.py"))

prefixes = ("bash ${CLAUDE_PLUGIN_ROOT}/hooks/", "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/")
stray = [c for c in every_command() if not c.startswith(prefixes)]
print("plugin-root-rooted", not stray, " ".join(stray))

dogfood_only = ("enforce-comment-trust", "dogfood-", "doctor-on-update")
carried = [c for c in every_command() if any(t in c for t in dogfood_only)]
print("no-dogfood-only", not carried, " ".join(carried))
PY
)

hook_check() {
  local key="$1" desc="$2" got detail
  got=$(printf '%s\n' "$hooks_report" | awk -v k="$key" '$1 == k { print $2 }')
  detail=$(printf '%s\n' "$hooks_report" | awk -v k="$key" '$1 == k { $1 = ""; $2 = ""; sub(/^ +/, ""); print }')
  if [ "$got" = "True" ]; then
    pass_msg "$desc"
  else
    fail_msg "$desc — got '${got:-no hooks key}'${detail:+ (offenders: $detail)}"
  fi
}

hook_check has-hooks "claude-settings.local.json declares a hooks object"
hook_check post-star-tool-use "PostToolUse '*' logs tool use"
hook_check post-agent-subagent "PostToolUse 'Agent' logs subagent dispatches"
hook_check post-agent-cost "PostToolUse 'Agent' captures agent cost"
hook_check stop-cost "Stop '*' captures agent cost"
hook_check plugin-root-rooted "every hook command is rooted at the plugin root's hooks/ dir"
hook_check no-dogfood-only "no dogfood-only hook is carried into the sandbox"

# ---------------------------------------------------------------------------
echo "== (d) slate shape =="
# ---------------------------------------------------------------------------

mapfile -t slate_dirs < <(find "$SLATE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
if [ "${#slate_dirs[@]}" -eq 5 ]; then
  pass_msg "slate has exactly 5 issue directories"
else
  fail_msg "slate has ${#slate_dirs[@]} issue directories (want exactly 5)"
fi

for d in "${slate_dirs[@]}"; do
  name=$(basename "$d")
  for f in title.txt body.md expected-files.txt; do
    if [ -s "$d/$f" ]; then
      pass_msg "$name/$f exists and is non-empty"
    else
      fail_msg "$name/$f missing or empty"
    fi
  done
  if [ -x "$d/reference-test.sh" ]; then
    pass_msg "$name/reference-test.sh is executable"
  else
    fail_msg "$name/reference-test.sh missing or not executable"
  fi
done

# ---------------------------------------------------------------------------
echo "== (e) slate routing shapes =="
# ---------------------------------------------------------------------------

docs_only=0
quick_fix=0
feature=0
race_auth=0
lib_and_docs=0

for d in "${slate_dirs[@]}"; do
  ef="$d/expected-files.txt"
  body="$d/body.md"
  title="$d/title.txt"
  [ -f "$ef" ] || continue

  # docs-only: every expected file lives under docs/
  non_docs=$(grep -vE '^[[:space:]]*$' "$ef" | grep -cvE '^docs/')
  [ "$non_docs" -eq 0 ] && docs_only=$((docs_only + 1))

  # multi-directory: expected files span >= 2 top-level dirs AND include lib/ + docs/
  tops=$(grep -vE '^[[:space:]]*$' "$ef" | awk -F/ '{print $1}' | sort -u | wc -l)
  if [ "$tops" -ge 2 ] && grep -qE '^lib/' "$ef" && grep -qE '^docs/' "$ef"; then
    lib_and_docs=$((lib_and_docs + 1))
  fi

  [ -f "$body" ] || continue
  grep -qiE 'quick[ -]fix' "$body" && quick_fix=$((quick_fix + 1))
  if grep -qiw 'race' "$body" && grep -qiw 'auth' "$body"; then
    race_auth=$((race_auth + 1))
  fi
  [ -f "$title" ] && grep -qE '^feat(\(|:)' "$title" && feature=$((feature + 1))
done

check_count() {
  local label="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then
    pass_msg "$label: $got (want $want)"
  else
    fail_msg "$label: $got (want $want)"
  fi
}
check_count "docs-only issues" "$docs_only" 1
check_count "quick-fix issues" "$quick_fix" 1
check_count "feat-titled issues" "$feature" 1
check_count "race+auth issues" "$race_auth" 1
check_count "lib/+docs/ multi-dir issues" "$lib_and_docs" 1

# ---------------------------------------------------------------------------
echo "== template suite is green, every reference test is red =="
# ---------------------------------------------------------------------------

if [ -d "$TEMPLATE_DIR" ]; then
  cp -a "$TEMPLATE_DIR" "$TMP/baseline"
  out=$( (cd "$TMP/baseline" && bash tests/run.sh) 2>&1 )
  if [ $? -eq 0 ]; then
    pass_msg "pristine template test suite passes"
  else
    fail_msg "pristine template test suite fails: $(echo "$out" | tail -3 | tr '\n' ' ')"
  fi
else
  fail_msg "template directory does not exist"
fi

for d in "${slate_dirs[@]}"; do
  name=$(basename "$d")
  [ -x "$d/reference-test.sh" ] || continue
  rm -rf "$TMP/sbx"
  cp -a "$TEMPLATE_DIR" "$TMP/sbx"
  out=$( (cd "$TMP/sbx" && bash "$d/reference-test.sh") 2>&1 )
  rc=$?
  if [ "$rc" -ne 0 ]; then
    pass_msg "$name reference test fails against the untouched template (rc=$rc)"
  else
    fail_msg "$name reference test PASSES against the untouched template (should fail)"
  fi
done

# ---------------------------------------------------------------------------
echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
