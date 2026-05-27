#!/bin/bash
set -euo pipefail

# Tests for scripts/fetch-issue-attachments.sh — the helper that scans an
# issue body + comments for GitHub-hosted attachment URLs, downloads them via
# `gh api -i`, derives filenames + extensions from the response Content-Type,
# writes them to ${PIPELINE_PROJECT_ROOT}/.claude/scratch/issue-<N>/, and
# prints a stdout manifest.
#
# `gh` is replaced by a PATH-resident shim that interprets a tiny subset of
# subcommands: `gh issue view --json body,comments --jq ...` and `gh api -i`.
# A call-count file in the shim tracks `gh api` invocations across runs (this
# is what the idempotency test relies on).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/fetch-issue-attachments.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' EXIT

# Stage a fresh PIPELINE_PROJECT_ROOT for one test case (with a writable
# pipeline.config so the helper's `source pipeline.config` succeeds, and a
# .gitignore that includes /.claude/scratch/ by default).
stage_root() {
  local d="$ROOT_TMP/case-$1"
  rm -rf "$d"
  mkdir -p "$d"
  cat > "$d/pipeline.config" <<'CFG'
PIPELINE_REPO="rjskene/pipeline"
PIPELINE_BASE_BRANCH="staging"
CFG
  cat > "$d/.gitignore" <<'GI'
/.claude/scratch/
GI
  echo "$d"
}

# Stage the `gh` shim. The shim reads:
#   $SHIM_BODY              — text to return for `gh issue view ... --jq ...`
#   $SHIM_CT_DEFAULT        — default Content-Type for `gh api -i`
#   $SHIM_API_FAIL_URLS     — newline-separated URLs that should exit nonzero
#   $SHIM_BODY_BYTES        — number of body bytes to emit per asset
#   $SHIM_LOG               — file appended with one line per call
stage_shim() {
  local bin="$1/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_LOG"

# Strip --jq <expr> so we can match the subcommand keys.
JQ=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) JQ="$2"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]}"

sub1="${1:-}"; sub2="${2:-}"
case "$sub1 $sub2" in
  "issue view")
    # The helper requests --json body,comments. Two modes:
    #   - $SHIM_COMMENTS_JSON set: emit it verbatim (structured per-comment
    #     {author.login, authorAssociation, body} data — used by the trust-gate
    #     cases).
    #   - otherwise (legacy): wrap $SHIM_BODY as the issue body with no
    #     comments, so the pre-trust-gate cases keep feeding their combined
    #     text through unchanged.
    if [ -n "${SHIM_COMMENTS_JSON:-}" ]; then
      printf '%s' "$SHIM_COMMENTS_JSON"
    else
      jq -n --arg b "${SHIM_BODY:-}" '{body:$b, comments:[]}'
    fi
    ;;
  "api repos"*)
    # Issue-level metadata lookup: `gh api repos/<owner>/<repo>/issues/<N>`.
    # `gh issue view --json` does NOT expose issue-level authorAssociation, so
    # the helper reads it here. Default opener is trusted (OWNER) so legacy /
    # comment-gate cases keep including the opener body. Does NOT bump
    # $SHIM_API_COUNT (that counter tracks attachment downloads only).
    jq -n \
      --arg assoc "${SHIM_OPENER_ASSOC:-OWNER}" \
      --arg login "${SHIM_OPENER_LOGIN:-opener}" \
      '{author_association:$assoc, user:{login:$login}}'
    ;;
  "api -i"|"api"*)
    # `gh api -i <url>` — print HTTP-like response.
    if [ "$sub2" = "-i" ]; then URL="${3:-}"; else URL="${2:-}"; fi
    # Failure injection.
    if [ -n "${SHIM_API_FAIL_URLS:-}" ]; then
      while IFS= read -r failu; do
        [ -z "$failu" ] && continue
        if [ "$URL" = "$failu" ]; then
          echo "gh: not found" >&2
          exit 22
        fi
      done <<< "$SHIM_API_FAIL_URLS"
    fi
    # Per-URL content-type override via $SHIM_CT_<n>; fallback to $SHIM_CT_DEFAULT.
    CT="${SHIM_CT_DEFAULT:-image/png}"
    if [ -n "${SHIM_CT_BY_URL:-}" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        k="${line%%=*}"; v="${line#*=}"
        if [ "$k" = "$URL" ]; then CT="$v"; fi
      done <<< "$SHIM_CT_BY_URL"
    fi
    # Bump call counter.
    if [ -n "${SHIM_API_COUNT:-}" ]; then
      cur=$(cat "$SHIM_API_COUNT" 2>/dev/null || echo 0)
      echo $((cur + 1)) > "$SHIM_API_COUNT"
    fi
    # Emit HTTP-shaped output. If $SHIM_BODY_FILE is set, stream that file
    # verbatim as the body (used by the binary-safety regression case).
    # Otherwise emit a fixed-length ASCII blob (deterministic so size-based
    # idempotency works).
    if [ -n "${SHIM_BODY_FILE:-}" ] && [ -f "${SHIM_BODY_FILE}" ]; then
      blen=$(LC_ALL=C wc -c < "$SHIM_BODY_FILE" | tr -d ' ')
      printf 'HTTP/2.0 200 OK\r\n'
      printf 'Content-Type: %s\r\n' "$CT"
      printf 'Content-Length: %s\r\n' "$blen"
      printf '\r\n'
      cat "$SHIM_BODY_FILE"
    else
      printf 'HTTP/2.0 200 OK\r\n'
      printf 'Content-Type: %s\r\n' "$CT"
      printf 'Content-Length: %s\r\n' "${SHIM_BODY_BYTES:-16}"
      printf '\r\n'
      head -c "${SHIM_BODY_BYTES:-16}" /dev/zero | tr '\0' 'X'
    fi
    ;;
  *)
    echo "shim: unhandled gh invocation: $*" >&2
    exit 99
    ;;
