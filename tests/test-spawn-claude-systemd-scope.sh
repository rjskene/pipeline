#!/bin/bash
set -uo pipefail

# Regression guard for issue #918: scripts/spawn-claude.sh must wrap the
# tmux-mode `timeout … claude …` launch in a per-agent
# `systemd-run --user --scope -p MemoryMax=<cap> -p TasksMax=<cap> --` prefix
# so a fork/memory-bomb in one agent is OOM/pid-killed inside its own cgroup
# scope instead of taking down the host. The wrapper MUST degrade gracefully
# to a plain `timeout … claude …` (plus a stderr WARNING) when
# `systemd-run --user` is unavailable (containers, Windows/Git-Bash, hosts with
# no user systemd manager).
#
# All assertions run against the PIPELINE_SPAWN_DRY_RUN=1 state dump (which
# resolves SCOPE_PREFIX and exits BEFORE launching anything) and a static grep
# of the tmux-mode heredoc — driven by a NOOP `systemd-run` stub on PATH. No
# real scope is ever created and no bomb is ever forked.
#
# Caps are configurable via PIPELINE_AGENT_MEMORY_MAX / PIPELINE_AGENT_TASKS_MAX
# (defaults 2G / 512), documented in pipeline.config.example. Dual-scan per
# CLAUDE.md: pipeline.config.example is always present; the gitignored live
# pipeline.config is host-only (skipped when absent).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/../scripts/spawn-claude.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLE="$ROOT/pipeline.config.example"
LIVE="$ROOT/pipeline.config"

PASS=0
FAIL=0
TESTS=0
pass_msg() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail_msg() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
inc() { TESTS=$((TESTS + 1)); }

