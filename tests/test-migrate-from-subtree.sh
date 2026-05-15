#!/bin/bash
set -euo pipefail

# Tests for scripts/migrate-from-subtree.sh — the consumer-facing migration
# script that removes pipeline-managed files installed via the legacy subtree
# + install.sh path.
#
# Each test builds an isolated $PROJ fixture under a per-test mktemp dir,
# invokes the migration script from that dir, and asserts on filesystem
# state, stdout, and stderr.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE_SH="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"

PASS=0
FAIL=0
TESTS=0

pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

if [ ! -f "$MIGRATE_SH" ]; then
  echo "ERROR: migrate-from-subtree.sh not found at $MIGRATE_SH" >&2
  exit 1
fi
chmod +x "$MIGRATE_SH"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Test "absent": no .claude-pipeline/, no markers, no .claude/agents — script
# is a no-op. Snapshot fs state, run, snapshot again, require identical.
# ---------------------------------------------------------------------------
echo "Test 'absent': no-op when nothing pipeline-managed exists"

PROJ_ABSENT="$WORKDIR/proj-absent"
mkdir -p "$PROJ_ABSENT"
# Some user content so the dir isn't trivially empty
echo "hello" > "$PROJ_ABSENT/README.md"
mkdir -p "$PROJ_ABSENT/.claude"
echo '{"hooks": []}' > "$PROJ_ABSENT/.claude/settings.json"

BEFORE=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)
STDERR_LOG="$WORKDIR/absent.stderr"
STDOUT_LOG="$WORKDIR/absent.stdout"
(cd "$PROJ_ABSENT" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?
AFTER=$(cd "$PROJ_ABSENT" && find . -type f -o -type d | sort)

inc
if [ "$EXIT" -eq 0 ]; then
  pass_msg "absent: exit 0"
else
  fail_msg "absent: exit $EXIT"
fi

inc
if [ "$BEFORE" = "$AFTER" ]; then
  pass_msg "absent: filesystem unchanged"
else
  fail_msg "absent: filesystem changed"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
fi

inc
if grep -qi 'nothing to migrate' "$STDERR_LOG"; then
  pass_msg "absent: stderr mentions 'nothing to migrate'"
else
  fail_msg "absent: stderr missing 'nothing to migrate'"
  echo "    stderr:"
  sed 's/^/      /' "$STDERR_LOG"
fi

# ---------------------------------------------------------------------------
# Test "clean": every pipeline-managed surface present — script removes the
# managed files end-to-end, leaves user-authored siblings untouched, prints
# the post-migration instructions.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'clean': end-to-end removal of pipeline-managed surfaces"

PROJ_CLEAN="$WORKDIR/proj-clean"
mkdir -p "$PROJ_CLEAN/.claude-pipeline/scripts" "$PROJ_CLEAN/.claude-pipeline/hooks"
touch "$PROJ_CLEAN/.claude-pipeline/install.sh"
touch "$PROJ_CLEAN/.claude-pipeline/pipeline.config.example"

# Pipeline manifest under .claude-pipeline/ — names the migration script
# enumerates to identify managed scripts/hooks.
touch "$PROJ_CLEAN/.claude-pipeline/scripts/spawn-claude.sh.template"
touch "$PROJ_CLEAN/.claude-pipeline/hooks/log-tool-use.sh"

# Installed surfaces
mkdir -p "$PROJ_CLEAN/.claude/skills/run" \
         "$PROJ_CLEAN/.claude/skills/userwritten" \
         "$PROJ_CLEAN/.claude/agents" \
         "$PROJ_CLEAN/.claude/scripts" \
         "$PROJ_CLEAN/.claude/hooks"

# Skills: one managed (marker), one user-authored
echo "managed skill" > "$PROJ_CLEAN/.claude/skills/run/SKILL.md"
touch "$PROJ_CLEAN/.claude/skills/run/.pipeline-managed"
echo "user skill" > "$PROJ_CLEAN/.claude/skills/userwritten/SKILL.md"

# Agents: one managed (per-file marker), one user-authored
echo "managed agent" > "$PROJ_CLEAN/.claude/agents/tdd-implementer.md"
touch "$PROJ_CLEAN/.claude/agents/.tdd-implementer.pipeline-managed"
echo "user agent" > "$PROJ_CLEAN/.claude/agents/handwritten.md"

# Scripts: one matches pipeline manifest (managed), one does not (user)
echo "managed" > "$PROJ_CLEAN/.claude/scripts/spawn-claude.sh"
echo "user" > "$PROJ_CLEAN/.claude/scripts/custom.sh"

# Hooks: one matches manifest, one does not
echo "managed" > "$PROJ_CLEAN/.claude/hooks/log-tool-use.sh"
echo "user" > "$PROJ_CLEAN/.claude/hooks/custom-hook.sh"

STDERR_LOG="$WORKDIR/clean.stderr"
STDOUT_LOG="$WORKDIR/clean.stdout"
(cd "$PROJ_CLEAN" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "clean: exit 0"; else fail_msg "clean: exit $EXIT"; fi

inc
if [ ! -d "$PROJ_CLEAN/.claude-pipeline" ]; then
  pass_msg "clean: .claude-pipeline/ removed"
else
  fail_msg "clean: .claude-pipeline/ still present"
fi

inc
if [ ! -d "$PROJ_CLEAN/.claude/skills/run" ]; then
  pass_msg "clean: managed skill dir removed"
else
  fail_msg "clean: managed skill dir still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/skills/userwritten/SKILL.md" ]; then
  pass_msg "clean: user-authored skill preserved"
else
  fail_msg "clean: user-authored skill was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/agents/tdd-implementer.md" ] && \
   [ ! -f "$PROJ_CLEAN/.claude/agents/.tdd-implementer.pipeline-managed" ]; then
  pass_msg "clean: managed agent + marker removed"