esac
GH
  chmod +x "$bin/gh"
  export PATH="$bin:$PATH"
}

run_helper() {
  local issue="$1"
  # Run from inside the staged project root (so `source pipeline.config` works).
  ( cd "$PIPELINE_PROJECT_ROOT" && bash "$HELPER" "$issue" )
}

# Reset case-scoped env between cases.
reset_shim_env() {
  unset SHIM_BODY SHIM_CT_DEFAULT SHIM_CT_BY_URL SHIM_API_FAIL_URLS SHIM_BODY_BYTES SHIM_LOG SHIM_API_COUNT SHIM_BODY_FILE SHIM_COMMENTS_JSON SHIM_OPENER_ASSOC SHIM_OPENER_LOGIN
}

# ---------------------------------------------------------------------------
# Case 1: happy path / 2 attachments with extension derivation
# ---------------------------------------------------------------------------
echo "=== Case 1: happy path / 2 attachments with content-type extensions ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 1)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
UUID_A="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
URL_A="https://github.com/user-attachments/assets/${UUID_A}"
URL_B="https://user-images.githubusercontent.com/123/foo.jpg"
SHIM_BODY=$'See screenshot: '"$URL_A"$'\nAnother: '"$URL_B"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_BY_URL="${URL_A}=image/png
${URL_B}=image/jpeg"
SHIM_BODY_BYTES=16
export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_BY_URL SHIM_BODY_BYTES
OUT=$(run_helper 999)

if grep -q "^Found 2 attachments for issue #999:" <<<"$OUT"; then
  pass_msg "stdout manifest header present"
else
  fail_msg "stdout manifest header missing; got: $OUT"
