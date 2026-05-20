#!/bin/bash
# tests/test-check-container-assets.sh — tests for scripts/check-container-assets.sh.
#
# Each scenario builds a fixture project root, cds into it, invokes the helper,
# and asserts the per-asset diagnostic lines + the trailing status= line + exit
# code. Mirrors the fresh_fx pattern from tests/test-doctor-preservation-refs.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/check-container-assets.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ---------------------------------------------------------------------------
# Fixture builder. Materialises an empty project root at $TMP/<name>/proj.
# Scenarios layer on additional files (pipeline.config, compose.*.yml,
# .claude/hooks/*.py) and then call run_helper.
# ---------------------------------------------------------------------------
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj"
  echo "$root"
}

run_helper() {
  local root="$1"; shift
  (
    cd "$root/proj"
    bash "$HELPER" "$@" 2>&1
    echo "__EXIT__=$?"
  )
}

# Extract exit code from run_helper output (last line, __EXIT__=N format).
extract_rc() {
  printf '%s\n' "$1" | awk -F= '/^__EXIT__=/{print $2; exit}'
}

# Strip the __EXIT__ tail line so callers can grep the rest cleanly.
strip_rc() {
  printf '%s\n' "$1" | sed -E '/^__EXIT__=[0-9]+$/d'
}

# ---------------------------------------------------------------------------
# Case 0: helper exists and is executable.
# ---------------------------------------------------------------------------
echo "Case 0: helper exists"
if [ -f "$HELPER" ]; then
  pass_msg "scripts/check-container-assets.sh exists"
else
  fail_msg "scripts/check-container-assets.sh missing at $HELPER"
fi

# ---------------------------------------------------------------------------
# Case 1: fx-declared — declared mode (PIPELINE_EVAL_CONTAINERS="web-eval"),
# full triangle present, exit 0, status=pass.
# ---------------------------------------------------------------------------
echo "Case 1: fx-declared — declared mode → PASS"
ROOT=$(fresh_fx fx-declared)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_EVAL_CONTAINERS="web-eval"
CFG
cat > "$ROOT/proj/compose.web-eval.yml" <<'YAML'
services:
  claude-web-eval:
    image: claude-pipeline-web-eval
    environment:
      BOMON_WEB_EVAL: "1"
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-web-eval-evidence.py" <<'PY'
import os
if os.environ.get('BOMON_WEB_EVAL'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "0" ]; then
  pass_msg "exit 0"
else
  fail_msg "expected exit 0, got $rc"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE '^status=pass'; then
  pass_msg "status=pass on stdout"
else
  fail_msg "no status=pass line"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'compose\.web-eval\.yml .* PASS \(declared'; then
  pass_msg "declared-mode PASS asset line emitted"
else
  fail_msg "no PASS asset line for declared mode"
  echo "$body" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 2: fx-undeclared-no-reader — undeclared, compose sets FOO_MARKER, no
# .claude/hooks/ directory at all. Expectation: WARN, exit 2.
# ---------------------------------------------------------------------------
echo "Case 2: fx-undeclared-no-reader — undeclared, no reader → WARN"
ROOT=$(fresh_fx fx-undeclared-no-reader)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_EVAL_CONTAINERS=""
CFG
cat > "$ROOT/proj/compose.foo.yml" <<'YAML'
services:
  foo-svc:
    environment:
      FOO_MARKER: "1"
YAML
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "2" ]; then
  pass_msg "exit 2"
else
  fail_msg "expected exit 2, got $rc"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE '^status=warn'; then
  pass_msg "status=warn"
else
  fail_msg "no status=warn"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'compose\.foo\.yml .* WARN .*no marker-reader'; then
  pass_msg "WARN asset line names 'no marker-reader'"
else
  fail_msg "no WARN asset line"
  echo "$body" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 3: fx-undeclared-triangle — the worked example from the issue.
# Undeclared compose.web-eval.yml + sibling Dockerfile.web-eval + .env.web-eval
# + .claude/hooks/enforce-web-eval-evidence.py reading BOMON_WEB_EVAL. Full
# triangle → FAIL + emitted snippet with PIPELINE_EVAL_CONTAINER_WEB_EVAL_*.
# ---------------------------------------------------------------------------
echo "Case 3: fx-undeclared-triangle — full triangle → FAIL + snippet"
ROOT=$(fresh_fx fx-undeclared-triangle)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
cat > "$ROOT/proj/compose.web-eval.yml" <<'YAML'
services:
  claude-web-eval:
    image: claude-pipeline-web-eval
    environment:
      BOMON_WEB_EVAL: "1"
