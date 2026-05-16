#!/bin/bash
# tests/test-doctor-preservation-refs.sh — tests for scan-preservation-refs.sh
# and the preservation_refs check in doctor.sh.
#
# Builds a fake project tree + fake $CLAUDE_PLUGIN_ROOT per case (mirroring
# the fresh_fx pattern from test-doctor-consumer-drift.sh) and asserts the
# REF / VERDICT rows the helper emits, plus the doctor block output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/scan-preservation-refs.sh"
DIFF_HELPER="$SCRIPT_DIR/../scripts/diff-consumer-files.sh"
DOCTOR="$SCRIPT_DIR/../scripts/doctor.sh"

PASS=0
FAIL=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap "rm -rf $TMP" EXIT

# ---------------------------------------------------------------------------
# Fixture builder
#
# Materialises:
#   $1/proj/ — fake consumer project
#     pipeline.config (PIPELINE_REPO=owner/repo-correct)
#     .claude/{scripts,hooks,skills/pipeline}/
#   $1/plugin/ — fake $CLAUDE_PLUGIN_ROOT
#     scripts/, hooks/, skills/pipeline/SKILL.md
#
# Echoes the fixture root; cd into "$root/proj" to run the helper.
# ---------------------------------------------------------------------------
fresh_fx() {
  local name="$1"
  local root="$TMP/$name"
  rm -rf "$root"
  mkdir -p "$root/proj/.claude/scripts" "$root/proj/.claude/hooks" \
           "$root/proj/.claude/skills/pipeline"
  mkdir -p "$root/plugin/scripts" "$root/plugin/hooks" \
           "$root/plugin/skills/pipeline"
  cat > "$root/proj/pipeline.config" <<'CFG'
PIPELINE_REPO="owner/repo-correct"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_TMUX_SESSION="dev"
CFG
  # Plugin-shipped pipeline skill (so .claude/skills/pipeline/SKILL.md refs
  # classify as falls-away by default).
  printf '# pipeline\n' > "$root/plugin/skills/pipeline/SKILL.md"
  echo "$root"
}

run_helper() {
  local root="$1"; shift
  (
    cd "$root/proj"
    # shellcheck disable=SC1091
    source ./pipeline.config
    CLAUDE_PLUGIN_ROOT="$root/plugin" bash "$HELPER" "$@"
  )
}

# ---------------------------------------------------------------------------
# Case 1: helper exists and is executable.
# ---------------------------------------------------------------------------
echo "Case 1: helper exists"
if [ -f "$HELPER" ]; then
  pass_msg "scan-preservation-refs.sh exists at $HELPER"
else
  fail_msg "scan-preservation-refs.sh missing at $HELPER"
fi

# ---------------------------------------------------------------------------
# Case 2: empty fixture (no consumer .claude/{scripts,hooks}/ files) emits
# zero rows and exits 0.
# ---------------------------------------------------------------------------
echo "Case 2: empty fixture → zero rows, rc=0"
ROOT=$(fresh_fx fx-empty)
out="$(run_helper "$ROOT" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
  pass_msg "empty fixture: zero rows, rc=0"
else
  fail_msg "empty fixture: expected zero rows + rc=0 (got rc=$rc, out='$out')"
fi

# ---------------------------------------------------------------------------
# Case 3: helper enumerates the same set of .claude/scripts/ + .claude/hooks/
# files (with plugin counterparts) as diff-consumer-files.sh covers.
# ---------------------------------------------------------------------------
echo "Case 3: enumeration parity with diff-consumer-files.sh"
ROOT=$(fresh_fx fx-parity)
# Plugin ships three files; consumer has copies of two of them plus one extra.
printf '#!/bin/bash\necho a\n' > "$ROOT/plugin/scripts/a.sh"
printf '#!/bin/bash\necho b\n' > "$ROOT/plugin/scripts/b.sh"
printf '#!/bin/bash\necho h\n' > "$ROOT/plugin/hooks/h.py"
cp "$ROOT/plugin/scripts/a.sh" "$ROOT/proj/.claude/scripts/a.sh"
cp "$ROOT/plugin/hooks/h.py" "$ROOT/proj/.claude/hooks/h.py"
# Consumer-only file (no plugin counterpart) — should NOT appear in helper output.
printf '#!/bin/bash\necho own\n' > "$ROOT/proj/.claude/scripts/consumer-only.sh"