else
  fail_msg "clean: managed agent or marker still present"
  ls -la "$PROJ_CLEAN/.claude/agents/" | sed 's/^/    /'
fi

inc
if [ -f "$PROJ_CLEAN/.claude/agents/handwritten.md" ]; then
  pass_msg "clean: user-authored agent preserved"
else
  fail_msg "clean: user-authored agent was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/scripts/spawn-claude.sh" ]; then
  pass_msg "clean: managed script removed"
else
  fail_msg "clean: managed script still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/scripts/custom.sh" ]; then
  pass_msg "clean: user-authored script preserved"
else
  fail_msg "clean: user-authored script was deleted"
fi

inc
if [ ! -f "$PROJ_CLEAN/.claude/hooks/log-tool-use.sh" ]; then
  pass_msg "clean: managed hook removed"
else
  fail_msg "clean: managed hook still present"
fi

inc
if [ -f "$PROJ_CLEAN/.claude/hooks/custom-hook.sh" ]; then
  pass_msg "clean: user-authored hook preserved"
else
  fail_msg "clean: user-authored hook was deleted"
fi

inc
if grep -qF 'Install the plugin: claude plugin install hts-collab-org/claude-pipeline' "$STDOUT_LOG"; then
  pass_msg "clean: install instructions printed to stdout"
else
  fail_msg "clean: install instructions missing from stdout"
  echo "    stdout:"
  sed 's/^/      /' "$STDOUT_LOG"
fi

# ---------------------------------------------------------------------------
# Test "partial": marker present but no .claude-pipeline/. Migration should
# still remove the marker + its agent and exit 0.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'partial': managed marker without .claude-pipeline/"

PROJ_PARTIAL="$WORKDIR/proj-partial"
mkdir -p "$PROJ_PARTIAL/.claude/agents"
echo "managed agent" > "$PROJ_PARTIAL/.claude/agents/tdd-implementer.md"
touch "$PROJ_PARTIAL/.claude/agents/.tdd-implementer.pipeline-managed"