YAML
: > "$ROOT/proj/Dockerfile.web-eval"
: > "$ROOT/proj/.env.web-eval"
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-web-eval-evidence.py" <<'PY'
import os
if os.environ.get('BOMON_WEB_EVAL'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "1" ]; then
  pass_msg "exit 1"
else
  fail_msg "expected exit 1, got $rc"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE '^status=fail'; then
  pass_msg "status=fail"
else
  fail_msg "no status=fail"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'compose\.web-eval\.yml .* FAIL'; then
  pass_msg "FAIL asset line emitted"
else
  fail_msg "no FAIL asset line"
fi
if echo "$body" | grep -qE 'Marker env var set by compose: BOMON_WEB_EVAL'; then
  pass_msg "marker name surfaced"
else
  fail_msg "missing 'Marker env var set by compose: BOMON_WEB_EVAL'"
fi
if echo "$body" | grep -qE 'Marker reader: .*enforce-web-eval-evidence\.py'; then
  pass_msg "marker reader surfaced"
else
  fail_msg "missing 'Marker reader: ...enforce-web-eval-evidence.py'"
fi
if echo "$body" | grep -qE 'Service: .*claude-web-eval'; then
  pass_msg "service name surfaced"
else
  fail_msg "missing 'Service: claude-web-eval'"
fi
if echo "$body" | grep -qE 'PIPELINE_EVAL_CONTAINERS="web-eval"'; then
  pass_msg "PIPELINE_EVAL_CONTAINERS suggestion emitted"
else
  fail_msg "missing PIPELINE_EVAL_CONTAINERS suggestion"
fi
if echo "$body" | grep -qE 'PIPELINE_EVAL_CONTAINER_WEB_EVAL_COMPOSE_FILE="compose\.web-eval\.yml"'; then
  pass_msg "_COMPOSE_FILE suggestion emitted with dash→underscore mode suffix"
else
  fail_msg "missing PIPELINE_EVAL_CONTAINER_WEB_EVAL_COMPOSE_FILE"
fi
if echo "$body" | grep -qE 'PIPELINE_EVAL_CONTAINER_WEB_EVAL_SERVICE='; then
  pass_msg "_SERVICE suggestion emitted"
else
  fail_msg "missing PIPELINE_EVAL_CONTAINER_WEB_EVAL_SERVICE"
fi
if echo "$body" | grep -qE 'PIPELINE_EVAL_CONTAINER_WEB_EVAL_ENV_FILE="\.env\.web-eval"'; then
  pass_msg "_ENV_FILE suggestion emitted"
else
  fail_msg "missing PIPELINE_EVAL_CONTAINER_WEB_EVAL_ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Case 4a: fx-optout — `# pipeline:manual-only` on line 1 → PASS
# (overrides what would otherwise be a full-triangle FAIL).
# ---------------------------------------------------------------------------
echo "Case 4a: fx-optout — opt-out comment line 1 → PASS"
ROOT=$(fresh_fx fx-optout)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
cat > "$ROOT/proj/compose.web-eval.yml" <<'YAML'
# pipeline:manual-only
services:
  claude-web-eval:
    environment:
      BOMON_WEB_EVAL: "1"
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-web-eval-evidence.py" <<'PY'
import os
if os.environ.get('BOMON_WEB_EVAL'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "0" ]; then
  pass_msg "opt-out line 1: exit 0"
else
  fail_msg "opt-out line 1: expected exit 0, got $rc"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'PASS \(explicit opt-out: # pipeline:manual-only\)'; then
  pass_msg "opt-out PASS asset line emitted"
else
  fail_msg "no opt-out PASS asset line"
  echo "$body" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 4b: opt-out comment on line 6 → still FAIL (head-5 scan window).
# ---------------------------------------------------------------------------
echo "Case 4b: fx-optout-line6 — opt-out on line 6 → FAIL"
ROOT=$(fresh_fx fx-optout-line6)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
# Lines 1–5 are unrelated content; line 6 has the opt-out marker.
cat > "$ROOT/proj/compose.web-eval.yml" <<'YAML'
# line1
# line2
# line3
# line4
# line5
# pipeline:manual-only
services:
  claude-web-eval:
    environment:
      BOMON_WEB_EVAL: "1"
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-web-eval-evidence.py" <<'PY'
import os
if os.environ.get('BOMON_WEB_EVAL'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "1" ]; then
  pass_msg "opt-out on line 6 ignored: exit 1"
else
  fail_msg "opt-out on line 6 wrongly honored (rc=$rc)"
  echo "$body" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 5: fx-marker-mismatch — compose sets FOO_MARKER, hook reads BAR_MARKER.