scan_files="$(run_helper "$ROOT" | awk -F'\t' '$1=="REF"||$1=="VERDICT"{print $2}' | sort -u)"
expected="$(printf '%s\n' '.claude/hooks/h.py' '.claude/scripts/a.sh' | sort -u)"
if [ "$scan_files" = "$expected" ]; then
  pass_msg "helper enumerates files with plugin counterparts only"
else
  fail_msg "enumeration parity mismatch"
  echo "    expected:"; echo "$expected" | sed 's/^/      /'
  echo "    got:"; echo "$scan_files" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# Case 4: active-wiring — settings.json reference, non-C drift.
# ---------------------------------------------------------------------------
echo "Case 4: active-wiring (settings.json)"
ROOT=$(fresh_fx fx-active)
printf '#!/bin/bash\necho block\n' > "$ROOT/plugin/hooks/block.py"
cp "$ROOT/plugin/hooks/block.py" "$ROOT/proj/.claude/hooks/block.py"
cat > "$ROOT/proj/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/block.py"}]}]}}
JSON
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/hooks/block\.py	\.claude/settings\.json:[0-9]+	active-wiring	"; then
  pass_msg "active-wiring REF row emitted"
else
  fail_msg "no active-wiring row"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 5: falls-away — SKILL.md ref AND plugin ships skill <name>.
# ---------------------------------------------------------------------------
echo "Case 5: falls-away (plugin-shipped SKILL.md)"
ROOT=$(fresh_fx fx-falls)
printf '#!/bin/bash\necho review\n' > "$ROOT/plugin/scripts/review-logs.sh"
cp "$ROOT/plugin/scripts/review-logs.sh" "$ROOT/proj/.claude/scripts/review-logs.sh"
# plugin/skills/pipeline already created by fresh_fx → falls-away applies.
echo "See .claude/scripts/review-logs.sh for details." > "$ROOT/proj/.claude/skills/pipeline/SKILL.md"
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/scripts/review-logs\.sh	\.claude/skills/pipeline/SKILL\.md:[0-9]+	falls-away	"; then
  pass_msg "falls-away REF row emitted"
else
  fail_msg "no falls-away row"
  echo "$out" | sed 's/^/    /'
fi
# Negative: must NOT bucket as active-wiring.
if echo "$out" | grep -qE "active-wiring"; then
  fail_msg "spurious active-wiring on SKILL.md ref"
else
  pass_msg "no spurious active-wiring"
fi

# ---------------------------------------------------------------------------
# Case 6: self-only — only reference is inside the file itself.
# ---------------------------------------------------------------------------
echo "Case 6: self-only"
ROOT=$(fresh_fx fx-self)
printf '#!/bin/bash\necho prune\n' > "$ROOT/plugin/scripts/prune.sh"
cat > "$ROOT/proj/.claude/scripts/prune.sh" <<'SH'
#!/bin/bash
# Usage: .claude/scripts/prune.sh --help
echo prune
SH
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/scripts/prune\.sh	\.claude/scripts/prune\.sh:[0-9]+	self-only	"; then
  pass_msg "self-only REF row emitted"
else
  fail_msg "no self-only row"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 7: fork — settings.json ref AND drift bucket = C.
# ---------------------------------------------------------------------------
echo "Case 7: fork (settings.json ref + bucket-C divergence)"
ROOT=$(fresh_fx fx-fork)
cat > "$ROOT/plugin/scripts/run-queue.sh" <<'SH'
#!/bin/bash
echo plugin-version
SH
cat > "$ROOT/proj/.claude/scripts/run-queue.sh" <<'SH'
#!/bin/bash
case "${1:-}" in
  --runs) echo "fork-only feature"; exit 0;;
esac
SH
cat > "$ROOT/proj/.claude/settings.json" <<'JSON'
{"hooks":{"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":".claude/scripts/run-queue.sh"}]}]}}
JSON
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/scripts/run-queue\.sh	\.claude/settings\.json:[0-9]+	fork	"; then
  pass_msg "fork REF row emitted"
else
  fail_msg "no fork row"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 8: VERDICT DELETE — all references non-concerning (self-only + falls-away).
