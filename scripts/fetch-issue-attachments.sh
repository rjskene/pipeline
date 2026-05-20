#!/bin/bash
# fetch-issue-attachments.sh — scan an issue body + comments for
# GitHub-hosted attachment URLs, download them via authenticated `gh api -i`,
# derive a filename + extension from the response `Content-Type:` header,
# and write the bytes to ${PIPELINE_PROJECT_ROOT}/.claude/scratch/issue-<N>/.
#
# Idempotent: re-running on the same issue with existing on-disk files
# emits the manifest from disk without re-downloading.
#
# Stdout: a manifest of the form `Found N attachments for issue #<N>:`
#         followed by one absolute path per line (sticky on re-run).
# Stderr: [skip] / WARN / ERROR advisories.
#
# Refuses to run from inside a worktree: must be invoked with
# PIPELINE_PROJECT_ROOT set, which downstream callers
# (`/pipeline:fullsend` step 1a, `/pipeline:plan-issue` step 3b) provide
# explicitly. `setup-worktree.sh` mirrors the resulting scratch dir into
# the worktree; worktree-side ingestion would create a duplicate dir and
# break that contract.
set -euo pipefail

# Load pipeline config from the configured project root (or fall back to PWD,
# which is what callers running from the consumer repo root rely on).
PROJECT_DIR="${PIPELINE_PROJECT_ROOT:-$(pwd)}"
# shellcheck disable=SC1091
[ -f "$PROJECT_DIR/pipeline.config" ] && source "$PROJECT_DIR/pipeline.config"

# Guard — refuse to run when PIPELINE_PROJECT_ROOT is unset. Worktree-side
# invocations would create a duplicate scratch dir; see header comment.
if [ -z "${PIPELINE_PROJECT_ROOT:-}" ]; then
  echo "ERROR: fetch-issue-attachments.sh must be invoked with PIPELINE_PROJECT_ROOT set; refuse worktree-side invocation" >&2
  exit 2
fi

ISSUE="${1:-}"
if [ -z "$ISSUE" ]; then
  echo "Usage: bash fetch-issue-attachments.sh <issue-number>" >&2
  exit 1
fi

SCRATCH_DIR="${PIPELINE_PROJECT_ROOT}/.claude/scratch/issue-${ISSUE}"
REPO="${PIPELINE_REPO:-}"

# Gitignore advisory — fire once per invocation when the repo doesn't yet
# ignore the scratch tree.
if [ -f "${PIPELINE_PROJECT_ROOT}/.gitignore" ]; then
  if ! grep -qE '^/?\.claude/scratch/?' "${PIPELINE_PROJECT_ROOT}/.gitignore"; then
    echo "WARN: .claude/scratch/ is not gitignored; add a /.claude/scratch/ line" >&2
  fi
fi

# Fetch body + comments in one `gh` call.
BODY_AND_COMMENTS=$(gh issue view "$ISSUE" --repo "$REPO" --json body,comments \
  --jq '.body + "\n" + ([.comments[].body] | join("\n"))' 2>/dev/null || true)

# Extract GitHub-hosted attachment URLs. Three accepted hosts:
#   - https://github.com/user-attachments/assets/<uuid>            (no extension)
#   - https://user-images.githubusercontent.com/<id>/<path>        (has extension)
#   - https://private-user-images.githubusercontent.com/<…>?jwt=…  (has extension; JWT query)
URLS=$(printf '%s' "$BODY_AND_COMMENTS" | grep -oE \
  '(https://github\.com/user-attachments/assets/[A-Za-z0-9-]+|https://user-images\.githubusercontent\.com/[A-Za-z0-9./_-]+|https://private-user-images\.githubusercontent\.com/[A-Za-z0-9./_?=&-]+)' \
  | sort -u || true)

# Map a Content-Type header value (charset stripped) to an extension.
ct_to_ext() {
  case "$1" in
    image/png)        echo ".png" ;;
    image/jpeg|image/jpg) echo ".jpg" ;;
    image/gif)        echo ".gif" ;;
    image/webp)       echo ".webp" ;;
    application/pdf)  echo ".pdf" ;;
    *)                echo ".bin" ;;
  esac
}

# Derive the on-disk filename from URL + content-type.
# - user-attachments/assets/<uuid>  → "<uuid><ext>"
# - user-images.githubusercontent.com/<id>/<rest> → basename(rest); preserve extension
# - private-user-images.githubusercontent.com/?jwt=… → strip query, basename; append ext only if missing
derive_filename() {
  local url="$1" ct="$2" ext base
  ext=$(ct_to_ext "$ct")
  case "$url" in
    https://github.com/user-attachments/assets/*)
      local uuid="${url##*/}"
      echo "${uuid}${ext}"
      ;;
    https://user-images.githubusercontent.com/*)
      base="${url##*/}"
      # If the basename already carries an extension, keep it as-is.
      case "$base" in
        *.*) echo "$base" ;;
        *)   echo "${base}${ext}" ;;
      esac
      ;;
    https://private-user-images.githubusercontent.com/*)
      # Strip query string.
      local stripped="${url%%\?*}"
      base="${stripped##*/}"
      case "$base" in
        *.*) echo "$base" ;;
        *)   echo "${base}${ext}" ;;
      esac
      ;;
    *)
      # Defensive fallback (regex above should prevent reaching here).
      base="${url##*/}"
      case "$base" in
        *.*) echo "$base" ;;
        *)   echo "${base}${ext}" ;;
      esac
      ;;
  esac
}