STDERR_LOG="$WORKDIR/partial.stderr"
STDOUT_LOG="$WORKDIR/partial.stdout"
(cd "$PROJ_PARTIAL" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "partial: exit 0"; else fail_msg "partial: exit $EXIT"; fi

inc
if [ ! -f "$PROJ_PARTIAL/.claude/agents/tdd-implementer.md" ] && \
   [ ! -f "$PROJ_PARTIAL/.claude/agents/.tdd-implementer.pipeline-managed" ]; then
  pass_msg "partial: managed agent + marker removed"
else
  fail_msg "partial: managed agent or marker still present"
  ls -la "$PROJ_PARTIAL/.claude/agents/" | sed 's/^/    /'
fi

inc
if grep -qF 'Install the plugin: claude plugin install hts-collab-org/claude-pipeline' "$STDOUT_LOG"; then
  pass_msg "partial: install instructions printed"
else
  fail_msg "partial: install instructions missing"
fi

# ---------------------------------------------------------------------------
# Test "idempotent": after the "clean" run, re-running on the same $PROJ is
# a no-op (exit 0, stderr 'nothing to migrate', filesystem identical).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'idempotent': second run on already-migrated project is a no-op"

BEFORE=$(cd "$PROJ_CLEAN" && find . -type f -o -type d | sort)
STDERR_LOG="$WORKDIR/idem.stderr"
STDOUT_LOG="$WORKDIR/idem.stdout"
(cd "$PROJ_CLEAN" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?
AFTER=$(cd "$PROJ_CLEAN" && find . -type f -o -type d | sort)

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "idempotent: exit 0"; else fail_msg "idempotent: exit $EXIT"; fi

inc
if [ "$BEFORE" = "$AFTER" ]; then
  pass_msg "idempotent: filesystem unchanged on second run"
else
  fail_msg "idempotent: filesystem changed on second run"
  diff <(echo "$BEFORE") <(echo "$AFTER") | sed 's/^/    /'
fi

inc
if grep -qi 'nothing to migrate' "$STDERR_LOG"; then
  pass_msg "idempotent: stderr mentions 'nothing to migrate'"
else
  fail_msg "idempotent: stderr missing 'nothing to migrate'"
  sed 's/^/      /' "$STDERR_LOG"
fi

# ---------------------------------------------------------------------------
# Test "settings injection": settings.json references pipeline hook basenames
# → report file written, settings.json untouched, stdout warning printed.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings injection': pipeline hook refs in settings.json reported"

PROJ_INJ="$WORKDIR/proj-inj"
mkdir -p "$PROJ_INJ/.claude-pipeline/hooks" "$PROJ_INJ/.claude"
touch "$PROJ_INJ/.claude-pipeline/hooks/log-tool-use.sh"
touch "$PROJ_INJ/.claude-pipeline/hooks/enforce-base-branch.sh"
cat > "$PROJ_INJ/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/enforce-base-branch.sh"}]}
    ]
  }
}
EOF

SETTINGS_SHA_BEFORE=$(sha256sum "$PROJ_INJ/.claude/settings.json" | awk '{print $1}')

