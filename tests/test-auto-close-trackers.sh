#!/bin/bash
set -euo pipefail

# Tests for scripts/auto-close-trackers.sh — the helper that scans open
# `tracker`-labelled issues, determines whether all checklist children are
# closed, and optionally invokes `gh issue close` to auto-close them.
#
# The gh CLI is replaced by a PATH-resident shim that interprets a small
# set of subcommands and reads state from env vars / a body file.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../scripts/auto-close-trackers.sh"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
mkdir -p "$TMP/bin"

# Shim:
# - gh issue list --label tracker --state open --json number ...
#     -> prints contents of $TRACKER_LIST (default: [{"number":999}])
# - gh issue view <N> --json body ...
#     -> prints contents of $BODY_FILE
# - gh issue view <N> --json state ...
#     -> looks up state in $STATES (space-separated "N=STATE" pairs)
# - gh issue close <N> ...
#     -> records and exits 0
#
# Every invocation appends one line to $SHIM_LOG.
cat > "$TMP/bin/gh" <<'GH'
#!/bin/bash
echo "gh $*" >> "$SHIM_LOG"

# strip --jq <expr> from args (we always print raw json or the requested field)
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
  "issue list")
    # match --json number --jq .[].number → print numbers one per line
    if [ "$JQ" = ".[].number" ]; then
      # read TRACKER_LIST json, extract numbers
      python3 -c 'import json,os,sys
data=json.loads(os.environ.get("TRACKER_LIST","[{\"number\":999}]"))
for d in data: print(d["number"])'
    else
      printf '%s\n' "${TRACKER_LIST:-[{\"number\":999}]}"
    fi
    ;;
  "issue view")
    # find target N and the json key requested
    N="$3"
    KEY=""
    for ((i=4;i<=$#;i++)); do
      v="${!i}"
      if [ "$v" = "--json" ]; then
        j=$((i+1)); KEY="${!j}"
      fi
    done
    if [ "$KEY" = "body" ]; then
      cat "${BODY_FILE:-/dev/null}"
    elif [ "$KEY" = "state" ]; then
      # look up N in $STATES
      state="OPEN"
      for pair in $STATES; do
        k="${pair%%=*}"; v="${pair#*=}"
        if [ "$k" = "$N" ]; then state="$v"; fi
      done
      if [ "$JQ" = ".state" ]; then echo "$state"; else printf '{"state":"%s"}\n' "$state"; fi
    fi
    ;;
  "issue close")
    exit 0
    ;;
  *)
    echo "shim: unhandled gh invocation: $*" >&2
    exit 99
    ;;
esac
GH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export PIPELINE_REPO="rjskene/pipeline"

# Synthetic tracker body with `## Rollout sequence` block and three children.
BODY="$TMP/body.md"
cat > "$BODY" <<'BODY'
## Context
Some context paragraph.

## Rollout sequence

Brief prose note.

- [ ] **#101 — first task**
- [ ] **#102 — second task**
- [ ] **#103 — third task**

## Notes
Trailing section that must NOT be parsed as children.

- [ ] **#999 — should be ignored (not in rollout)**
BODY

reset_case() {
  local case_dir="$1"
  rm -rf "$case_dir"; mkdir -p "$case_dir"
  export SHIM_LOG="$case_dir/calls.log"
  : > "$SHIM_LOG"
  export BODY_FILE="$BODY"
  export TRACKER_LIST='[{"number":999}]'
}

# ---- Case A: all children closed ----
echo "Case A: all-closed"
inc
A="$TMP/case-a"; reset_case "$A"
export STATES="101=CLOSED 102=CLOSED 103=CLOSED"

if bash "$HELPER" >"$A/stdout" 2>"$A/stderr"; then
  if grep -qE '^STATUS: all-closed tracker=999' "$A/stdout"; then
    pass_msg "all-closed: emits STATUS: all-closed tracker=999"
  else
    fail_msg "all-closed: stdout missing 'STATUS: all-closed tracker=999'"
    sed 's/^/    /' "$A/stdout"
  fi
else
  rc=$?
  fail_msg "all-closed: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$A/stderr"
fi

