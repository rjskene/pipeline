#!/bin/bash
set -uo pipefail

# #1215 — scripts/doctor.sh must emit a `project_root` check so that the
# orchestrator-checkout resolution (`${PIPELINE_PROJECT_ROOT:-$(pwd)}`) is a
# DELIBERATE operator choice rather than a silent convention.
#
# Three verdicts:
#   warn — PIPELINE_PROJECT_ROOT unset; read sites fall back to $(pwd).
#   pass — set, and the target holds BOTH pipeline.config and a .git entry
#          (the same validity predicate scripts/prune-checkpoints.sh and
#          scripts/review-logs.sh already use).
#   fail — set, but the target is not a valid project checkout.
#
# Shape mirrors tests/test-doctor-script.sh: a temp fixture project dir, a
# PATH-resident `gh` shim, and `bash scripts/doctor.sh` run with cwd inside the
# fixture. doctor's own exit code is deliberately NOT asserted — unrelated
# checks legitimately fail inside a bare fixture; only the `CHECK: project_root`
# line is under test here.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
# Compact diagnostic: the check names doctor actually emitted, one per line.
emitted_checks() { grep -oE '^CHECK: [a-z_]+' <<<"$1" | sed 's/^/      /'; }

if [ ! -f "$HELPER" ]; then
  echo "ERROR: required file not found: $HELPER" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# gh shim — doctor.sh fail-fasts (and never reaches project_root) without one.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")   exit 0 ;;
  "label list")  printf '%s\n' "[]" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$TMP/bin/gh"
# `gh version` is answered by the catch-all arm above (empty stdout), which
# doctor.sh treats as "version unknown" and lets through.

# Build a fixture project dir: a real git checkout carrying a pipeline.config.
# Extra PIPELINE_* lines can be appended by the caller.
fresh_fx() {
  local name="$1"
  local fx="$TMP/$name"
  rm -rf "$fx"
  mkdir -p "$fx"
  (
    cd "$fx"
    git init -q
    git config user.email t@t
    git config user.name t
    git commit --allow-empty -q -m init
  ) >/dev/null 2>&1
  cat > "$fx/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
CFG
  echo "$fx"
}

# Run doctor.sh inside the fixture, capturing stdout+stderr into $fx/out.
run_helper() {
  local fx="$1"
  (
    cd "$fx"
    # Scrub inherited PIPELINE_* so the fixture's own pipeline.config is the
    # sole authority (the #425 leak guard, same as test-doctor-script.sh).
    unset $(compgen -v PIPELINE_ 2>/dev/null) 2>/dev/null || true
    PATH="$TMP/bin:$PATH" CLAUDE_PLUGIN_ROOT="$fx" bash "$HELPER"
  ) > "$fx/out" 2>&1
  echo "$?" > "$fx/rc"
}

# ---------------------------------------------------------------------------
# Case 1: PIPELINE_PROJECT_ROOT unset -> warn, detail names the $(pwd) fallback
# ---------------------------------------------------------------------------
echo "Case 1: PIPELINE_PROJECT_ROOT unset"
FX=$(fresh_fx fx-unset)
run_helper "$FX"
out="$(cat "$FX/out")"

grep -qE '^CHECK: project_root ' <<<"$out" \
  && pass_msg "unset: doctor emits a project_root check" \
  || { fail_msg "unset: no 'CHECK: project_root' line emitted at all"; emitted_checks "$out"; }

grep -qE '^CHECK: project_root status=warn' <<<"$out" \
  && pass_msg "unset: project_root status=warn" \
  || fail_msg "unset: project_root is not status=warn"

grep -qE '^CHECK: project_root status=warn .*PIPELINE_PROJECT_ROOT' <<<"$out" \
  && pass_msg "unset: warn detail names PIPELINE_PROJECT_ROOT" \
  || fail_msg "unset: warn detail does not name PIPELINE_PROJECT_ROOT"

grep -qE '^CHECK: project_root status=warn .*pwd' <<<"$out" \
  && pass_msg "unset: warn detail names the \$(pwd) fallback" \
  || fail_msg "unset: warn detail does not mention the \$(pwd) fallback"

grep -qE '^project_root[[:space:]]+warn$' <<<"$out" \
  && pass_msg "unset: project_root appears in the summary table as warn" \
  || fail_msg "unset: project_root missing from the summary table"

# ---------------------------------------------------------------------------
# Case 2: set to a valid checkout (pipeline.config + .git) -> pass
# ---------------------------------------------------------------------------
echo "Case 2: PIPELINE_PROJECT_ROOT set to a valid project root"
FX=$(fresh_fx fx-valid)
printf 'PIPELINE_PROJECT_ROOT="%s"\n' "$FX" >> "$FX/pipeline.config"
run_helper "$FX"
out="$(cat "$FX/out")"

grep -qE '^CHECK: project_root ' <<<"$out" \
  && pass_msg "valid: doctor emits a project_root check" \
  || { fail_msg "valid: no 'CHECK: project_root' line emitted at all"; emitted_checks "$out"; }

grep -qE '^CHECK: project_root status=pass' <<<"$out" \
  && pass_msg "valid: project_root status=pass" \
  || fail_msg "valid: project_root is not status=pass"

grep -qE "^CHECK: project_root status=pass .*$FX" <<<"$out" \
  && pass_msg "valid: pass detail echoes the configured root" \
  || fail_msg "valid: pass detail does not echo the configured root"

grep -qE '^project_root[[:space:]]+pass$' <<<"$out" \
  && pass_msg "valid: project_root appears in the summary table as pass" \
  || fail_msg "valid: project_root missing from the summary table"

# ---------------------------------------------------------------------------
# Case 3a: set to a non-existent path -> fail
# ---------------------------------------------------------------------------
echo "Case 3a: PIPELINE_PROJECT_ROOT set to a non-existent path"
FX=$(fresh_fx fx-missing)
BOGUS="$TMP/no-such-project-root"
printf 'PIPELINE_PROJECT_ROOT="%s"\n' "$BOGUS" >> "$FX/pipeline.config"
run_helper "$FX"
out="$(cat "$FX/out")"

grep -qE '^CHECK: project_root ' <<<"$out" \
  && pass_msg "missing: doctor emits a project_root check" \
  || { fail_msg "missing: no 'CHECK: project_root' line emitted at all"; emitted_checks "$out"; }

grep -qE '^CHECK: project_root status=fail' <<<"$out" \
  && pass_msg "missing: project_root status=fail" \
  || fail_msg "missing: project_root is not status=fail for a non-existent path"

grep -qE "^CHECK: project_root status=fail .*$BOGUS" <<<"$out" \
  && pass_msg "missing: fail detail echoes the offending path" \
  || fail_msg "missing: fail detail does not echo the offending path"

# ---------------------------------------------------------------------------
# Case 3b: set to an existing dir that is not a checkout -> fail
# ---------------------------------------------------------------------------
echo "Case 3b: PIPELINE_PROJECT_ROOT set to a non-checkout directory"
FX=$(fresh_fx fx-notcheckout)
NOTREPO="$TMP/not-a-checkout"
mkdir -p "$NOTREPO"
printf 'PIPELINE_PROJECT_ROOT="%s"\n' "$NOTREPO" >> "$FX/pipeline.config"
run_helper "$FX"
out="$(cat "$FX/out")"

grep -qE '^CHECK: project_root status=fail' <<<"$out" \
  && pass_msg "not-checkout: project_root status=fail" \
  || { fail_msg "not-checkout: project_root is not status=fail (no pipeline.config / .git there)"; emitted_checks "$out"; }

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
