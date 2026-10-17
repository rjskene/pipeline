#!/bin/bash
set -uo pipefail
#
# Tests for the calib-base re-anchor in scripts/calibration-run.sh (#1477).
#
# Calib 25 aborted because `--bootstrap` committed a template sync onto the
# sandbox main but tag_base() never moved an existing calib-base tag, so the
# next `--reset` restored the OLD seed and silently discarded the template fix.
#
# HERMETIC: the "remote" is a local bare repo injected via
# PIPELINE_CALIB_REMOTE, `gh` is a PATH stub, doctor.sh is a stub, and the
# sandbox lives in mktemp -d. Nothing touches the network, the real harness
# repo, or the real sandbox under ~/.claude/calib.
#

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/calibration-run.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
scenario() { echo ""; echo "-- $1 --"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME="calib test" GIT_AUTHOR_EMAIL="calib@example.invalid"
export GIT_COMMITTER_NAME="calib test" GIT_COMMITTER_EMAIL="calib@example.invalid"

# Synthetic harness: a template dir and a doctor.sh stub are all --bootstrap
# reads from it.
HARNESS="$TMP/harness"
TEMPLATE="$HARNESS/dev/calib/template"
mkdir -p "$HARNESS/scripts" "$TEMPLATE"
echo "# calib sandbox" > "$TEMPLATE/README.md"
# A stale inert line the template later drops (Calib 25's shape; a non-PIPELINE_
# key so check-config-drift.sh does not read it as an undeclared knob).
printf 'PIPELINE_REPO=owner/pipeline-calib\nSTALE_INERT_KNOB=false\n' > "$TEMPLATE/pipeline.config"
printf '{"permissions":{"allow":["Bash"]}}\n' > "$TEMPLATE/claude-settings.local.json"
printf '#!/bin/bash\necho "doctor stub: $*"\n' > "$HARNESS/scripts/doctor.sh"
chmod +x "$HARNESS/scripts/doctor.sh"

REMOTE="$TMP/remote/pipeline-calib.git"
mkdir -p "$TMP/remote"
git init --quiet --bare "$REMOTE"
SANDBOX="$TMP/calib/pipeline-calib"

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GH'
#!/bin/bash
case "$*" in
  "repo view --json"*) echo "rjskene/pipeline" ;;   # this checkout's own slug
  "repo view"*)        exit 0 ;;                    # sandbox repo exists
  *)                   exit 0 ;;
esac
GH
chmod +x "$STUB_BIN/gh"
printf '#!/bin/bash\necho "FATAL: launched claude" >&2\nexit 97\n' > "$STUB_BIN/claude"
chmod +x "$STUB_BIN/claude"

RC=0
OUT=""
run_helper() {
  OUT="$(PATH="$STUB_BIN:$PATH" \
        HOME="$TMP/home" \
        PIPELINE_REPO="${CALIB_TEST_PIPELINE_REPO:-rjskene/pipeline}" \
        PIPELINE_CALIB_REPO="owner/pipeline-calib" \
        PIPELINE_CALIB_DIR="$SANDBOX" \
        PIPELINE_CALIB_REMOTE="$REMOTE" \
        timeout 30 bash "$HELPER" "$@" 2>&1)"
  RC=$?
}

expect_rc() { # <label> <want>
  if [ "$RC" -eq "$2" ]; then pass_msg "$1"; else fail_msg "$1 (want rc=$2, got rc=$RC): $OUT"; fi
}
expect_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then pass_msg "$1"; else fail_msg "$1 (missing: $3)"; fi
}
refute_sub() { # <label> <text> <substring>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then fail_msg "$1 (unexpectedly present: $3)"; else pass_msg "$1"; fi
}
expect_eq() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then pass_msg "$1"; else fail_msg "$1 (got $2, want $3)"; fi
}

local_tag()    { git -C "$SANDBOX" rev-parse -q --verify 'refs/tags/calib-base^{commit}' 2>/dev/null; }
remote_tag()   { git -C "$REMOTE" rev-parse -q --verify 'refs/tags/calib-base^{commit}' 2>/dev/null; }
remote_main()  { git -C "$REMOTE" rev-parse -q --verify refs/heads/main 2>/dev/null; }
sandbox_head() { git -C "$SANDBOX" rev-parse HEAD; }

# ---------------------------------------------------------------------------
scenario "Scenario 1: --retag before --bootstrap fails cleanly"
# ---------------------------------------------------------------------------
run_helper --retag --harness "$HARNESS"
expect_rc "--retag on an un-bootstrapped sandbox exits 1" 1
expect_sub "--retag names the missing bootstrap" "$OUT" "run --bootstrap first"

# ---------------------------------------------------------------------------
scenario "Scenario 2: first --bootstrap anchors calib-base at the seed"
# ---------------------------------------------------------------------------
run_helper --bootstrap --harness "$HARNESS"
expect_rc "first --bootstrap exits 0" 0
H1="$(sandbox_head)"
expect_eq "calib-base anchored at the seed commit (local)" "$(local_tag)" "$H1"
expect_eq "calib-base anchored at the seed commit (remote)" "$(remote_tag)" "$H1"
refute_sub "a fresh anchor is not reported as a re-anchor" "$OUT" "re-anchored"