# No attachments — print manifest and exit. Do NOT create SCRATCH_DIR.
if [ -z "$URLS" ]; then
  echo "Found 0 attachments for issue #${ISSUE}."
  exit 0
fi

mkdir -p "$SCRATCH_DIR"

MANIFEST=()

while IFS= read -r url; do
  [ -z "$url" ] && continue

  # Idempotency pre-check (avoid `gh api` entirely when we already have this
  # asset on disk). The two URL shapes differ in how we predict the filename:
  #   - user-attachments/assets/<uuid>: ext unknown until we fetch — match by
  #     "<uuid>.*" glob in SCRATCH_DIR.
  #   - {user,private-user}-images.githubusercontent.com: filename = basename
  #     (with any "?jwt=…" stripped). Known a priori.
  existing=""
  case "$url" in
    https://github.com/user-attachments/assets/*)
      uuid_only="${url##*/}"
      for cand in "$SCRATCH_DIR/$uuid_only".*; do
        if [ -s "$cand" ]; then existing="$cand"; break; fi
      done
      ;;
    https://user-images.githubusercontent.com/*|https://private-user-images.githubusercontent.com/*)
      stripped="${url%%\?*}"
      base_only="${stripped##*/}"
      [ -s "$SCRATCH_DIR/$base_only" ] && existing="$SCRATCH_DIR/$base_only"
      ;;
  esac
  if [ -n "$existing" ]; then
    echo "[skip] $existing already present" >&2
    MANIFEST+=("$existing")
    continue
  fi

  # Stream `gh api -i` to a tempfile so the HTTP body is binary-safe
  # (bash command substitution strips NUL bytes; piping through awk/printf
  # appends a stray newline — both corrupt real PNG/JPG/PDF downloads).
  raw_tmp="$SCRATCH_DIR/.raw.$$.$RANDOM"
  body_tmp="$raw_tmp.body"
  set +e
  gh api -i "$url" > "$raw_tmp" 2>/dev/null
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    rm -f "$raw_tmp"
    echo "WARN: failed to download $url (gh api exit $rc)" >&2
    continue
  fi

  # Split headers from body and parse Content-Type in one python3 pass.
  # `grep -F` on a multi-byte pattern across newlines is unreliable on GNU
  # grep (line-oriented even under -a), so we do the split in python where
  # binary-safe re.search and `wb` writes are guaranteed. python3 is already
  # a runtime dep (see hooks/restrict_paths.py).
  set +e
  ct=$(PIPELINE_BODY_OUT="$body_tmp" python3 - "$raw_tmp" <<'PY'
import os, re, sys
with open(sys.argv[1], 'rb') as f:
    data = f.read()
m = re.search(rb'\r?\n\r?\n', data)
if m is None:
    sys.stderr.write("NOSEP\n")
    sys.exit(1)
hdr = data[:m.start()].decode('latin-1', errors='replace')
ct = ""
for line in hdr.splitlines():
    if line.lower().startswith('content-type:'):
        ct = line.split(':', 1)[1].strip().split(';')[0].strip()
        break
with open(os.environ['PIPELINE_BODY_OUT'], 'wb') as out:
    out.write(data[m.end():])
print(ct)
PY
  )
  py_rc=$?
  set -e
  if [ "$py_rc" -ne 0 ] || [ ! -f "$body_tmp" ]; then
    rm -f "$raw_tmp" "$body_tmp"
    echo "WARN: malformed HTTP response for $url" >&2
    continue
  fi

  filename=$(derive_filename "$url" "$ct")
  target="$SCRATCH_DIR/$filename"

  # Idempotency — skip if a non-empty file with this name already exists.
  if [ -s "$target" ]; then
    rm -f "$raw_tmp" "$body_tmp"
    echo "[skip] $target already present" >&2
    MANIFEST+=("$target")
    continue
  fi

  # Atomic rename — body_tmp was written by python in binary mode, so NUL
  # bytes and CRLF sequences are byte-for-byte preserved.
  mv "$body_tmp" "$target"
  rm -f "$raw_tmp"
  MANIFEST+=("$target")
done <<< "$URLS"

# Emit manifest.
N=${#MANIFEST[@]}
echo "Found $N attachments for issue #${ISSUE}:"
for p in "${MANIFEST[@]}"; do
  echo "$p"
done