# ---------------------------------------------------------------------------
echo "Case 8: VERDICT DELETE (all non-concerning)"
ROOT=$(fresh_fx fx-delete)
printf '#!/bin/bash\n# Usage: .claude/scripts/foo.sh\n' > "$ROOT/plugin/scripts/foo.sh"
cp "$ROOT/plugin/scripts/foo.sh" "$ROOT/proj/.claude/scripts/foo.sh"
echo "See .claude/scripts/foo.sh" > "$ROOT/proj/.claude/skills/pipeline/SKILL.md"
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^VERDICT	\.claude/scripts/foo\.sh	DELETE	"; then
  pass_msg "VERDICT DELETE emitted"
else
  fail_msg "expected DELETE verdict"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 9: VERDICT KEEP — at least one active-wiring reference.
# ---------------------------------------------------------------------------
echo "Case 9: VERDICT KEEP (active-wiring present)"
ROOT=$(fresh_fx fx-keep)
printf '#!/bin/bash\necho wire\n' > "$ROOT/plugin/hooks/wire.py"
cp "$ROOT/plugin/hooks/wire.py" "$ROOT/proj/.claude/hooks/wire.py"
cat > "$ROOT/proj/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/wire.py"}]}]}}
JSON
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^VERDICT	\.claude/hooks/wire\.py	KEEP	"; then
  pass_msg "VERDICT KEEP emitted"
else
  fail_msg "expected KEEP verdict"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 10: mixed refs (active-wiring + falls-away) → KEEP.
# ---------------------------------------------------------------------------
echo "Case 10: mixed refs → KEEP"
ROOT=$(fresh_fx fx-mixed)
printf '#!/bin/bash\necho mixed\n' > "$ROOT/plugin/hooks/mixed.py"
cp "$ROOT/plugin/hooks/mixed.py" "$ROOT/proj/.claude/hooks/mixed.py"
cat > "$ROOT/proj/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/mixed.py"}]}]}}
JSON
echo "doc ref: .claude/hooks/mixed.py" > "$ROOT/proj/.claude/skills/pipeline/SKILL.md"
out="$(run_helper "$ROOT")"
ref_count="$(echo "$out" | awk -F'\t' '$1=="REF" && $2==".claude/hooks/mixed.py"' | wc -l | tr -d ' ')"
if [ "$ref_count" = "2" ]; then
  pass_msg "two REF rows for mixed file"
else
  fail_msg "expected 2 REF rows, got $ref_count"
  echo "$out" | sed 's/^/    /'
fi
if echo "$out" | grep -qE "^VERDICT	\.claude/hooks/mixed\.py	KEEP	"; then
  pass_msg "KEEP wins with one concerning ref"
else
  fail_msg "expected KEEP on mixed"
fi

# ---------------------------------------------------------------------------
# Case 11: no references anywhere → DELETE with 'no references' hint.
# ---------------------------------------------------------------------------
echo "Case 11: no refs → DELETE"
ROOT=$(fresh_fx fx-noref)
printf '#!/bin/bash\necho lonely-plugin\n' > "$ROOT/plugin/scripts/lonely.sh"
printf '#!/bin/bash\necho lonely-local\n' > "$ROOT/proj/.claude/scripts/lonely.sh"
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^VERDICT	\.claude/scripts/lonely\.sh	DELETE	no references"; then
  pass_msg "DELETE on zero refs"
else
  fail_msg "expected DELETE w/ 'no references' hint"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 12: migrate-from-subtree.sh --keep-referenced regression.
#
# Provisions all three sources of preserved.sh that exist in a realistic
# pre-migration consumer install:
#   1. .claude-pipeline/scripts/preserved.sh — subtree marker (migrate
#      enumerates from here, lines 114-127, to populate TO_REMOVE_SCRIPTS).
#   2. .claude/scripts/preserved.sh — consumer copy installed by the legacy
#      subtree script; the file migrate is about to delete.
#   3. $plugin/scripts/preserved.sh — current plugin counterpart (so the
#      scan-preservation-refs helper enumerates the basename and emits REF
#      rows that the refactored migrate iterates over).
# ---------------------------------------------------------------------------
echo "Case 12: migrate --keep-referenced still preserves referenced file"
ROOT=$(fresh_fx fx-migrate)
MIGRATE="$SCRIPT_DIR/../scripts/migrate-from-subtree.sh"
mkdir -p "$ROOT/proj/.claude-pipeline/scripts"
printf '#!/bin/bash\necho preserved\n' > "$ROOT/proj/.claude-pipeline/scripts/preserved.sh"
printf '#!/bin/bash\necho preserved\n' > "$ROOT/proj/.claude/scripts/preserved.sh"
printf '#!/bin/bash\necho preserved\n' > "$ROOT/plugin/scripts/preserved.sh"
echo "See .claude/scripts/preserved.sh" > "$ROOT/proj/.claude/skills/pipeline/SKILL.md"
out=$(
  cd "$ROOT/proj"
  # shellcheck disable=SC1091
  source ./pipeline.config
  CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$MIGRATE" --keep-referenced --dry-run --assume-yes 2>&1 || true
)
if echo "$out" | grep -q "Preserved due to --keep-referenced:.*preserved.sh"; then
  pass_msg "migrate --keep-referenced preserves on plugin-SKILL.md ref"
