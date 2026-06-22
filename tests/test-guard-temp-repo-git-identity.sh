#!/usr/bin/env bash
# Regression guard (issue #1117 / PR #1116): no test may `git init` a `mktemp`
# repo AND run an EXECUTED `git … commit` while providing NO inline git
# identity anywhere in the file.
#
# Root cause this guards against: a temp repo created with a fresh `git init`
# does NOT inherit the checked-out repo's identity, and CI has no GLOBAL git
# identity. A bare `git commit` in such a repo passes locally (developer has a
# global identity) but fails CI with exit 128 ("Please tell me who you are").
#
# Invariant: file-scope (NOT line-proximity). A file is FLAGGED iff it has all
# of: a `git … init`, a `mktemp`, and an EXECUTED `git … commit` (comment lines
# and JSON hook-input payload lines do NOT count), AND it provides NO identity
# anywhere in the file (inline `-c user.email/name`, `git config user.*`, or
# `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env).
#
# Safe pattern: call `git_init_sandbox` from tests/_lib/git-sandbox.sh, or use
# inline `git -c user.email=… -c user.name=… commit`.
#
# RED note: this file CALLS scan_file() and sources tests/_lib/git-sandbox.sh,
# neither of which exists yet — the GREEN implementer defines them. Until then
# this guard fails for the RIGHT reason (undefined function / missing source).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------
# scan_file <path>
# Returns 0 (exit 0) if the file is SAFE (not flagged), non-zero if FLAGGED.
# A file is FLAGGED iff ALL of:
#   (a) contains a `git … init` invocation
#   (b) contains a `mktemp` invocation
#   (c) contains an EXECUTED `git … commit` (comment lines and JSON payload
#       lines are excluded)
#   AND provides NO identity anywhere in the file.
# ---------------------------------------------------------------------------
scan_file() {
  local f="$1"

  # (a) has git init?
  grep -qE 'git[^\n]*\binit\b' "$f" || return 0

  # (b) has mktemp?
  grep -q 'mktemp' "$f" || return 0

  # (c) has an EXECUTED git commit? (strip comment lines + JSON payload lines)
  local commit_lines
  commit_lines=$(grep -nE 'git[^\n]*\bcommit\b' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '"command"[[:space:]]*:')
  [ -n "$commit_lines" ] || return 0

  # identity present anywhere in the file? (any one shape => safe)
  if grep -qE '-c[[:space:]]+user\.(email|name)' "$f"; then return 0; fi
  if grep -qE 'config[[:space:]]+user\.(email|name)' "$f"; then return 0; fi
  if grep -qE 'GIT_(AUTHOR|COMMITTER)_(NAME|EMAIL)' "$f"; then return 0; fi

  # Flagged — print diagnostics to stdout
  echo "FLAGGED: $f"
  echo "  Executed-commit lines:"
  while IFS= read -r line; do
    echo "    $line"
  done <<< "$commit_lines"
  echo "  Remediation: use git_init_sandbox from tests/_lib/git-sandbox.sh,"
  echo "  or inline 'git -c user.email=… -c user.name=… commit'."
  return 1
}
TESTS_DIR="$SCRIPT_DIR"
SELF_BASENAME="$(basename "$0")"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc()      { TESTS=$((TESTS + 1)); }

SCRATCH="$(mktemp -d)"
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# ---- Self-check 1: BAD fixture MUST be flagged (true-positive arm) ----
# Synthetic fixture that inits a mktemp repo and commits with NO identity.
echo "Self-check 1: BAD fixture (temp-repo commit, no identity) is flagged"
inc
BAD_FIXTURE="$SCRATCH/bad-fixture.sh"
cat >"$BAD_FIXTURE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="$(mktemp -d)"
git -C "$repo" init -q
echo x > "$repo/f"
git -C "$repo" add f
git -C "$repo" commit -qm "first"
EOF

if scan_file "$BAD_FIXTURE" >/dev/null 2>&1; then
  fail_msg "BAD fixture should be flagged (scan_file returned not-flagged)"
else
  pass_msg "BAD fixture flagged by scan_file"
fi

# ---- Self-check 2: GOOD fixture must NOT be flagged (true-negative arm) ----
# Same shape but with inline -c user.email / -c user.name identity.
echo "Self-check 2: GOOD fixture (inline -c identity) is NOT flagged"
inc
GOOD_FIXTURE="$SCRATCH/good-fixture.sh"
cat >"$GOOD_FIXTURE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
repo="$(mktemp -d)"
git -C "$repo" init -q
echo x > "$repo/f"
git -C "$repo" add f
git -C "$repo" -c user.email=t@t.t -c user.name=t commit -qm "first"
EOF

if scan_file "$GOOD_FIXTURE" >/dev/null 2>&1; then
  pass_msg "GOOD fixture not flagged by scan_file"
else
  fail_msg "GOOD fixture should NOT be flagged (it sets inline -c identity)"
fi

# ---- Self-check 3: live scan of the real tests/ tree yields ZERO flags ----
echo "Self-check 3: live scan of tests/ yields zero flags"
inc
flagged_files=()
for t in "$TESTS_DIR"/test*.sh "$TESTS_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  case "$(basename "$t")" in
    "$SELF_BASENAME") continue ;;
  esac
  # Skip anything under tests/_lib/ (helpers, not discoverable tests).
  case "$t" in
    */_lib/*) continue ;;
  esac
  if ! scan_file "$t" >/dev/null 2>&1; then
    flagged_files+=("$t")
  fi
done

if [ "${#flagged_files[@]}" -eq 0 ]; then
  pass_msg "no temp-repo-commit-without-identity violations in tests/"
else
  fail_msg "${#flagged_files[@]} file(s) flagged in tests/:"
  for f in "${flagged_files[@]}"; do
    echo "    $f"
  done
  echo "    Remediation: call git_init_sandbox from tests/_lib/git-sandbox.sh,"
  echo "    or use inline 'git -c user.email=… -c user.name=… commit'."
fi

# ---- Self-check 4: git_init_sandbox helper stamps a usable identity ----
echo "Self-check 4: git_init_sandbox yields an identity sufficient to commit"
inc
# shellcheck source=/dev/null
if source "$TESTS_DIR/_lib/git-sandbox.sh" 2>/dev/null; then
  SANDBOX_DIR="$(mktemp -d)"
  if git_init_sandbox "$SANDBOX_DIR" >/dev/null 2>&1 \
     && git -C "$SANDBOX_DIR" commit --allow-empty -qm x >/dev/null 2>&1; then
    pass_msg "git_init_sandbox stamped a usable identity (commit exit 0)"
  else
    fail_msg "git_init_sandbox did not yield a usable identity (commit failed)"
  fi
  rm -rf "$SANDBOX_DIR"
else
  fail_msg "could not source tests/_lib/git-sandbox.sh (helper missing)"
fi

echo ""
echo "================================"
echo "Tests: $TESTS Pass: $PASS Fail: $FAIL"
echo "================================"

[ "$FAIL" -eq 0 ]
