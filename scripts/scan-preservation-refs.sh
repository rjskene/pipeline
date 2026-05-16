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
HAS_PLUGIN=false
HAS_SUBTREE=false
[ -n "$plugin_root" ] && [ -d "$plugin_root" ] && HAS_PLUGIN=true
[ -d .claude-pipeline ] && HAS_SUBTREE=true
if [ "$HAS_PLUGIN" = false ] && [ "$HAS_SUBTREE" = false ]; then
  echo "scan-preservation-refs: no CLAUDE_PLUGIN_ROOT and no .claude-pipeline/ — nothing to scan" >&2
  exit 1
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build a basename lookup of "files the consumer's local copy could be a
# duplicate of": union of $plugin_root/{scripts,hooks}/ basenames (current
# plugin counterparts, for doctor) and .claude-pipeline/{scripts,hooks}/
# basenames stripped of .template suffix (legacy subtree marker, for
# migrate). A consumer file enters the report when its basename matches
# either source.
shipped_tmp="$(mktemp)"
trap 'rm -f "$shipped_tmp"' EXIT
{
  if [ "$HAS_PLUGIN" = true ]; then
    for sub in scripts hooks; do
      [ -d "$plugin_root/$sub" ] && find "$plugin_root/$sub" -type f -printf '%f\n' 2>/dev/null
    done
  fi
  if [ "$HAS_SUBTREE" = true ]; then
    for sub in scripts hooks; do
      [ -d ".claude-pipeline/$sub" ] || continue
      find ".claude-pipeline/$sub" -type f -printf '%f\n' 2>/dev/null \
        | sed 's/\.template$//'
    done
  fi
} | sort -u > "$shipped_tmp"

has_counterpart() { grep -qxF "$1" "$shipped_tmp"; }

# --------------------------------------------------------------------------
# Cache diff-consumer-files.sh output ONCE per helper invocation. Per-path
# drift bucket lookup powers the active-wiring vs fork distinction without
# re-running the classifier for every settings.json hit (Blocker 4). Only
# meaningful when a plugin root is available; in migrate-from-subtree mode
# the bucket map stays empty and settings.json hits classify as active-
# wiring (the conservative default).
# --------------------------------------------------------------------------
declare -A DRIFT_BUCKET=()
if [ "$HAS_PLUGIN" = true ]; then
  _diff_out="$(bash "$SELF_DIR/diff-consumer-files.sh" 2>/dev/null || true)"
  while IFS=$'\t' read -r _p _bucket _rest; do
    [ -n "$_p" ] || continue
    DRIFT_BUCKET["$_p"]="$_bucket"
  done <<<"$_diff_out"
fi

# Plugin-shipped skill set — for falls-away vs consumer-skill-ref distinction
# (Blocker 3). Mirrors migrate-from-subtree.sh's basename-match logic. Empty
# when CLAUDE_PLUGIN_ROOT is unresolved; in that case every SKILL.md ref
# falls into the consumer-skill-ref bucket (conservative — see SKILL.md
# Risks section).
declare -A PLUGIN_SKILL_SET=()
if [ "$HAS_PLUGIN" = true ] && [ -d "$plugin_root/skills" ]; then
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

# Accumulator: REF_BUCKETS[<consumer_path>] = "<bucket1> <bucket2> ..."
declare -A REF_BUCKETS=()

# scan_refs_for <consumer_path> — emit REF rows on stdout for each external
# reference to the file's consumer-form path AND populate REF_BUCKETS so
# verdict_for can resolve KEEP vs DELETE per-file.
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
    REF_BUCKETS["$consumer_path"]+=" $bucket"
    printf 'REF\t%s\t%s:%s\t%s\t%s\n' "$consumer_path" "$ref_file" "$lineno" "$bucket" "$snippet"
  done <<<"$hits"
}

# verdict_for <consumer_path> — emit a single VERDICT row. KEEP wins over
# DELETE the moment a concerning bucket appears
# ({active-wiring, fork, consumer-skill-ref, doc-ref}); otherwise DELETE.
verdict_for() {
  local consumer_path="$1"
  local buckets="${REF_BUCKETS[$consumer_path]:-}"
  if [ -z "$buckets" ]; then
    printf 'VERDICT\t%s\tDELETE\tno references\n' "$consumer_path"; return
  fi
  case " $buckets " in
    *" active-wiring "*)      printf 'VERDICT\t%s\tKEEP\tactive wiring — rewire settings then delete\n' "$consumer_path"; return ;;
    *" fork "*)               printf 'VERDICT\t%s\tKEEP\tintentional fork\n' "$consumer_path"; return ;;
    *" consumer-skill-ref "*) printf 'VERDICT\t%s\tKEEP\theld by consumer-authored skill; resolve manually\n' "$consumer_path"; return ;;
    *" doc-ref "*)            printf 'VERDICT\t%s\tKEEP\tdocumentation reference; resolve manually post-migration\n' "$consumer_path"; return ;;
  esac
  case " $buckets " in
    *" falls-away "*) printf 'VERDICT\t%s\tDELETE\tonly plugin-shipped SKILL.md ref(s); falls away after migration\n' "$consumer_path"; return ;;
    *" self-only "*)  printf 'VERDICT\t%s\tDELETE\tself-comment(s) only; --keep-referenced false-positive\n' "$consumer_path"; return ;;
  esac
  printf 'VERDICT\t%s\tKEEP\tunclassified\n' "$consumer_path"
}

# Walk consumer .claude/{scripts,hooks}/ and emit REF rows followed by a
# single VERDICT row per file.
for sub in scripts hooks; do
  [ -d ".claude/$sub" ] || continue
  while IFS= read -r -d '' local_path; do
    local_path="${local_path#./}"
    bn="$(basename "$local_path")"
    has_counterpart "$bn" || continue
    scan_refs_for "$local_path"
    verdict_for "$local_path"
  done < <(find ".claude/$sub" -type f -print0 2>/dev/null)
done

exit 0