else
  fail_msg "migrate regression: file not preserved"
  echo "$out" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 13: doctor preservation_refs check emits per-file blocks.
# ---------------------------------------------------------------------------
echo "Case 13: doctor preservation_refs block output"
ROOT=$(fresh_fx fx-doctor)
printf '#!/bin/bash\necho enforced\n' > "$ROOT/plugin/hooks/enforced.py"
cp "$ROOT/plugin/hooks/enforced.py" "$ROOT/proj/.claude/hooks/enforced.py"
cat > "$ROOT/proj/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":".claude/hooks/enforced.py"}]}]}}
JSON
out=$(
  cd "$ROOT/proj"
  # shellcheck disable=SC1091
  source ./pipeline.config
  CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR" 2>&1 || true
)
if echo "$out" | grep -q "CHECK: preservation_refs"; then
  pass_msg "preservation_refs CHECK line emitted"
else
  fail_msg "no preservation_refs CHECK line"
fi
if echo "$out" | grep -q "\.claude/hooks/enforced\.py"; then
  pass_msg "file path appears in doctor output"
else
  fail_msg "file path missing"
fi
if echo "$out" | grep -qE "Verdict: KEEP"; then
  pass_msg "KEEP verdict surfaced"
else
  fail_msg "KEEP verdict missing"
fi
if echo "$out" | grep -q "active-wiring"; then
  pass_msg "active-wiring annotation surfaced"
else
  fail_msg "active-wiring annotation missing"
fi

# ---------------------------------------------------------------------------
# Case 14: pure-DELETE doctor run records pass, not warn.
# ---------------------------------------------------------------------------
echo "Case 14: pure-DELETE → record pass"
ROOT=$(fresh_fx fx-doctor-clean)
printf '#!/bin/bash\necho lonely\n' > "$ROOT/plugin/scripts/lonely.sh"
printf '#!/bin/bash\necho lonely\n' > "$ROOT/proj/.claude/scripts/lonely.sh"
out=$(
  cd "$ROOT/proj"
  # shellcheck disable=SC1091
  source ./pipeline.config
  CLAUDE_PLUGIN_ROOT="$ROOT/plugin" bash "$DOCTOR" 2>&1 || true
)
if echo "$out" | grep -qE "CHECK: preservation_refs status=pass"; then
  pass_msg "pure-DELETE → pass status"
else
  fail_msg "expected pass, got something else"
  echo "$out" | grep preservation_refs | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 15: SKILL.md documents the preservation_refs check + its taxonomy.
# ---------------------------------------------------------------------------
echo "Case 15: SKILL.md documents preservation_refs"
SKILL_MD="$SCRIPT_DIR/../skills/doctor/SKILL.md"
if grep -q "preservation_refs" "$SKILL_MD"; then
  pass_msg "SKILL.md mentions preservation_refs"
else
  fail_msg "SKILL.md missing preservation_refs section"
fi
if grep -qE "DELETE\s*/\s*KEEP|DELETE.*KEEP|KEEP.*DELETE" "$SKILL_MD"; then
  pass_msg "SKILL.md documents DELETE/KEEP verdict"
else
  fail_msg "SKILL.md missing verdict rule"
fi
if grep -q "active-wiring" "$SKILL_MD"; then
  pass_msg "SKILL.md lists active-wiring bucket"
else
  fail_msg "SKILL.md missing reference-bucket list"