# ---- Case B: pending (one open child) ----
echo "Case B: pending"
inc
B="$TMP/case-b"; reset_case "$B"
export STATES="101=CLOSED 102=OPEN 103=CLOSED"

if bash "$HELPER" >"$B/stdout" 2>"$B/stderr"; then
  if grep -qE '^STATUS: pending tracker=999 open=102' "$B/stdout"; then
    pass_msg "pending: emits STATUS: pending tracker=999 open=102"
  else
    fail_msg "pending: stdout missing expected STATUS line"
    sed 's/^/    /' "$B/stdout"
  fi
else
  rc=$?
  fail_msg "pending: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$B/stderr"
fi

# ---- Case C: no-children (rollout block has no `- [ ] **#N` items) ----
echo "Case C: no-children"
inc
C="$TMP/case-c"; reset_case "$C"
NOCHILD="$TMP/body-nochild.md"
# #491: this fixture must contain NO `#NNN` mentions anywhere. The fallback
# mention-scan (Case I+) would otherwise pick up an out-of-rollout `#101` and
# flip this from no-children to pending. Default-mode section bounding is
# already proven by parse-tracker-children Case B, so the decoy is unneeded.
cat > "$NOCHILD" <<'BODY'
## Rollout sequence

Just a prose blurb, no checklist.

## Notes
Trailing prose with no issue references.
BODY
export BODY_FILE="$NOCHILD"
export STATES=""
if bash "$HELPER" >"$C/stdout" 2>"$C/stderr"; then
  if grep -qE '^STATUS: no-children tracker=999' "$C/stdout"; then
    pass_msg "no-children: emits STATUS: no-children tracker=999"
  else
    fail_msg "no-children: stdout missing expected STATUS line"
    sed 's/^/    /' "$C/stdout"
  fi
else
  rc=$?
  fail_msg "no-children: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$C/stderr"
fi

# ---- Case D: mixed hyphen / en-dash, both detected ----
echo "Case D: mixed dash forms"
inc
D="$TMP/case-d"; reset_case "$D"
MIXED="$TMP/body-mixed.md"
cat > "$MIXED" <<'BODY'
## Rollout sequence

- [ ] **#101 - ascii hyphen**
- [ ] **#102 — en-dash**

## End
BODY
export BODY_FILE="$MIXED"
export STATES="101=CLOSED 102=CLOSED"
if bash "$HELPER" >"$D/stdout" 2>"$D/stderr"; then
  if grep -qE '^STATUS: all-closed tracker=999' "$D/stdout"; then
    pass_msg "mixed dashes: both children detected; all-closed emitted"
  else
    fail_msg "mixed dashes: expected all-closed, got:"
    sed 's/^/    /' "$D/stdout"
  fi
else
  rc=$?
  fail_msg "mixed dashes: helper exited $rc; expected 0"
fi

# ---- Case E: --apply closes only when all-closed ----
echo "Case E: --apply on all-closed → closes tracker"
inc
E="$TMP/case-e"; reset_case "$E"
export STATES="101=CLOSED 102=CLOSED 103=CLOSED"
if bash "$HELPER" --apply >"$E/stdout" 2>"$E/stderr"; then
  n_close=$(grep -cE '^gh issue close 999' "$SHIM_LOG" || true)
  if [ "$n_close" = "1" ]; then
    if grep -qF -- '--comment Auto-closed: all children merged.' "$SHIM_LOG"; then
      pass_msg "--apply on all-closed: gh issue close 999 invoked once with exact comment"
    else
      fail_msg "--apply on all-closed: close invoked but comment text wrong"
      sed 's/^/    /' "$SHIM_LOG"
    fi
  else
    fail_msg "--apply on all-closed: expected 1 'gh issue close 999', saw $n_close"
    sed 's/^/    /' "$SHIM_LOG"
  fi
else
  rc=$?
  fail_msg "--apply on all-closed: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$E/stderr"
fi

# ---- Case F: --apply on pending → does NOT close ----
echo "Case F: --apply on pending → no close"
inc
F="$TMP/case-f"; reset_case "$F"
export STATES="101=CLOSED 102=OPEN 103=CLOSED"
if bash "$HELPER" --apply >"$F/stdout" 2>"$F/stderr"; then
  n_close=$(grep -cE '^gh issue close' "$SHIM_LOG" || true)
  if [ "$n_close" = "0" ]; then
    pass_msg "--apply on pending: zero 'gh issue close' calls"
  else
    fail_msg "--apply on pending: expected 0 'gh issue close', saw $n_close"
  fi