STDERR_LOG="$WORKDIR/inj.stderr"
STDOUT_LOG="$WORKDIR/inj.stdout"
(cd "$PROJ_INJ" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

SETTINGS_SHA_AFTER=$(sha256sum "$PROJ_INJ/.claude/settings.json" | awk '{print $1}')

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "inj: exit 0"; else fail_msg "inj: exit $EXIT"; fi

inc
if [ "$SETTINGS_SHA_BEFORE" = "$SETTINGS_SHA_AFTER" ]; then
  pass_msg "inj: settings.json byte-identical"
else
  fail_msg "inj: settings.json was modified"
fi

REPORT="$PROJ_INJ/.claude/settings.json.pipeline-migration-report.txt"
inc
if [ -f "$REPORT" ]; then
  pass_msg "inj: report file created"
else
  fail_msg "inj: report file missing"
fi

inc
if [ -f "$REPORT" ] && grep -qF 'log-tool-use.sh' "$REPORT" && grep -qF 'enforce-base-branch.sh' "$REPORT"; then
  pass_msg "inj: report mentions both hook basenames"
else
  fail_msg "inj: report missing one or both hook basenames"
  [ -f "$REPORT" ] && sed 's/^/      /' "$REPORT"
fi

inc
if [ -f "$REPORT" ] && grep -qF 'Review and remove these entries manually.' "$REPORT"; then
  pass_msg "inj: report includes advisory line"
else
  fail_msg "inj: report missing advisory line"
fi

inc
if grep -qF 'Pipeline-injected entries detected in settings.json — see report.' "$STDOUT_LOG"; then
  pass_msg "inj: stdout warning printed"
else
  fail_msg "inj: stdout warning missing"
  sed 's/^/      /' "$STDOUT_LOG"
fi

# ---------------------------------------------------------------------------
# Test "settings clean": settings.json has no pipeline hook refs → no report,
# no warning. Mutation phase still runs (because .claude-pipeline/ exists).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings clean': benign settings.json produces no report"

PROJ_CLEAN_S="$WORKDIR/proj-clean-s"
mkdir -p "$PROJ_CLEAN_S/.claude-pipeline/hooks" "$PROJ_CLEAN_S/.claude"
touch "$PROJ_CLEAN_S/.claude-pipeline/hooks/log-tool-use.sh"
echo '{"hooks": []}' > "$PROJ_CLEAN_S/.claude/settings.json"

STDERR_LOG="$WORKDIR/clean-s.stderr"
STDOUT_LOG="$WORKDIR/clean-s.stdout"
(cd "$PROJ_CLEAN_S" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "clean-s: exit 0"; else fail_msg "clean-s: exit $EXIT"; fi

inc
if [ ! -f "$PROJ_CLEAN_S/.claude/settings.json.pipeline-migration-report.txt" ]; then
  pass_msg "clean-s: no report file created"
else
  fail_msg "clean-s: spurious report file created"
fi

inc
if ! grep -qF 'Pipeline-injected entries detected in settings.json' "$STDOUT_LOG"; then
  pass_msg "clean-s: no spurious warning in stdout"
else
  fail_msg "clean-s: warning incorrectly emitted"
fi

# ---------------------------------------------------------------------------
# Test "settings injection w/o manifest": consumer manually removed
# .claude-pipeline/ but still has .claude/hooks/* references in settings.json.
# Path-fragment matching (".claude/hooks/") must still flag these so the user
# gets the advisory report.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings injection no-manifest': path-fragment detection without .claude-pipeline/"

PROJ_NOMAN="$WORKDIR/proj-noman"
mkdir -p "$PROJ_NOMAN/.claude"
cat > "$PROJ_NOMAN/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ]
  }
}
EOF

STDERR_LOG="$WORKDIR/noman.stderr"
STDOUT_LOG="$WORKDIR/noman.stdout"
(cd "$PROJ_NOMAN" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG") || true

REPORT="$PROJ_NOMAN/.claude/settings.json.pipeline-migration-report.txt"
inc
if [ -f "$REPORT" ]; then
  pass_msg "noman: report file created via path-fragment detection"
else
  fail_msg "noman: no report despite .claude/hooks/ reference in settings.json"
fi

inc
if grep -qF 'Pipeline-injected entries detected in settings.json — see report.' "$STDOUT_LOG"; then
  pass_msg "noman: stdout warning printed"
else
  fail_msg "noman: stdout warning missing"
fi

# ---------------------------------------------------------------------------
# Test "claudemd integration": migrate-from-subtree.sh invokes the CLAUDE.md
# scanner and the resulting advisory report appears.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'claudemd integration': scanner is invoked from migrate-from-subtree.sh"

PROJ_INTG="$WORKDIR/proj-intg"
mkdir -p "$PROJ_INTG/.claude-pipeline/hooks"
touch "$PROJ_INTG/.claude-pipeline/install.sh"
touch "$PROJ_INTG/.claude-pipeline/hooks/log-tool-use.sh"
printf 'Run `bash .claude-pipeline/install.sh` to begin.\n' > "$PROJ_INTG/CLAUDE.md"

STDERR_LOG="$WORKDIR/intg.stderr"
STDOUT_LOG="$WORKDIR/intg.stdout"
(cd "$PROJ_INTG" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
EXIT=$?

inc
if [ "$EXIT" -eq 0 ]; then pass_msg "intg: exit 0"; else fail_msg "intg: exit $EXIT"; fi

REPORT_INTG="$PROJ_INTG/.claude/migration-cleanup-report-claudemd.txt"
inc
if [ -f "$REPORT_INTG" ]; then
  pass_msg "intg: claudemd report exists"
else
  fail_msg "intg: claudemd report missing"
fi

inc
if [ -f "$REPORT_INTG" ] && grep -qF 'CLAUDE.md:' "$REPORT_INTG" \
   && grep -qF 'install.sh' "$REPORT_INTG"; then
  pass_msg "intg: report mentions CLAUDE.md path and install.sh"
else
  fail_msg "intg: report missing expected content"
  [ -f "$REPORT_INTG" ] && sed 's/^/    /' "$REPORT_INTG"
fi

# ---------------------------------------------------------------------------
# Test "settings patch: pipeline-only" — settings.json carries only pipeline
# hook entries. Script must emit .claude/migration-cleanup-settings.patch
# alongside the report. Patch must apply cleanly via `git apply` and yield
# valid JSON (empty hooks block) or remove the file entirely (with loud
# warning in the report). Source settings.json must remain byte-identical.
# Patch must be byte-stable across re-runs (idempotency).
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings patch: pipeline-only settings.json'"

PROJ_PATCH_PO="$WORKDIR/proj-patch-po"
mkdir -p "$PROJ_PATCH_PO/.claude-pipeline/hooks" "$PROJ_PATCH_PO/.claude"
touch "$PROJ_PATCH_PO/.claude-pipeline/hooks/log-tool-use.sh"
touch "$PROJ_PATCH_PO/.claude-pipeline/hooks/enforce-base-branch.sh"
cat > "$PROJ_PATCH_PO/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ],
    "PreToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/enforce-base-branch.sh"}]}
    ]
  }
}
EOF
(cd "$PROJ_PATCH_PO" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)