fi
if grep -q "consumer-skill-ref" "$SKILL_MD"; then
  pass_msg "SKILL.md lists consumer-skill-ref bucket"
else
  fail_msg "SKILL.md missing consumer-skill-ref"
fi
if grep -q "doc-ref" "$SKILL_MD"; then
  pass_msg "SKILL.md lists doc-ref bucket"
else
  fail_msg "SKILL.md missing doc-ref"
fi

# ---------------------------------------------------------------------------
# Case 16: consumer-skill-ref — SKILL.md ref BUT skill is consumer-authored
# (plugin does NOT ship this skill). Must classify as consumer-skill-ref,
# NOT falls-away. Verdict: KEEP.
# ---------------------------------------------------------------------------
echo "Case 16: consumer-skill-ref (consumer-authored SKILL.md)"
ROOT=$(fresh_fx fx-consumer-skill)
printf '#!/bin/bash\necho needed\n' > "$ROOT/plugin/scripts/needed.sh"
cp "$ROOT/plugin/scripts/needed.sh" "$ROOT/proj/.claude/scripts/needed.sh"
mkdir -p "$ROOT/proj/.claude/skills/my-custom"
echo "Calls .claude/scripts/needed.sh from my custom skill." \
  > "$ROOT/proj/.claude/skills/my-custom/SKILL.md"
# fresh_fx only ships 'pipeline'; ensure my-custom is NOT plugin-shipped.
rm -rf "$ROOT/plugin/skills/my-custom" 2>/dev/null || true
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/scripts/needed\.sh	\.claude/skills/my-custom/SKILL\.md:[0-9]+	consumer-skill-ref	"; then
  pass_msg "consumer-skill-ref REF row emitted"
else
  fail_msg "expected consumer-skill-ref bucket"
  echo "$out" | sed 's/^/    /'
fi
if echo "$out" | grep -q "falls-away"; then
  fail_msg "spurious falls-away on consumer-authored skill"
else
  pass_msg "no spurious falls-away"
fi
if echo "$out" | grep -qE "^VERDICT	\.claude/scripts/needed\.sh	KEEP	held by consumer-authored skill"; then
  pass_msg "consumer-skill-ref → KEEP with correct hint"
else
  fail_msg "expected KEEP w/ consumer-authored hint"
fi

# ---------------------------------------------------------------------------
# Case 17: doc-ref — reference in arbitrary project doc (CLAUDE.md /
# README.md) outside .claude/skills/*/SKILL.md and outside settings.json.
# Verdict: KEEP. Critical: must NOT be misclassified as active-wiring.
# ---------------------------------------------------------------------------
echo "Case 17: doc-ref (CLAUDE.md / README.md)"
ROOT=$(fresh_fx fx-doc-ref)
printf '#!/bin/bash\necho logged\n' > "$ROOT/plugin/scripts/logged.sh"
cp "$ROOT/plugin/scripts/logged.sh" "$ROOT/proj/.claude/scripts/logged.sh"
cat > "$ROOT/proj/CLAUDE.md" <<'MD'
See .claude/scripts/logged.sh for the observability log writer.
MD
cat > "$ROOT/proj/README.md" <<'MD'
Run .claude/scripts/logged.sh after install.
MD
out="$(run_helper "$ROOT")"
if echo "$out" | grep -qE "^REF	\.claude/scripts/logged\.sh	CLAUDE\.md:[0-9]+	doc-ref	"; then
  pass_msg "doc-ref REF row (CLAUDE.md) emitted"
else
  fail_msg "expected doc-ref for CLAUDE.md"
  echo "$out" | sed 's/^/    /'
fi
if echo "$out" | grep -qE "^REF	\.claude/scripts/logged\.sh	README\.md:[0-9]+	doc-ref	"; then
  pass_msg "doc-ref REF row (README.md) emitted"
else
  fail_msg "expected doc-ref for README.md"
fi
if echo "$out" | grep -q "active-wiring"; then
  fail_msg "doc-ref incorrectly classified as active-wiring"
else
  pass_msg "no spurious active-wiring on doc-ref"
fi
if echo "$out" | grep -qE "^VERDICT	\.claude/scripts/logged\.sh	KEEP	documentation reference"; then
  pass_msg "doc-ref → KEEP w/ 'documentation reference' hint"
else
  fail_msg "expected KEEP w/ documentation hint"
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
