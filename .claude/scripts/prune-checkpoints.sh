#!/bin/bash
set -euo pipefail

# prune-checkpoints.sh — Delete local checkpoint/* tags older than a threshold.
#
# Usage:
#   bash .claude/scripts/prune-checkpoints.sh --older-than <Nd> [--dry-run]
#
# Only touches tags matching refs/tags/checkpoint/* — semver and other tags
# are left alone. Never touches remote tags.

MAIN_REPO="$(cd "$(dirname "$0")/../.." && pwd)"

OLDER_THAN=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --older-than) OLDER_THAN="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '3,11p' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$OLDER_THAN" ]; then
  echo "Usage: bash $0 --older-than <Nd> [--dry-run]" >&2
  exit 1
fi

if [[ ! "$OLDER_THAN" =~ ^([0-9]+)d$ ]]; then
  echo "ERROR: --older-than must be of the form <N>d (e.g., 7d, 30d); got: $OLDER_THAN" >&2
  exit 1
fi
DAYS="${BASH_REMATCH[1]}"

cd "$MAIN_REPO"

IS_GNU=false
if date --version >/dev/null 2>&1; then
  IS_GNU=true
fi

if $IS_GNU; then
  CUTOFF=$(date -d "-${DAYS} days" +%s)
elif date -j -f "%Y-%m-%d" "2000-01-01" +%s >/dev/null 2>&1; then
  CUTOFF=$(date -j -v-"${DAYS}"d +%s)
else
  echo "ERROR: unsupported date command (neither GNU nor BSD detected)" >&2
  exit 1
fi

DELETED=0
KEPT=0

while IFS=' ' read -r tagdate tagname; do
  [ -z "$tagname" ] && continue

  if $IS_GNU; then
    tag_epoch=$(date -d "$tagdate" +%s 2>/dev/null || echo "")
  else
    # BSD date: normalize iso-strict tz like "+00:00" -> "+0000"
    norm_date=$(printf '%s' "$tagdate" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/')
    tag_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$norm_date" +%s 2>/dev/null || echo "")
  fi

  if [ -z "$tag_epoch" ]; then
    echo "  [skip] could not parse date for $tagname: $tagdate" >&2
    continue
  fi

  if [ "$tag_epoch" -lt "$CUTOFF" ]; then
    if $DRY_RUN; then
      echo "DRY RUN: would delete $tagname (tagged $tagdate)"
    else
      git tag -d "$tagname" >/dev/null
      echo "Deleted: $tagname (tagged $tagdate)"
    fi
    DELETED=$((DELETED + 1))
  else
    KEPT=$((KEPT + 1))
  fi
done < <(git for-each-ref --format='%(taggerdate:iso-strict) %(refname:short)' 'refs/tags/checkpoint/*')

echo ""
if $DRY_RUN; then
  echo "DRY RUN: would delete ${DELETED} tag(s), would keep ${KEPT}."
else
  echo "Deleted ${DELETED} tag(s), kept ${KEPT}."
fi