# No marker overlap → WARN (no triangle).
# ---------------------------------------------------------------------------
echo "Case 5: fx-marker-mismatch — marker names don't overlap → WARN"
ROOT=$(fresh_fx fx-marker-mismatch)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
cat > "$ROOT/proj/compose.foo.yml" <<'YAML'
services:
  foo-svc:
    environment:
      FOO_MARKER: "1"
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-bar.py" <<'PY'
import os
if os.environ.get('BAR_MARKER'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "2" ]; then
  pass_msg "marker-mismatch: exit 2"
else
  fail_msg "marker-mismatch: expected exit 2, got $rc"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'compose\.foo\.yml .* WARN'; then
  pass_msg "marker-mismatch: WARN asset line emitted"
else
  fail_msg "marker-mismatch: no WARN asset line"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'Marker reader:'; then
  fail_msg "marker-mismatch: must NOT emit 'Marker reader:' (no overlap)"
else
  pass_msg "marker-mismatch: no 'Marker reader:' line"
fi

# ---------------------------------------------------------------------------
# Case 6: fx-yaml-unparseable — environment block in a YAML shape neither
# yq (when present) nor the awk fallback can parse. Plus a hook that reads
# SOME marker. The helper must NOT escalate to FAIL — stays at WARN with
# 'yaml-parse-skipped' annotation.
# ---------------------------------------------------------------------------
echo "Case 6: fx-yaml-unparseable — unparseable env block + reader → WARN"
ROOT=$(fresh_fx fx-yaml-unparseable)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
# A YAML structure where 'environment:' refers to an anchor → flat awk
# fallback cannot resolve the keys (no inline key list under environment:).
cat > "$ROOT/proj/compose.weird.yml" <<'YAML'
x-env: &shared-env
  COMMON_MARKER: "1"
services:
  weird-svc:
    environment: *shared-env
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-something.py" <<'PY'
import os
if os.environ.get('SOMETHING'):
    pass
PY
# Stub yq with a no-op (prints nothing, exits 0) so the helper is forced
# through the awk fallback. Without this the test would be non-deterministic:
# yq v4 can resolve the anchor and extract COMMON_MARKER, which would change
# the verdict from yaml-parse-skipped to plain WARN.
STUB_BIN="$ROOT/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/yq" <<'STUB'
#!/bin/bash
# Stub yq → return nothing, exit 0. Forces awk fallback in the helper.
exit 0
STUB
chmod +x "$STUB_BIN/yq"
out=$(
  cd "$ROOT/proj"
  PATH="$STUB_BIN:$PATH" bash "$HELPER" 2>&1
  echo "__EXIT__=$?"
)
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" = "2" ]; then
  pass_msg "yaml-unparseable: exit 2"
else
  fail_msg "yaml-unparseable: expected exit 2, got $rc (must NOT escalate to FAIL)"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE '^status=warn'; then
  pass_msg "yaml-unparseable: status=warn"
else
  fail_msg "yaml-unparseable: no status=warn"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE 'yaml-parse-skipped'; then
  pass_msg "yaml-unparseable: 'yaml-parse-skipped' annotation present"
else
  fail_msg "yaml-unparseable: missing 'yaml-parse-skipped' annotation"
  echo "$body" | sed 's/^/    /'
fi
if echo "$body" | grep -qE '^status=fail'; then
  fail_msg "yaml-unparseable: helper MUST NOT escalate to FAIL"
else
  pass_msg "yaml-unparseable: no false-FAIL"
fi

# ---------------------------------------------------------------------------
# Case 7: PIPELINE_* env vars in compose are filtered (not treated as
# consumer-intent markers). compose sets PIPELINE_FOO; hook reads PIPELINE_FOO.
# Must NOT FAIL just because both surfaces mention PIPELINE_FOO.
# ---------------------------------------------------------------------------
echo "Case 7: PIPELINE_* env-var filter"
ROOT=$(fresh_fx fx-pipeline-filter)
cat > "$ROOT/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
cat > "$ROOT/proj/compose.flt.yml" <<'YAML'
services:
  flt-svc:
    environment:
      PIPELINE_FOO: "1"
YAML
mkdir -p "$ROOT/proj/.claude/hooks"
cat > "$ROOT/proj/.claude/hooks/enforce-pipeline.py" <<'PY'
import os
if os.environ.get('PIPELINE_FOO'):
    pass
PY
out=$(run_helper "$ROOT")
rc=$(extract_rc "$out")
body=$(strip_rc "$out")
if [ "$rc" != "1" ]; then
  pass_msg "PIPELINE_* filter: exit != 1 (got $rc)"
else
  fail_msg "PIPELINE_* filter: must not FAIL on PIPELINE_* overlap"
  echo "$body" | sed 's/^/    /'
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