PO_SETTINGS_SHA_BEFORE=$(sha256sum "$PROJ_PATCH_PO/.claude/settings.json" | awk '{print $1}')

STDERR_LOG="$WORKDIR/patch-po.stderr"
STDOUT_LOG="$WORKDIR/patch-po.stdout"
(cd "$PROJ_PATCH_PO" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG") || true

PATCH_PO="$PROJ_PATCH_PO/.claude/migration-cleanup-settings.patch"
REPORT_PO="$PROJ_PATCH_PO/.claude/settings.json.pipeline-migration-report.txt"

inc
if [ -f "$PATCH_PO" ]; then
  pass_msg "patch-po: patch file created"
else
  fail_msg "patch-po: patch file missing"
fi

inc
if [ -f "$PATCH_PO" ] && (cd "$PROJ_PATCH_PO" && git apply --check .claude/migration-cleanup-settings.patch) 2>/dev/null; then
  pass_msg "patch-po: git apply --check clean"
else
  fail_msg "patch-po: git apply --check failed"
fi

inc
PO_SETTINGS_SHA_AFTER=$(sha256sum "$PROJ_PATCH_PO/.claude/settings.json" 2>/dev/null | awk '{print $1}')
if [ "$PO_SETTINGS_SHA_BEFORE" = "$PO_SETTINGS_SHA_AFTER" ]; then
  pass_msg "patch-po: source settings.json byte-identical pre/post"
else
  fail_msg "patch-po: source settings.json was modified"
fi

inc
if [ -f "$PATCH_PO" ]; then
  PO_COPY="$WORKDIR/po-copy"
  cp -r "$PROJ_PATCH_PO" "$PO_COPY"
  if (cd "$PO_COPY" && git apply .claude/migration-cleanup-settings.patch) 2>/dev/null; then
    if [ ! -f "$PO_COPY/.claude/settings.json" ]; then
      if grep -qF '+++ /dev/null' "$PATCH_PO" && grep -qiF 'functionally empty' "$REPORT_PO"; then
        pass_msg "patch-po: deletion-form patch + loud warning"
      else
        fail_msg "patch-po: file removed but missing /dev/null marker or warning"
      fi
    elif jq -e '(.hooks // {}) | to_entries | all(.value | length == 0)' "$PO_COPY/.claude/settings.json" >/dev/null 2>&1; then
      pass_msg "patch-po: post-patch JSON valid with empty hooks"
    else
      fail_msg "patch-po: post-patch JSON invalid or hooks not empty"
    fi
  else
    fail_msg "patch-po: post-patch apply failed in copy"
  fi
else
  fail_msg "patch-po: cannot validate post-patch state (no patch)"
fi

inc
if [ -f "$REPORT_PO" ] && grep -qF 'migration-cleanup-settings.patch' "$REPORT_PO"; then
  pass_msg "patch-po: report references the patch file"
else
  fail_msg "patch-po: report missing patch reference"
fi

inc
if [ -f "$PATCH_PO" ]; then
  PO_PATCH_SHA_1=$(sha256sum "$PATCH_PO" | awk '{print $1}')
  (cd "$PROJ_PATCH_PO" && bash "$MIGRATE_SH" >/dev/null 2>&1) || true
  PO_PATCH_SHA_2=$(sha256sum "$PATCH_PO" 2>/dev/null | awk '{print $1}')
  if [ "$PO_PATCH_SHA_1" = "$PO_PATCH_SHA_2" ]; then
    pass_msg "patch-po: patch byte-stable across re-runs"
  else
    fail_msg "patch-po: patch differs across re-runs"
  fi
else
  fail_msg "patch-po: cannot test idempotency (no patch)"
fi

# ---------------------------------------------------------------------------
# Test "settings patch: mixed" — settings.json mixes pipeline + consumer hooks
# plus a top-level env block. Patch must preserve consumer entries and the
# env block; only the pipeline hook reference is removed.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings patch: mixed pipeline + consumer hooks preserved'"

PROJ_PATCH_MX="$WORKDIR/proj-patch-mx"
mkdir -p "$PROJ_PATCH_MX/.claude-pipeline/hooks" "$PROJ_PATCH_MX/.claude"
touch "$PROJ_PATCH_MX/.claude-pipeline/hooks/log-tool-use.sh"
cat > "$PROJ_PATCH_MX/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]},
      {"hooks": [{"type": "command", "command": ".claude/hooks/my-custom-hook.sh"}]}
    ]
  },
  "env": {"MY_VAR": "foo"}
}
EOF
(cd "$PROJ_PATCH_MX" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)

