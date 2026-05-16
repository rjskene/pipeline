#!/bin/bash
# scripts/scan-preservation-refs.sh — enumerate consumer .claude/{scripts,hooks}/
# files that have a plugin counterpart, scan the project tree for references
# to each, classify, and emit:
#
#   REF\t<consumer_path>\t<ref_file>:<lineno>\t<ref_bucket>\t<snippet>
#   VERDICT\t<consumer_path>\t<DELETE|KEEP>\t<hint>
#
# ref_bucket ∈ {
#   active-wiring      — settings.json reference (and not bucket-C drift)
#   falls-away         — SKILL.md ref AND skill is plugin-shipped (will be removed)
#   consumer-skill-ref — SKILL.md ref AND skill is consumer-authored (NOT removed)
#   self-only          — only reference is inside the file itself
#   fork               — settings.json ref AND drift bucket = C
#   doc-ref            — any other .md/.txt source outside .claude/skills/*/SKILL.md
# }
#
# Caching: diff-consumer-files.sh is invoked ONCE at helper start and the
# per-path bucket cached for classify_ref lookups. Reused by doctor +
# migrate-from-subtree.
set -uo pipefail

plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root" ]; then
  echo "scan-preservation-refs: CLAUDE_PLUGIN_ROOT empty or not a directory" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build a basename lookup of plugin-shipped scripts/hooks. A consumer file
# enters the report only when its basename appears in this set (parity with
# diff-consumer-files.sh's basename-collision rule).
shipped_tmp="$(mktemp)"
trap 'rm -f "$shipped_tmp"' EXIT
for sub in scripts hooks; do
  if [ -d "$plugin_root/$sub" ]; then
    find "$plugin_root/$sub" -type f -printf '%f\n' 2>/dev/null
  fi
done | sort -u > "$shipped_tmp"

has_counterpart() { grep -qxF "$1" "$shipped_tmp"; }

# --------------------------------------------------------------------------
# Cache diff-consumer-files.sh output ONCE per helper invocation. Per-path
# drift bucket lookup powers the active-wiring vs fork distinction without
# re-running the classifier for every settings.json hit (Blocker 4).
# --------------------------------------------------------------------------
declare -A DRIFT_BUCKET=()
_diff_out="$(bash "$SELF_DIR/diff-consumer-files.sh" 2>/dev/null || true)"
while IFS=$'\t' read -r _p _bucket _rest; do
  [ -n "$_p" ] || continue
  DRIFT_BUCKET["$_p"]="$_bucket"
done <<<"$_diff_out"

# Plugin-shipped skill set — for falls-away vs consumer-skill-ref distinction
# (Blocker 3). Mirrors migrate-from-subtree.sh's basename-match logic.
declare -A PLUGIN_SKILL_SET=()
if [ -d "$plugin_root/skills" ]; then
  for d in "$plugin_root"/skills/*/; do
    [ -d "$d" ] || continue
    PLUGIN_SKILL_SET["$(basename "$d")"]=1
  done
fi

# Six-bucket classifier — explicit enumeration, no default fallback to
# active-wiring (Blocker 2). Each known source type maps to exactly one
# bucket; long-tail unknown sources fall through to doc-ref so they surface
# but don't masquerade as live wiring.
classify_ref() {
  # $1: consumer_path, $2: ref_file
  local consumer_path="$1" ref_file="$2"
  # self-only — reference is inside the file itself.
  if [ "$ref_file" = "$consumer_path" ]; then
    echo "self-only"; return
  fi
  # active-wiring / fork — .claude/settings.json.
  case "$ref_file" in
    .claude/settings.json|*/.claude/settings.json)
      local bucket="${DRIFT_BUCKET[$consumer_path]:-}"
      if [ "$bucket" = "C" ]; then echo "fork"; else echo "active-wiring"; fi
      return
      ;;
  esac
  # falls-away vs consumer-skill-ref — .claude/skills/<name>/SKILL.md.
  case "$ref_file" in
    .claude/skills/*/SKILL.md)
      local _skill_path="${ref_file#.claude/skills/}"
      local _skill_name="${_skill_path%%/*}"
      if [ "${PLUGIN_SKILL_SET[$_skill_name]:-}" = 1 ]; then
        echo "falls-away"
      else
        echo "consumer-skill-ref"
      fi
      return
      ;;
  esac
  # doc-ref — any other .md/.txt source (CLAUDE.md, README.md, dev/audits/*).
  case "$ref_file" in
    *.md|*.txt) echo "doc-ref"; return ;;
  esac
  # Long-tail unknown source — treat conservatively as doc-ref so it surfaces
  # but doesn't get a misleading active-wiring label.
  echo "doc-ref"
}

# scan_refs_for <consumer_path> — emit REF rows on stdout for each external
# reference to the file's consumer-form path. self-comments inside the file
# itself classify as self-only.
scan_refs_for() {
  local consumer_path="$1"
  local bn; bn="$(basename "$consumer_path")"
  local sub; sub="$(basename "$(dirname "$consumer_path")")"
  local needle=".claude/${sub}/${bn}"
  local hits
  hits="$(grep -rn -F \
      --include='*.md' --include='*.sh' --include='*.py' --include='*.json' \
      --include='*.txt' \
      --exclude-dir=.git --exclude-dir=node_modules \
      --exclude-dir=.claude-pipeline \
      "$needle" . 2>/dev/null \
    | grep -v '^\./\.claude/worktrees/' \
    || true)"
  [ -n "$hits" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#./}"
    local ref_file="${line%%:*}"
    local rest="${line#*:}"
    local lineno="${rest%%:*}"
    local snippet="${rest#*:}"
    [ "${#snippet}" -gt 160 ] && snippet="${snippet:0:160}..."
    local bucket
    bucket="$(classify_ref "$consumer_path" "$ref_file")"
    printf 'REF\t%s\t%s:%s\t%s\t%s\n' "$consumer_path" "$ref_file" "$lineno" "$bucket" "$snippet"
  done <<<"$hits"
}

# Walk consumer .claude/{scripts,hooks}/ and emit REF rows + placeholder
# VERDICT rows per file. Real verdict logic lands in Task 4.
for sub in scripts hooks; do
  [ -d ".claude/$sub" ] || continue
  while IFS= read -r -d '' local_path; do
    local_path="${local_path#./}"
    bn="$(basename "$local_path")"
    has_counterpart "$bn" || continue
    scan_refs_for "$local_path"
    printf 'VERDICT\t%s\tKEEP\tpending classification\n' "$local_path"
  done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
done

exit 0