# ---------------------------------------------------------------------------
scenario "Scenario 3: template change -> --bootstrap re-anchors calib-base"
# ---------------------------------------------------------------------------
# The Calib 25 shape: the template drops the stale inert line.
printf 'PIPELINE_REPO=owner/pipeline-calib\n' > "$TEMPLATE/pipeline.config"
run_helper --bootstrap --harness "$HARNESS"
expect_rc "--bootstrap after a template change exits 0" 0
H2="$(sandbox_head)"
if [ "$H2" != "$H1" ]; then pass_msg "the template sync committed (HEAD moved)"; else fail_msg "the template sync did not commit"; fi
expect_eq "remote main carries the template sync" "$(remote_main)" "$H2"
expect_eq "local calib-base follows the new main" "$(local_tag)" "$H2"
expect_eq "remote calib-base follows the new main" "$(remote_tag)" "$H2"
expect_sub "the re-anchor is reported old -> new" "$OUT" "calib: calib-base re-anchored $H1 -> $H2"

# ---------------------------------------------------------------------------
scenario "Scenario 4: no template change -> calib-base unchanged"
# ---------------------------------------------------------------------------
run_helper --bootstrap --harness "$HARNESS"
expect_rc "idempotent --bootstrap exits 0" 0
expect_eq "idempotent --bootstrap creates no commit" "$(sandbox_head)" "$H2"
expect_eq "idempotent --bootstrap leaves the local tag alone" "$(local_tag)" "$H2"
expect_eq "idempotent --bootstrap leaves the remote tag alone" "$(remote_tag)" "$H2"
refute_sub "idempotent --bootstrap reports no re-anchor" "$OUT" "re-anchored"
TAGS="$(git -C "$SANDBOX" tag -l 'calib-base' | wc -l | tr -d ' ')"
expect_eq "calib-base is never duplicated" "$TAGS" "1"

# ---------------------------------------------------------------------------
scenario "Scenario 5: sandbox not at calib-base -> --bootstrap refuses to re-anchor"
# ---------------------------------------------------------------------------
# After a --run, the sandbox main carries the run's merged fixes. Re-anchoring
# onto that would bake the slate's answers into the seed — never do it.
echo "fixed" > "$SANDBOX/run-fix.txt"
git -C "$SANDBOX" add run-fix.txt
git -C "$SANDBOX" commit --quiet -m "fix: merged by a measured run"
git -C "$SANDBOX" push --quiet origin HEAD:refs/heads/main
echo "# calib sandbox v2" > "$TEMPLATE/README.md"
run_helper --bootstrap --harness "$HARNESS"
expect_rc "--bootstrap on a drifted sandbox still exits 0" 0
expect_eq "drifted --bootstrap leaves the local tag alone" "$(local_tag)" "$H2"
expect_eq "drifted --bootstrap leaves the remote tag alone" "$(remote_tag)" "$H2"
refute_sub "drifted --bootstrap reports no re-anchor" "$OUT" "re-anchored"
expect_sub "drifted --bootstrap warns that the tag was left behind" "$OUT" "calib-base left at $H2"

# ---------------------------------------------------------------------------
scenario "Scenario 6: --retag re-anchors to the sandbox HEAD explicitly"
# ---------------------------------------------------------------------------
H3="$(sandbox_head)"
run_helper --retag --harness "$HARNESS"
expect_rc "--retag exits 0" 0
expect_eq "--retag moves the local tag to HEAD" "$(local_tag)" "$H3"
expect_eq "--retag moves the remote tag to HEAD" "$(remote_tag)" "$H3"
expect_sub "--retag reports old -> new" "$OUT" "calib: calib-base re-anchored $H2 -> $H3"

run_helper --retag --harness "$HARNESS"
expect_rc "a second --retag exits 0" 0
expect_eq "a second --retag leaves the tag at HEAD" "$(remote_tag)" "$H3"
refute_sub "a second --retag is a no-op" "$OUT" "re-anchored"

# ---------------------------------------------------------------------------
scenario "Scenario 7: --retag arg handling + blast-radius guard"
# ---------------------------------------------------------------------------
run_helper --retag --bootstrap
expect_rc "--retag + --bootstrap is rejected" 2
expect_sub "the mutual-exclusion error is named" "$OUT" "mutually exclusive"
run_helper --help
expect_sub "--help documents --retag" "$OUT" "--retag"
CALIB_TEST_PIPELINE_REPO="owner/pipeline-calib" run_helper --retag --harness "$HARNESS"
expect_rc "--retag refuses when the sandbox is the harness repo" 1
expect_sub "the guard refusal is named" "$OUT" "refusing to"

# ---------------------------------------------------------------------------
echo ""
echo "================================"
echo "PASS: $PASS  FAIL: $FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