MX_SHA_BEFORE=$(sha256sum "$PROJ_PATCH_MX/.claude/settings.json" | awk '{print $1}')
STDERR_LOG="$WORKDIR/patch-mx.stderr"
STDOUT_LOG="$WORKDIR/patch-mx.stdout"
(cd "$PROJ_PATCH_MX" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG") || true

PATCH_MX="$PROJ_PATCH_MX/.claude/migration-cleanup-settings.patch"
REPORT_MX="$PROJ_PATCH_MX/.claude/settings.json.pipeline-migration-report.txt"

inc
if [ -f "$PATCH_MX" ]; then pass_msg "patch-mx: patch file created"; else fail_msg "patch-mx: patch file missing"; fi

inc
if [ -f "$PATCH_MX" ] && (cd "$PROJ_PATCH_MX" && git apply --check .claude/migration-cleanup-settings.patch) 2>/dev/null; then
  pass_msg "patch-mx: git apply --check clean"
else
  fail_msg "patch-mx: git apply --check failed"
fi

inc
MX_SHA_AFTER=$(sha256sum "$PROJ_PATCH_MX/.claude/settings.json" 2>/dev/null | awk '{print $1}')
if [ "$MX_SHA_BEFORE" = "$MX_SHA_AFTER" ]; then
  pass_msg "patch-mx: source settings.json byte-identical pre/post"
else
  fail_msg "patch-mx: source settings.json was modified"
fi

inc
if [ -f "$PATCH_MX" ]; then
  MX_COPY="$WORKDIR/mx-copy"
  cp -r "$PROJ_PATCH_MX" "$MX_COPY"
  if (cd "$MX_COPY" && git apply .claude/migration-cleanup-settings.patch) 2>/dev/null \
     && jq -e . "$MX_COPY/.claude/settings.json" >/dev/null 2>&1 \
     && jq -e '.env.MY_VAR == "foo"' "$MX_COPY/.claude/settings.json" >/dev/null \
     && jq -e '[..|.command? // empty] | any(. == ".claude/hooks/my-custom-hook.sh")' "$MX_COPY/.claude/settings.json" >/dev/null \
     && ! grep -qF 'log-tool-use.sh' "$MX_COPY/.claude/settings.json"; then
    pass_msg "patch-mx: post-patch JSON valid, consumer hook + env preserved, pipeline hook removed"
  else
    fail_msg "patch-mx: post-patch JSON did not match expected shape"
    [ -f "$MX_COPY/.claude/settings.json" ] && sed 's/^/      /' "$MX_COPY/.claude/settings.json"
  fi
else
  fail_msg "patch-mx: cannot validate post-patch (no patch)"
fi

inc
if [ -f "$REPORT_MX" ] && ! grep -qiF 'functionally empty' "$REPORT_MX"; then
  pass_msg "patch-mx: no spurious functionally-empty warning"
else
  fail_msg "patch-mx: spurious functionally-empty warning OR report missing"
fi

# ---------------------------------------------------------------------------
# Test "settings patch: no-manifest" — consumer removed .claude-pipeline/ but
# settings.json still has path-fragment refs. Patch must still be emitted.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings patch: no-manifest, path-fragment-only injection traces still produces patch'"

PROJ_PATCH_NM="$WORKDIR/proj-patch-nm"
mkdir -p "$PROJ_PATCH_NM/.claude"
cat > "$PROJ_PATCH_NM/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ]
  }
}
EOF
(cd "$PROJ_PATCH_NM" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)