fi
if [ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/${UUID_A}.png" ]; then
  pass_msg "uuid attachment saved with .png extension"
else
  fail_msg ".png file missing"
fi
inc
if [ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/foo.jpg" ]; then
  pass_msg "foo.jpg preserved verbatim (existing extension)"
else
  fail_msg "foo.jpg missing"
fi
inc
if grep -q "${PIPELINE_PROJECT_ROOT}/.claude/scratch/issue-999/${UUID_A}.png" <<<"$OUT" \
   && grep -q "${PIPELINE_PROJECT_ROOT}/.claude/scratch/issue-999/foo.jpg" <<<"$OUT"; then
  pass_msg "manifest lists both absolute paths"
else
  fail_msg "manifest missing one or both paths; got: $OUT"
fi

# ---------------------------------------------------------------------------
# Case 2: zero attachments — scratch dir not created
# ---------------------------------------------------------------------------
echo "=== Case 2: zero attachments ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 2)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
SHIM_BODY=$'No attachments here, just markdown text.'
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
export SHIM_BODY SHIM_LOG
OUT=$(run_helper 999)
if grep -q "^Found 0 attachments for issue #999\." <<<"$OUT"; then
  pass_msg "zero-attachments manifest header"
else
  fail_msg "zero-attachments header wrong; got: $OUT"
fi
inc
if [ ! -d "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999" ]; then
  pass_msg "scratch dir not created on zero attachments"
else
  fail_msg "scratch dir was unexpectedly created"
fi

# ---------------------------------------------------------------------------
# Case 3: idempotent re-run with sticky manifest
# ---------------------------------------------------------------------------
echo "=== Case 3: idempotent re-run / sticky manifest ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 3)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_A="https://github.com/user-attachments/assets/idem-uuid-1"
URL_B="https://user-images.githubusercontent.com/9/bar.png"
SHIM_BODY=$"$URL_A"$'\n'"$URL_B"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_BY_URL="${URL_A}=image/png
${URL_B}=image/png"
SHIM_BODY_BYTES=16
export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_BY_URL SHIM_BODY_BYTES
run_helper 999 >/dev/null
COUNT_FIRST=$(cat "$SHIM_API_COUNT")
OUT2=$(run_helper 999 2>"$PIPELINE_PROJECT_ROOT/stderr.log")
COUNT_SECOND=$(cat "$SHIM_API_COUNT")
if [ "$COUNT_FIRST" = "2" ] && [ "$COUNT_SECOND" = "2" ]; then
  pass_msg "second run did not re-invoke gh api (idempotent)"
else
  fail_msg "expected counts 2 then 2; got $COUNT_FIRST then $COUNT_SECOND"
fi
inc
if grep -q "^Found 2 attachments for issue #999:" <<<"$OUT2"; then
  pass_msg "sticky manifest still emitted on idempotent re-run"
else
  fail_msg "sticky manifest missing on re-run; got: $OUT2"
fi
inc
if grep -q "\[skip\] .*already present" "$PIPELINE_PROJECT_ROOT/stderr.log"; then
  pass_msg "stderr emits [skip] advisory for present files"
else
  fail_msg "missing [skip] advisory; stderr: $(cat "$PIPELINE_PROJECT_ROOT/stderr.log")"
fi

# ---------------------------------------------------------------------------
# Case 4: gitignore warning when /.claude/scratch/ is NOT gitignored
# ---------------------------------------------------------------------------
echo "=== Case 4: gitignore advisory ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 4)"; export PIPELINE_PROJECT_ROOT
# Overwrite .gitignore to NOT include scratch.
echo "node_modules/" > "$PIPELINE_PROJECT_ROOT/.gitignore"
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_A="https://github.com/user-attachments/assets/case4-uuid"
SHIM_BODY="$URL_A"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="image/png"
SHIM_BODY_BYTES=16
export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_BYTES
ERRLOG="$PIPELINE_PROJECT_ROOT/stderr.log"
run_helper 999 >/dev/null 2>"$ERRLOG"
if grep -q "WARN: .claude/scratch/ is not gitignored" "$ERRLOG"; then
  pass_msg "stderr emits gitignore advisory"
else
  fail_msg "missing gitignore WARN; stderr: $(cat "$ERRLOG")"
fi

# ---------------------------------------------------------------------------
# Case 5: bad URL (non-GitHub host) ignored
# ---------------------------------------------------------------------------
echo "=== Case 5: non-attachment URL ignored ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 5)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
SHIM_BODY="Visit https://example.com/not-a-github-attachment.png — irrelevant."
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
export SHIM_BODY SHIM_LOG SHIM_API_COUNT
run_helper 999 >/dev/null
COUNT=$(cat "$SHIM_API_COUNT" 2>/dev/null || true)
[ -z "$COUNT" ] && COUNT=0
if [ "$COUNT" = "0" ] && [ ! -d "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999" ]; then
  pass_msg "non-attachment URL ignored; no gh api call"
else
  fail_msg "expected 0 api calls and no scratch dir; got count=$COUNT, dir=$([ -d "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999" ] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# Case 6: content-type → extension derivation
# ---------------------------------------------------------------------------
echo "=== Case 6: content-type → extension mapping ==="
for sub in png pdf bin; do
  inc
  reset_shim_env
  PIPELINE_PROJECT_ROOT="$(stage_root 6-$sub)"; export PIPELINE_PROJECT_ROOT
  stage_shim "$PIPELINE_PROJECT_ROOT"
  UUID="ctype-uuid-$sub"
  URL="https://github.com/user-attachments/assets/${UUID}"
  case "$sub" in
    png) CT="image/png"; EXT=".png" ;;
    pdf) CT="application/pdf"; EXT=".pdf" ;;
    bin) CT="text/plain"; EXT=".bin" ;;
  esac
  SHIM_BODY="$URL"
  SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
  SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
  SHIM_CT_DEFAULT="$CT"
  SHIM_BODY_BYTES=16
  export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_BYTES
  run_helper 999 >/dev/null
  if [ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/${UUID}${EXT}" ]; then
    pass_msg "ct=$CT → ext=$EXT"
  else
    fail_msg "expected ${UUID}${EXT}, got: $(ls "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/" 2>/dev/null || echo '(no dir)')"
  fi
done

# ---------------------------------------------------------------------------
# Case 7: PIPELINE_PROJECT_ROOT guard
# ---------------------------------------------------------------------------
echo "=== Case 7: PIPELINE_PROJECT_ROOT guard ==="
inc
reset_shim_env
# Stage a project root only to host pipeline.config (in /tmp). Then unset.
GUARD_ROOT="$(stage_root 7)"
stage_shim "$GUARD_ROOT"
ERRLOG="$GUARD_ROOT/stderr.log"
# Invoke from a directory WITHOUT a pipeline.config; ensure PIPELINE_PROJECT_ROOT is unset.
unset PIPELINE_PROJECT_ROOT
set +e
( cd /tmp && bash "$HELPER" 999 ) >/dev/null 2>"$ERRLOG"
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q "ERROR: fetch-issue-attachments.sh must be invoked with PIPELINE_PROJECT_ROOT set" "$ERRLOG"; then
  pass_msg "guard fires when PIPELINE_PROJECT_ROOT unset"
else
  fail_msg "guard did not fire as expected; rc=$rc stderr=$(cat "$ERRLOG")"
fi

# ---------------------------------------------------------------------------
# Case 8: failed-download isolation (one URL fails, other survives)
# ---------------------------------------------------------------------------
echo "=== Case 8: failed-download isolation ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 8)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_A="https://github.com/user-attachments/assets/ok-uuid"
URL_B="https://github.com/user-attachments/assets/fail-uuid"
SHIM_BODY="$URL_A $URL_B"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="image/png"
SHIM_API_FAIL_URLS="$URL_B"
SHIM_BODY_BYTES=16
export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_API_FAIL_URLS SHIM_BODY_BYTES
ERRLOG="$PIPELINE_PROJECT_ROOT/stderr.log"
set +e
OUT=$(run_helper 999 2>"$ERRLOG")
rc=$?
set -e
if [ "$rc" = "0" ]; then
  pass_msg "exits 0 despite one failed download"
else
  fail_msg "expected exit 0, got $rc"
fi
inc
if [ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/ok-uuid.png" ] \
   && [ ! -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/fail-uuid.png" ]; then
  pass_msg "successful asset present, failed asset absent"
else
  fail_msg "isolation failed: ok=$([ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/ok-uuid.png" ] && echo y || echo n) fail=$([ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/fail-uuid.png" ] && echo y || echo n)"
fi
inc
if grep -q "WARN: failed to download" "$ERRLOG"; then
  pass_msg "stderr emits WARN on failed download"
else
  fail_msg "missing WARN; stderr: $(cat "$ERRLOG")"
fi
inc
if grep -q "^Found 1 attachments for issue #999:" <<<"$OUT"; then
  pass_msg "manifest reflects only successfully-downloaded assets (N=1)"
else
  fail_msg "manifest count wrong; got: $OUT"
fi

# ---------------------------------------------------------------------------
# Case 9: binary safety — embedded NUL bytes preserved byte-for-byte
# ---------------------------------------------------------------------------
echo "=== Case 9: binary safety (NUL bytes + full byte range preserved) ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 9)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
# Build a synthetic "binary" body: every byte 0x00..0xff. This exercises NUL,
# CR, LF, and high-bit bytes — the modes most likely to be corrupted by
# bash command substitution or text-mode awk pipelines.
BIN_BODY="$PIPELINE_PROJECT_ROOT/bin-body.bin"
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256)))" > "$BIN_BODY"
EXPECTED_SIZE=$(LC_ALL=C wc -c < "$BIN_BODY" | tr -d ' ')