else
  rc=$?
  fail_msg "--apply on pending: helper exited $rc"
fi

# ---- Case G: --apply on no-children → no close ----
echo "Case G: --apply on no-children → no close"
inc
G="$TMP/case-g"; reset_case "$G"
export BODY_FILE="$NOCHILD"
export STATES=""
if bash "$HELPER" --apply >"$G/stdout" 2>"$G/stderr"; then
  n_close=$(grep -cE '^gh issue close' "$SHIM_LOG" || true)
  if [ "$n_close" = "0" ]; then
    pass_msg "--apply on no-children: zero 'gh issue close' calls"
  else
    fail_msg "--apply on no-children: expected 0 'gh issue close', saw $n_close"
  fi
else
  rc=$?
  fail_msg "--apply on no-children: helper exited $rc"
fi

# ---- Case H: missing PIPELINE_REPO and no --repo → documented error ----
# Regression-guard for the script's `PIPELINE_REPO (or --repo) is required` exit
# path. Protects against silently changing this contract (e.g., adding a
# pipeline.config self-source inside the helper, "option 2" in #288).
echo "Case H: missing PIPELINE_REPO and no --repo → required-error"
inc
H="$TMP/case-h"; reset_case "$H"
# env -i wipes the environment; we restore PATH to reach the gh stub but
# deliberately omit PIPELINE_REPO. Helper must exit non-zero with the
# documented stderr message.
if env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$HOME" \
     bash "$HELPER" --apply >"$H/stdout" 2>"$H/stderr"; then
  fail_msg "missing PIPELINE_REPO: helper exited 0 — expected non-zero"
  echo "    stderr:"; sed 's/^/      /' "$H/stderr"
else
  rc=$?
  if [ "$rc" -ne 0 ] && grep -qF 'PIPELINE_REPO (or --repo) is required' "$H/stderr"; then
    pass_msg "missing PIPELINE_REPO: helper exited $rc with documented error"
  else
    fail_msg "missing PIPELINE_REPO: exit=$rc but stderr lacks the documented error"
    echo "    stderr:"; sed 's/^/      /' "$H/stderr"
  fi
fi

# ============================================================================
# Fallback mention-scan path (#491): when the tracker body has no
# `## Rollout sequence` checklist, auto-close falls back to scanning the whole
# body for `#NNN` mentions, and surfaces an all-closed result as the distinct
# `STATUS: all-closed-fallback` line so the operator can audit the parser path
# used. The `pending` line shape is unchanged regardless of fallback.
# ============================================================================

# Body with NO `## Rollout sequence` section — children live only as prose
# `#NNN` mentions, in first-appearance order 101,102,103.
MENTIONS="$TMP/body-mentions.md"
cat > "$MENTIONS" <<'BODY'
## Context
This tracker coordinates #101, #102, and #103. No rollout checklist here.
BODY

# ---- Case I: no rollout + all mentions CLOSED → all-closed-fallback ----
echo "Case I: fallback all-closed → STATUS: all-closed-fallback"
inc
CI="$TMP/case-i"; reset_case "$CI"
export BODY_FILE="$MENTIONS"
export STATES="101=CLOSED 102=CLOSED 103=CLOSED"
if bash "$HELPER" >"$CI/stdout" 2>"$CI/stderr"; then
  if grep -qE '^STATUS: all-closed-fallback tracker=999 children=101,102,103' "$CI/stdout"; then
    pass_msg "fallback all-closed: emits all-closed-fallback with csv children"
  else
    fail_msg "fallback all-closed: stdout missing expected line"
    sed 's/^/    /' "$CI/stdout"
  fi
else
  rc=$?
  fail_msg "fallback all-closed: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$CI/stderr"
fi