NM_SHA_BEFORE=$(sha256sum "$PROJ_PATCH_NM/.claude/settings.json" | awk '{print $1}')
STDERR_LOG="$WORKDIR/patch-nm.stderr"
STDOUT_LOG="$WORKDIR/patch-nm.stdout"
(cd "$PROJ_PATCH_NM" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG") || true

PATCH_NM="$PROJ_PATCH_NM/.claude/migration-cleanup-settings.patch"

inc
if [ -f "$PATCH_NM" ]; then pass_msg "patch-nm: patch file created"; else fail_msg "patch-nm: patch file missing"; fi

inc
if [ -f "$PATCH_NM" ] && (cd "$PROJ_PATCH_NM" && git apply --check .claude/migration-cleanup-settings.patch) 2>/dev/null; then
  pass_msg "patch-nm: git apply --check clean"
else
  fail_msg "patch-nm: git apply --check failed"
fi

inc
if [ -f "$PATCH_NM" ]; then
  NM_COPY="$WORKDIR/nm-copy"
  cp -r "$PROJ_PATCH_NM" "$NM_COPY"
  if (cd "$NM_COPY" && git apply .claude/migration-cleanup-settings.patch) 2>/dev/null; then
    if [ ! -f "$NM_COPY/.claude/settings.json" ]; then
      pass_msg "patch-nm: post-patch file removed (functionally empty)"
    elif jq -e . "$NM_COPY/.claude/settings.json" >/dev/null 2>&1; then
      pass_msg "patch-nm: post-patch JSON valid"
    else
      fail_msg "patch-nm: post-patch JSON invalid"
    fi
  else
    fail_msg "patch-nm: post-patch apply failed in copy"
  fi
else
  fail_msg "patch-nm: cannot validate post-patch (no patch)"
fi

inc
NM_SHA_AFTER=$(sha256sum "$PROJ_PATCH_NM/.claude/settings.json" 2>/dev/null | awk '{print $1}')
if [ "$NM_SHA_BEFORE" = "$NM_SHA_AFTER" ]; then
  pass_msg "patch-nm: source settings.json byte-identical pre/post"
else
  fail_msg "patch-nm: source settings.json was modified"
fi

# ---------------------------------------------------------------------------
# Test "settings patch: clean" — settings.json has no pipeline refs and the
# .claude-pipeline/ manifest exists (mutation phase still runs). Patch must
# NOT be emitted; report must NOT be emitted.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings patch: clean settings.json produces no patch'"

PROJ_PATCH_CL="$WORKDIR/proj-patch-cl"
mkdir -p "$PROJ_PATCH_CL/.claude-pipeline/hooks" "$PROJ_PATCH_CL/.claude"
touch "$PROJ_PATCH_CL/.claude-pipeline/hooks/log-tool-use.sh"
cat > "$PROJ_PATCH_CL/.claude/settings.json" <<'EOF'
{"hooks": {"PostToolUse": [{"hooks": [{"type": "command", "command": "scripts/my-custom-hook.sh"}]}]}}
EOF

STDERR_LOG="$WORKDIR/patch-cl.stderr"
STDOUT_LOG="$WORKDIR/patch-cl.stdout"
(cd "$PROJ_PATCH_CL" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG")
CL_EXIT=$?

inc
if [ "$CL_EXIT" -eq 0 ]; then pass_msg "patch-cl: exit 0"; else fail_msg "patch-cl: exit $CL_EXIT"; fi

inc
if [ ! -f "$PROJ_PATCH_CL/.claude/migration-cleanup-settings.patch" ]; then
  pass_msg "patch-cl: no patch file (clean settings)"
else
  fail_msg "patch-cl: spurious patch emitted"
fi

inc
if [ ! -f "$PROJ_PATCH_CL/.claude/settings.json.pipeline-migration-report.txt" ]; then
  pass_msg "patch-cl: no advisory report (clean settings)"
else
  fail_msg "patch-cl: spurious report emitted"
fi

# ---------------------------------------------------------------------------
# Test "settings patch: functionally-empty" — settings.json contains ONLY the
# pipeline hook entry. After patch, the file becomes functionally empty so
# the script must emit a loud WARNING in the report and on stdout.
# ---------------------------------------------------------------------------
echo ""
echo "Test 'settings patch: functionally-empty result emits loud warning'"

PROJ_PATCH_FE="$WORKDIR/proj-patch-fe"
mkdir -p "$PROJ_PATCH_FE/.claude-pipeline/hooks" "$PROJ_PATCH_FE/.claude"
touch "$PROJ_PATCH_FE/.claude-pipeline/hooks/log-tool-use.sh"
cat > "$PROJ_PATCH_FE/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PostToolUse": [
      {"hooks": [{"type": "command", "command": ".claude/hooks/log-tool-use.sh"}]}
    ]
  }
}
EOF
(cd "$PROJ_PATCH_FE" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -q -m init)