UUID_BIN="bin-uuid-case9"
URL_BIN="https://github.com/user-attachments/assets/${UUID_BIN}"
SHIM_BODY="Look at this asset: $URL_BIN"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="application/octet-stream"   # expected to fall back to .bin
SHIM_BODY_FILE="$BIN_BODY"
export SHIM_BODY SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_FILE
run_helper 999 >/dev/null

TARGET="$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/${UUID_BIN}.bin"
if [ -f "$TARGET" ]; then
  ACTUAL_SIZE=$(LC_ALL=C wc -c < "$TARGET" | tr -d ' ')
  if [ "$ACTUAL_SIZE" = "$EXPECTED_SIZE" ] && cmp -s "$BIN_BODY" "$TARGET"; then
    pass_msg "binary body preserved byte-for-byte (size $ACTUAL_SIZE)"
  else
    fail_msg "binary corruption: expected size $EXPECTED_SIZE got $ACTUAL_SIZE; cmp=$(cmp "$BIN_BODY" "$TARGET" 2>&1)"
  fi
else
  fail_msg "binary attachment file missing at $TARGET"
fi

# ---------------------------------------------------------------------------
# Case 10: trust gate — URL in an untrusted comment is NOT downloaded
# ---------------------------------------------------------------------------
echo "=== Case 10: trust gate — untrusted comment URL not downloaded ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 10)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_TRUSTED="https://github.com/user-attachments/assets/trusted-uuid-10"
URL_UNTRUSTED="https://github.com/user-attachments/assets/untrusted-uuid-10"
# Opener (OWNER) body has NO url; a trusted (MEMBER) comment carries the
# trusted URL; an untrusted (NONE) comment carries the attacker URL.
SHIM_COMMENTS_JSON=$(jq -n \
  --arg t "$URL_TRUSTED" \
  --arg u "$URL_UNTRUSTED" \
  '{body:"Plain opener body, no attachments.",
    comments:[
      {author:{login:"maintainer"}, authorAssociation:"MEMBER", body:("trusted asset " + $t)},
      {author:{login:"attacker"},   authorAssociation:"NONE",   body:("malicious asset " + $u)}
    ]}')
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="image/png"
SHIM_BODY_BYTES=16
export SHIM_COMMENTS_JSON SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_BYTES
OUT=$(run_helper 999 2>/dev/null)
SCRATCH="$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999"
if [ -f "$SCRATCH/trusted-uuid-10.png" ]; then
  pass_msg "trusted-comment URL still downloaded"