[ -f "$SCRIPT_UNDER_TEST" ] || { echo "ERROR: $SCRIPT_UNDER_TEST not found" >&2; exit 1; }
[ -f "$EXAMPLE" ]          || { echo "ERROR: $EXAMPLE not found" >&2; exit 1; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PROJ="$WORKDIR/proj"
mkdir -p "$PROJ/worktree"

cat > "$PROJ/pipeline.config" <<'EOF'
PIPELINE_REPO="owner/repo"
PIPELINE_BASE_BRANCH="staging"
PIPELINE_WORKTREE_PREFIX="wt"
PIPELINE_WIN_TEMP=""
PIPELINE_PATH_A_SKILLS_EXECUTE=""
PIPELINE_PATH_B_SKILLS_EXECUTE=""
PIPELINE_PATH_C_SKILLS_EXECUTE=""
PIPELINE_PATH_A_REVIEWER_EXECUTE=""
PIPELINE_PATH_B_REVIEWER_EXECUTE=""
PIPELINE_PATH_C_REVIEWER_EXECUTE=""
EOF

# Stub bin dir: a `gh`/`claude`/`uuidgen` so spawn-claude resolves cleanly, plus
# a NOOP `systemd-run` that ALWAYS succeeds (the live-smoke probe must pass so
# SCOPE_PREFIX is built) without ever creating a real scope.
STUB_DIR="$WORKDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUB_DIR/uuidgen" <<'EOF'
#!/bin/bash
echo "00000000-0000-0000-0000-000000000000"
EOF
# NOOP systemd-run: prints its args (so a curious operator can see what would
# have run) and exits 0 for any invocation — both the `--user --scope -- true`
# smoke probe AND any real launch attempt are absorbed. NEVER forks claude.
cat > "$STUB_DIR/systemd-run" <<'EOF'
#!/bin/bash
echo "[stub systemd-run] $*" >&2
exit 0
EOF
chmod +x "$STUB_DIR"/gh "$STUB_DIR"/claude "$STUB_DIR"/uuidgen "$STUB_DIR"/systemd-run

# A second stub dir for the graceful-degrade case. systemd-run is on PATH but
# the `--user --scope -- true` smoke probe FAILS (exit 1) — simulating the
# Git-Bash / no-user-manager host where the binary exists but there is no user
# systemd instance. This exercises the AND-condition in the probe: presence on
# PATH alone is insufficient; the live smoke must also pass. Putting a failing
# stub FIRST on PATH also shadows any real /usr/bin/systemd-run, so the test is
# hermetic regardless of the CI host.
NOSYSTEMD_DIR="$WORKDIR/stub-no-systemd"
mkdir -p "$NOSYSTEMD_DIR"
cp "$STUB_DIR"/gh "$STUB_DIR"/claude "$STUB_DIR"/uuidgen "$NOSYSTEMD_DIR"/
cat > "$NOSYSTEMD_DIR/systemd-run" <<'EOF'
#!/bin/bash
# Smoke-probe failure: binary present, but no user manager (Failed to connect
# to bus). Always exits non-zero so spawn-claude takes the degrade path.
echo "Failed to connect to bus: No such file or directory" >&2
exit 1
EOF
chmod +x "$NOSYSTEMD_DIR"/*

# Run spawn-claude in dry-run mode with a scrubbed PATH (only the chosen stub
# dir + the minimal system dirs needed for coreutils). Captures stdout+stderr.
# Extra args ("$@") are KEY=VAL env overrides — passed via `env` so a quoted
# expansion in the env-prefix slot is treated as environment, not the command
# word (a bare `VAR=v "$@" cmd` would run VAR=v as the command).
run_dry() {
  local stub="$1"; shift
  (
    cd "$PROJ"
    env PATH="$stub:/usr/bin:/bin" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_PROJECT_ROOT="$PROJ" \
      "$@" \
      bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" 918 issue-918 tmux
  ) 2>&1
}

# ---------------------------------------------------------------------------
# Case 1: systemd-run present (+ smoke probe passes) → SCOPE_PREFIX is built
# with the systemd-run scope and both caps.
# ---------------------------------------------------------------------------
echo "Case 1: systemd-run present → SCOPE_PREFIX carries scope + caps"
OUT="$(run_dry "$STUB_DIR")"

inc
if echo "$OUT" | grep -Eq '^SCOPE_PREFIX=.*systemd-run --user --scope'; then
  pass_msg "case1: dry-run dump shows SCOPE_PREFIX with 'systemd-run --user --scope'"
else
  fail_msg "case1: SCOPE_PREFIX missing 'systemd-run --user --scope'"
  echo "$OUT" | grep -E 'SCOPE_PREFIX|WARNING' | sed 's/^/    /'
fi

inc
if echo "$OUT" | grep -E '^SCOPE_PREFIX=' | grep -q -- '-p MemoryMax='; then
  pass_msg "case1: SCOPE_PREFIX carries -p MemoryMax="
else
  fail_msg "case1: SCOPE_PREFIX missing -p MemoryMax="
fi

inc
if echo "$OUT" | grep -E '^SCOPE_PREFIX=' | grep -q -- '-p TasksMax='; then
  pass_msg "case1: SCOPE_PREFIX carries -p TasksMax="
else
  fail_msg "case1: SCOPE_PREFIX missing -p TasksMax="
fi

# Build a curated coreutils dir (symlinks to the real binaries spawn-claude
# needs) that deliberately EXCLUDES systemd-run, so we can run with a PATH that
# truly lacks it (the plan's "absent from PATH" case) without dragging in the
# host's /usr/bin/systemd-run.
COREUTILS_DIR="$WORKDIR/coreutils"
mkdir -p "$COREUTILS_DIR"
for b in bash sh env cat date dirname realpath mktemp tr command grep sed head tail printf rm mkdir chmod uname find sleep setsid nohup ls sort; do
  p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$COREUTILS_DIR/$b" 2>/dev/null
done
# gh/claude/uuidgen stubs, but deliberately NO systemd-run symlink/stub here.
ln -sf "$STUB_DIR/gh" "$COREUTILS_DIR/gh"
ln -sf "$STUB_DIR/claude" "$COREUTILS_DIR/claude"
ln -sf "$STUB_DIR/uuidgen" "$COREUTILS_DIR/uuidgen"

# Run with a PATH that genuinely lacks systemd-run entirely (curated coreutils +
# stub gh/claude/uuidgen, no /usr/bin, no systemd-run anywhere).
run_dry_absent() {
  (
    cd "$PROJ"
    PATH="$COREUTILS_DIR" \
      PIPELINE_SPAWN_DRY_RUN=1 \
      PIPELINE_PROJECT_ROOT="$PROJ" \
      bash "$SCRIPT_UNDER_TEST" "$PROJ/worktree" 918 issue-918 tmux
  ) 2>&1
}

# ---------------------------------------------------------------------------
# Case 2: systemd-run probe fails (binary present but smoke fails — the
# Git-Bash/no-user-manager degrade case) → SCOPE_PREFIX empty + stderr WARNING.
# ---------------------------------------------------------------------------
echo "Case 2: systemd-run smoke-probe fails → empty SCOPE_PREFIX + WARNING"
OUT="$(run_dry "$NOSYSTEMD_DIR")"

inc
# An empty SCOPE_PREFIX line: `SCOPE_PREFIX=` followed by end-of-line.
if echo "$OUT" | grep -Eq '^SCOPE_PREFIX=$'; then
  pass_msg "case2: SCOPE_PREFIX is empty when systemd-run absent"
else
  fail_msg "case2: SCOPE_PREFIX not empty when systemd-run absent"
  echo "$OUT" | grep -E 'SCOPE_PREFIX' | sed 's/^/    /'
fi

inc
if echo "$OUT" | grep -Eq 'WARNING:.*systemd-run --user (unavailable|not available)|WARNING:.*UNBOUNDED'; then
  pass_msg "case2: WARNING naming the unbounded/degrade condition emitted on stderr"
else
  fail_msg "case2: no WARNING about unbounded/degrade emitted"
  echo "$OUT" | grep -iE 'warn' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 2b: systemd-run truly ABSENT from PATH (the plan's primary degrade case)
# → SCOPE_PREFIX empty + WARNING. Exercises the `command -v` branch directly.
# ---------------------------------------------------------------------------
echo "Case 2b: systemd-run absent from PATH → empty SCOPE_PREFIX + WARNING"
OUT="$(run_dry_absent)"

inc
if echo "$OUT" | grep -Eq '^SCOPE_PREFIX=$'; then
  pass_msg "case2b: SCOPE_PREFIX empty when systemd-run not on PATH"
else
  fail_msg "case2b: SCOPE_PREFIX not empty when systemd-run not on PATH"
  echo "$OUT" | grep -E 'SCOPE_PREFIX' | sed 's/^/    /'
fi
inc
if echo "$OUT" | grep -Eq 'WARNING:.*systemd-run --user (unavailable|not available)|WARNING:.*UNBOUNDED'; then
  pass_msg "case2b: WARNING emitted on stderr when systemd-run absent"
else
  fail_msg "case2b: no WARNING when systemd-run absent"
  echo "$OUT" | grep -iE 'warn' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 3: caps honor PIPELINE_AGENT_MEMORY_MAX / PIPELINE_AGENT_TASKS_MAX.
# ---------------------------------------------------------------------------
echo "Case 3: PIPELINE_AGENT_MEMORY_MAX / PIPELINE_AGENT_TASKS_MAX overrides"
OUT="$(run_dry "$STUB_DIR" PIPELINE_AGENT_MEMORY_MAX=7G PIPELINE_AGENT_TASKS_MAX=99)"

inc
if echo "$OUT" | grep -E '^SCOPE_PREFIX=' | grep -q -- '-p MemoryMax=7G'; then
  pass_msg "case3: MemoryMax override (7G) propagated into SCOPE_PREFIX"
else
  fail_msg "case3: MemoryMax override not honored"
  echo "$OUT" | grep -E '^SCOPE_PREFIX=' | sed 's/^/    /'
fi

inc
if echo "$OUT" | grep -E '^SCOPE_PREFIX=' | grep -q -- '-p TasksMax=99'; then
  pass_msg "case3: TasksMax override (99) propagated into SCOPE_PREFIX"
else
  fail_msg "case3: TasksMax override not honored"
  echo "$OUT" | grep -E '^SCOPE_PREFIX=' | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# Case 4 (Task 2): static heredoc shape — the tmux-mode CMD line must place
# ${SCOPE_PREFIX} BEFORE `timeout` so the scope is the OUTER process. An empty
# SCOPE_PREFIX must collapse to a clean leading `timeout …` (no stray `--`).
# ---------------------------------------------------------------------------
echo "Case 4: tmux CMD line wires \${SCOPE_PREFIX} before timeout"
inc
if grep -Eq 'CMD="\$\{SCOPE_PREFIX\}timeout ' "$SCRIPT_UNDER_TEST"; then
  pass_msg "case4: CMD line is \"\${SCOPE_PREFIX}timeout …\" (scope is the outer process)"
else
  fail_msg "case4: tmux CMD line does not prefix timeout with \${SCOPE_PREFIX}"
  grep -nE 'CMD="' "$SCRIPT_UNDER_TEST" | sed 's/^/    /'
fi

# The bare `CMD="timeout …` (no SCOPE_PREFIX) must be gone from the tmux heredoc.
inc
if grep -Eq 'CMD="timeout ' "$SCRIPT_UNDER_TEST"; then
  fail_msg "case4: a bare CMD=\"timeout …\" still present (scope prefix not wired)"
else
  pass_msg "case4: no bare CMD=\"timeout …\" remains (prefix always applied)"
fi

# ---------------------------------------------------------------------------
# Case 5 (Task 4): config knobs documented in pipeline.config.example, with
# their defaults visible. Dual-scan the gitignored live config (no-op in CI).
# ---------------------------------------------------------------------------
echo "Case 5: knobs documented in pipeline.config.example"
inc
if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_AGENT_MEMORY_MAX=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_AGENT_MEMORY_MAX documented"
else
  fail_msg "example: PIPELINE_AGENT_MEMORY_MAX missing from pipeline.config.example"
fi
inc
if grep -Eq '^[[:space:]]*#?[[:space:]]*PIPELINE_AGENT_TASKS_MAX=' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_AGENT_TASKS_MAX documented"
else
  fail_msg "example: PIPELINE_AGENT_TASKS_MAX missing from pipeline.config.example"
fi
inc
if grep -Eq 'PIPELINE_AGENT_MEMORY_MAX=.*2G' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_AGENT_MEMORY_MAX default 2G visible"
else
  fail_msg "example: PIPELINE_AGENT_MEMORY_MAX default 2G not visible"
fi
inc
if grep -Eq 'PIPELINE_AGENT_TASKS_MAX=.*512' "$EXAMPLE"; then
  pass_msg "example: PIPELINE_AGENT_TASKS_MAX default 512 visible"
else
  fail_msg "example: PIPELINE_AGENT_TASKS_MAX default 512 not visible"
fi

# Dual-scan: live config (host-only) must not hardcode a conflicting cap form.
# No-op when absent in CI; presence-only sanity (knob value is operator choice).
if [ -f "$LIVE" ]; then
  inc
  # If the live config references the knobs at all, just assert it is parseable
  # (sourcing already happened via spawn-claude); this guard exists so a future
  # bad live edit (e.g. unquoted value) surfaces. We assert the file sources.
  if bash -n <(grep -E '^[[:space:]]*PIPELINE_AGENT_(MEMORY|TASKS)_MAX=' "$LIVE" 2>/dev/null) 2>/dev/null; then
    pass_msg "live: pipeline.config agent-cap knobs parse cleanly (or absent)"
  else
    fail_msg "live: pipeline.config agent-cap knob lines do not parse"
  fi
fi

echo ""
echo "================================"
echo "  $TESTS tests: PASS=$PASS FAIL=$FAIL"
echo "================================"
[ "$FAIL" -eq 0 ] || exit 1