# ---- Case J: no rollout + one mention OPEN → pending (no -fallback suffix) ----
echo "Case J: fallback pending → STATUS: pending (shape unchanged)"
inc
CJ="$TMP/case-j"; reset_case "$CJ"
export BODY_FILE="$MENTIONS"
export STATES="101=CLOSED 102=OPEN 103=CLOSED"
if bash "$HELPER" >"$CJ/stdout" 2>"$CJ/stderr"; then
  if grep -qE '^STATUS: pending tracker=999 open=102' "$CJ/stdout"; then
    pass_msg "fallback pending: emits STATUS: pending tracker=999 open=102"
  else
    fail_msg "fallback pending: stdout missing expected line"
    sed 's/^/    /' "$CJ/stdout"
  fi
else
  rc=$?
  fail_msg "fallback pending: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$CJ/stderr"
fi

# ---- Case K: no rollout AND no mentions → no-children preserved ----
echo "Case K: no rollout + no mentions → no-children preserved"
inc
CK="$TMP/case-k"; reset_case "$CK"
NONE="$TMP/body-none.md"
cat > "$NONE" <<'BODY'
## Context
Plain prose with no rollout checklist and no issue references at all.

## Plan
Some plan text.
BODY
export BODY_FILE="$NONE"
export STATES=""
if bash "$HELPER" >"$CK/stdout" 2>"$CK/stderr"; then
  if grep -qE '^STATUS: no-children tracker=999' "$CK/stdout"; then
    pass_msg "no rollout + no mentions: STATUS: no-children preserved"
  else
    fail_msg "no rollout + no mentions: stdout missing no-children line"
    sed 's/^/    /' "$CK/stdout"
  fi
else
  rc=$?
  fail_msg "no rollout + no mentions: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$CK/stderr"
fi

# ---- Case L: --apply on fallback all-closed → closes tracker once ----
echo "Case L: --apply on fallback all-closed → close 999 once, exact comment"
inc
CL="$TMP/case-l"; reset_case "$CL"
export BODY_FILE="$MENTIONS"
export STATES="101=CLOSED 102=CLOSED 103=CLOSED"
if bash "$HELPER" --apply >"$CL/stdout" 2>"$CL/stderr"; then
  n_close=$(grep -cE '^gh issue close 999' "$SHIM_LOG" || true)
  if [ "$n_close" = "1" ]; then
    if grep -qF -- '--comment Auto-closed: all children merged.' "$SHIM_LOG"; then
      pass_msg "--apply fallback all-closed: close 999 once with exact comment"
    else
      fail_msg "--apply fallback all-closed: close invoked but comment text wrong"
      sed 's/^/    /' "$SHIM_LOG"
    fi
  else
    fail_msg "--apply fallback all-closed: expected 1 'gh issue close 999', saw $n_close"
    sed 's/^/    /' "$SHIM_LOG"
  fi
else
  rc=$?
  fail_msg "--apply fallback all-closed: helper exited $rc"
  echo "    stderr:"; sed 's/^/      /' "$CL/stderr"
fi

# ---- Case M: merged PR child reports MERGED, not CLOSED → all-closed (#1156) ----
# A tracker checklist may legitimately reference a PR (e.g. a design-doc PR).
# A merged PR reports state MERGED, not CLOSED; auto-close must treat MERGED as
# done alongside CLOSED, else a tracker whose sole remaining child is a merged
# PR never qualifies for auto-close (observed: work-orchestrator tracker #732 /
# child #746).
echo "Case M: merged PR child (state MERGED) → all-closed"
inc
CM="$TMP/case-m"; reset_case "$CM"
export STATES="101=CLOSED 102=CLOSED 103=MERGED"
if bash "$HELPER" >"$CM/stdout" 2>"$CM/stderr"; then
  if grep -qE '^STATUS: all-closed tracker=999' "$CM/stdout"; then
    pass_msg "merged PR child: MERGED treated as done; all-closed emitted"
  else
    fail_msg "merged PR child: expected all-closed, got:"
    sed 's/^/    /' "$CM/stdout"
  fi
else
  rc=$?
  fail_msg "merged PR child: helper exited $rc; expected 0"
  echo "    stderr:"; sed 's/^/      /' "$CM/stderr"
fi

echo ""
echo "================================"
echo "  $TESTS tests: $PASS passed, $FAIL failed"
echo "================================"

[ "$FAIL" -eq 0 ] || exit 1