else
  fail_msg "trusted-comment asset missing; got: $OUT"
fi
inc
if [ ! -f "$SCRATCH/untrusted-uuid-10.png" ]; then
  pass_msg "untrusted-comment URL not downloaded"
else
  fail_msg "untrusted-comment asset was downloaded (trust gate not applied)"
fi
inc
if ! grep -q "$URL_UNTRUSTED" "$SHIM_LOG"; then
  pass_msg "no gh api download attempted for untrusted-comment URL"
else
  fail_msg "gh api was invoked for the untrusted-comment URL: $(grep "$URL_UNTRUSTED" "$SHIM_LOG")"
fi

# ---------------------------------------------------------------------------
# Case 11: trust gate — URL in an UNTRUSTED opener body is NOT downloaded
# ---------------------------------------------------------------------------
echo "=== Case 11: trust gate — untrusted opener body URL not downloaded ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 11)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_BODY="https://github.com/user-attachments/assets/openerbody-uuid-11"
SHIM_COMMENTS_JSON=$(jq -n --arg b "$URL_BODY" \
  '{body:("see " + $b), comments:[]}')
SHIM_OPENER_ASSOC="NONE"
SHIM_OPENER_LOGIN="drive-by"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="image/png"
SHIM_BODY_BYTES=16
export SHIM_COMMENTS_JSON SHIM_OPENER_ASSOC SHIM_OPENER_LOGIN SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_BYTES
OUT=$(run_helper 999 2>/dev/null)
if [ ! -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/openerbody-uuid-11.png" ]; then
  pass_msg "untrusted-opener body URL not downloaded"
else
  fail_msg "untrusted-opener body asset was downloaded (opener gate not applied)"
fi
inc
if ! grep -q "$URL_BODY" "$SHIM_LOG"; then
  pass_msg "no gh api download attempted for untrusted-opener body URL"
else
  fail_msg "gh api was invoked for the untrusted-opener body URL"
fi

# ---------------------------------------------------------------------------
# Case 12: trust gate does NOT over-filter — trusted opener body URL downloaded
# ---------------------------------------------------------------------------
echo "=== Case 12: trusted opener body URL still downloaded ==="
inc
reset_shim_env
PIPELINE_PROJECT_ROOT="$(stage_root 12)"; export PIPELINE_PROJECT_ROOT
stage_shim "$PIPELINE_PROJECT_ROOT"
URL_BODY2="https://github.com/user-attachments/assets/openerbody-uuid-12"
SHIM_COMMENTS_JSON=$(jq -n --arg b "$URL_BODY2" \
  '{body:("see " + $b), comments:[]}')
SHIM_OPENER_ASSOC="OWNER"
SHIM_OPENER_LOGIN="maintainer"
SHIM_LOG="$PIPELINE_PROJECT_ROOT/shim.log"; : > "$SHIM_LOG"
SHIM_API_COUNT="$PIPELINE_PROJECT_ROOT/api.count"; : > "$SHIM_API_COUNT"
SHIM_CT_DEFAULT="image/png"
SHIM_BODY_BYTES=16
export SHIM_COMMENTS_JSON SHIM_OPENER_ASSOC SHIM_OPENER_LOGIN SHIM_LOG SHIM_API_COUNT SHIM_CT_DEFAULT SHIM_BODY_BYTES
OUT=$(run_helper 999 2>/dev/null)
if [ -f "$PIPELINE_PROJECT_ROOT/.claude/scratch/issue-999/openerbody-uuid-12.png" ]; then
  pass_msg "trusted-opener body URL still downloaded"
else
  fail_msg "trusted-opener body asset missing (gate over-filtered); got: $OUT"
fi

echo ""
echo "================================================================"
echo "Results: $PASS passed, $FAIL failed (out of $TESTS test assertions)"
echo "================================================================"

[ "$FAIL" -eq 0 ]