STDERR_LOG="$WORKDIR/patch-fe.stderr"
STDOUT_LOG="$WORKDIR/patch-fe.stdout"
(cd "$PROJ_PATCH_FE" && bash "$MIGRATE_SH" >"$STDOUT_LOG" 2>"$STDERR_LOG") || true

PATCH_FE="$PROJ_PATCH_FE/.claude/migration-cleanup-settings.patch"
REPORT_FE="$PROJ_PATCH_FE/.claude/settings.json.pipeline-migration-report.txt"

inc
if [ -f "$PATCH_FE" ]; then pass_msg "patch-fe: patch file created"; else fail_msg "patch-fe: patch file missing"; fi

inc
if [ -f "$REPORT_FE" ] && grep -qF 'WARNING: applying this patch will leave .claude/settings.json functionally empty' "$REPORT_FE"; then
  pass_msg "patch-fe: report contains loud functionally-empty warning"
else
  fail_msg "patch-fe: loud warning missing from report"
fi

inc
if grep -qE '^WARNING:.*functionally empty' "$STDOUT_LOG"; then
  pass_msg "patch-fe: stdout warning printed"
else
  fail_msg "patch-fe: loud warning missing from stdout"
fi

inc
if [ -f "$PATCH_FE" ]; then
  FE_COPY="$WORKDIR/fe-copy"
  cp -r "$PROJ_PATCH_FE" "$FE_COPY"
  if (cd "$FE_COPY" && git apply .claude/migration-cleanup-settings.patch) 2>/dev/null; then
    if [ ! -f "$FE_COPY/.claude/settings.json" ]; then
      pass_msg "patch-fe: post-patch removes file (deletion form)"
    elif jq -e '. == {}' "$FE_COPY/.claude/settings.json" >/dev/null 2>&1; then
      pass_msg "patch-fe: post-patch leaves empty object"
    else
      fail_msg "patch-fe: post-patch unexpected shape"
    fi
  else
    fail_msg "patch-fe: post-patch apply failed"
  fi
else
  fail_msg "patch-fe: cannot validate post-patch (no patch)"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
