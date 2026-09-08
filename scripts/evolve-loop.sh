#!/bin/bash
set -uo pipefail
#
# evolve-loop.sh — session-per-cycle wrapper for /pipeline:evolve (issue #1303,
# tracker #1271).
#
# Claude Code loads a plugin's skill bodies, agent definitions and hook
# manifest ONCE per session and never re-reads them, so a harness fix merged
# mid-loop is invisible until the operator exits and relaunches. A loop that
# needs a human restart per cycle is not a loop. `claude -p` loads plugins
# fresh per PROCESS, so this wrapper runs ONE fresh headless session per cycle
# and every merge lands in the very next cycle.
#
# Per iteration:
#   1. read the tracker `## Mode` line + labels (`--json body` / `--json
#      labels` only — never `--json comments`); the `paused` label is the
#      operator kill switch.
#   2. run the usage gate, fold it through scripts/evolve-projection.sh, and
#      branch on the PROJECTION line (the projection, not the raw gate line,
#      is the decision source — it flips proceed -> pause-5h on projected
#      spend).
#   3. launch `claude -p "/pipeline:evolve start --cycles 1"` (Mode `step
#      done`) or `"/pipeline:evolve resume"` (mid-cycle), tee'd to its own
#      per-launch log under .claude/scratch/evolve-loop/.
#   4. classify the exit from THAT launch's log: a headless usage-pause exit
#      is slept out and relaunched; `step done` counts a cycle; anything else
#      is an unexplained stall.
#
# Exit codes / the `LOOP-STOP reason=` contract:
#
#   | rc | emitted as                             | when                                                      |
#   |----|----------------------------------------|-----------------------------------------------------------|
#   | 0  | LOOP-STOP reason=paused                | tracker carries the `paused` label (operator kill switch)  |
#   | 0  | LOOP-STOP reason=cycles-complete cycles=<n> | --cycles N satisfied                                  |
#   | 2  | usage message                          | bad/missing flag value, unknown arg                        |
#   | 3  | LOOP-STOP reason=halt-7d seven=<n> resume_at=<v> | projection says halt-7d                          |
#   | 4  | LOOP-STOP reason=resume-cap cycle=<N> step=<STEP> | consecutive unexplained stalls > --max-resumes   |
#   | 5  | LOOP-STOP reason=pause-cap pauses=<n> cycle=<N>   | consecutive headless usage-pause exits > --max-pauses |
#
# EVERY external call goes through the single dispatch() seam below, which
# --dry-run replaces with a printf preview. That is what makes
# tests/test-evolve-loop.sh hermetic and what makes --dry-run cost nothing.
# The preview goes to STDERR (the one deliberate divergence from
# scripts/calibration-run.sh, whose previews are stdout-only): the reads here
# are captured with $( ) / >file, so a stdout preview would corrupt them.
#
# Test-only env seams (not user knobs, mirroring calibration-run.sh's
# CALIB_TEST_*): EVOLVE_LOOP_USAGE_GATE, EVOLVE_LOOP_PROJECTION,
# EVOLVE_LOOP_SLEEP_CMD. Both helpers are invoked by ABSOLUTE PATH, which a
# PATH shim cannot intercept, hence the seams.
#
# Usage:
#   bash scripts/evolve-loop.sh --cycles 3
#   bash scripts/evolve-loop.sh --dry-run
#

print_usage() {
  cat <<'USAGE'
Usage: scripts/evolve-loop.sh [--cycles N] [--tracker N] [--model M]
                              [--max-resumes K] [--max-pauses K]
                              [--timeout SECS] [--dry-run] [--help]

Runs the harness-evolve loop as ONE FRESH `claude -p` session per cycle, so a
skill/agent/hook change merged during the loop is loaded by the next cycle
instead of waiting for an operator restart. Run from the clone root.

Options:
  --cycles N        Cycles to complete before stopping (default 0 = unbounded).
  --tracker N       Tracker issue number (default 1271).
  --model M         Model for the headless session (default: account default).
  --max-resumes K   consecutive unexplained stalls before LOOP-STOP reason=resume-cap (default 2, rc 4)
  --max-pauses K    consecutive headless usage-pause exits before LOOP-STOP reason=pause-cap (default 6 ~ 30 h, rc 5)
  --timeout SECS    Per-session cap handed to `timeout` (default 10800).
  --dry-run         Print the LOOP-LAUNCH preview and exit. No network call,
                    no claude launch, no sleep.
  --help            Print this banner and exit 0.

Exit codes: 0 paused / cycles-complete · 2 invalid arguments · 3 halt-7d
            · 4 resume-cap · 5 pause-cap.
USAGE
}

die_usage() { echo "evolve-loop: ERROR: $1" >&2; exit 2; }
warn()      { echo "evolve-loop: WARN: $1" >&2; }

# require_value "$@" — guards every `shift 2`. Without it a value-taking flag
# in LAST position leaves `"$2"` unbound, so `set -u` aborts the parser with
# rc 1 and no message naming the offending flag. The guard upgrades that to a
# clean rc 2 usage error that says which flag is missing its value.
require_value() { [ $# -ge 2 ] || die_usage "$1 requires a value"; }

require_num() { # <flag> <value>
  case "${2:-}" in
    ''|*[!0-9]*) die_usage "$1 must be a non-negative integer (got: ${2:-<empty>})" ;;
  esac
}

CYCLES=0
TRACKER=""
MODEL=""
MAX_RESUMES=2
MAX_PAUSES=6
LOOP_TIMEOUT=10800
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)        print_usage; exit 0 ;;
    --dry-run)        DRY=1; shift ;;
    --cycles)         require_value "$@"; CYCLES="$2"; shift 2 ;;
    --cycles=*)       CYCLES="${1#--cycles=}"; shift ;;
    --tracker)        require_value "$@"; TRACKER="$2"; shift 2 ;;
    --tracker=*)      TRACKER="${1#--tracker=}"; shift ;;
    --model)          require_value "$@"; MODEL="$2"; shift 2 ;;
    --model=*)        MODEL="${1#--model=}"; shift ;;
    --max-resumes)    require_value "$@"; MAX_RESUMES="$2"; shift 2 ;;
    --max-resumes=*)  MAX_RESUMES="${1#--max-resumes=}"; shift ;;
    --max-pauses)     require_value "$@"; MAX_PAUSES="$2"; shift 2 ;;
    --max-pauses=*)   MAX_PAUSES="${1#--max-pauses=}"; shift ;;
    --timeout)        require_value "$@"; LOOP_TIMEOUT="$2"; shift 2 ;;
    --timeout=*)      LOOP_TIMEOUT="${1#--timeout=}"; shift ;;
    *)                die_usage "unknown arg: $1" ;;
  esac
done

require_num --cycles "$CYCLES"
require_num --max-resumes "$MAX_RESUMES"
require_num --max-pauses "$MAX_PAUSES"
require_num --timeout "$LOOP_TIMEOUT"
[ -n "$TRACKER" ] && require_num --tracker "$TRACKER"

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLONE="$(cd "$SCRIPT_DIR/.." && pwd)"

# Best-effort: production runs from the clone root, where pipeline.config
# carries PIPELINE_REPO. An exported value survives when no config is present,
# which is what keeps the test suite hermetic.
# shellcheck disable=SC1091
source "$(pwd)/pipeline.config" 2>/dev/null || true
PIPELINE_REPO="${PIPELINE_REPO:-}"
[ -n "$PIPELINE_REPO" ] || warn "PIPELINE_REPO is unset — gh reads will fail"

TRACKER="${TRACKER:-1271}"
LOG_DIR="$(pwd)/.claude/scratch/evolve-loop"
mkdir -p "$LOG_DIR" 2>/dev/null || true
BODY_FILE="$LOG_DIR/tracker-body.md"

# The stub dispatch() returns for the tracker body under --dry-run: a canned
# `## Mode` block, so the dry preview shows the `start` command shape.
DRY_BODY_STUB='## Mode

`active` — cycle 0 · step done · issues none · updated --'
DRY_GATE_STUB='usage-gate: decision=skip reason=dry-run five_hour=--% seven_day=--% threshold=85 resume_at=--'
DRY_PROJ_STUB='PROJECTION decision=proceed est5=30 est7=8 five=-- seven=-- resume_at=--'

MODE_LINE=""
MODE_OK=1
N=0
STEP=done
NEXT_N=1
LAUNCH=()

# ---------------------------------------------------------------------------
# dispatch() — THE single external-call seam
# ---------------------------------------------------------------------------
# dispatch <label> <dry-stdout-stub> <cmd...>
dispatch() {
  local label="$1" stub="$2"
  shift 2
  if [ "$DRY" -eq 1 ]; then
    printf '%s cwd=%s %s\n' "$label" "$(pwd)" "$*" >&2
    if [ -n "$stub" ]; then printf '%s\n' "$stub"; fi
    return 0
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Tracker reads — `--json labels` / `--json body` ONLY, never `--json comments`
# ---------------------------------------------------------------------------

# Both reads FAIL CLOSED: the rc is captured and a failure never masquerades
# as a successful read. Discarding it is what turns a gh outage into an
# unbounded relaunch loop of real `claude -p` sessions — an empty labels list
# reads as "not paused" (the kill switch silently disabled) and a bodyless
# tracker parses as `cycle 0 / step done`, which classifies as a phantom
# COMPLETED cycle and resets every counter, so no cap can ever fire.
read_labels() {
  dispatch LOOP-READ "" \
    gh issue view "$TRACKER" --repo "$PIPELINE_REPO" --json labels --jq '.labels[].name'
}

# Parses the Mode line with the SAME idioms skills/evolve/SKILL.md
# `## Durable state` uses, so the wrapper and the skill can never disagree
# about what step the loop is on. Returns non-zero (and leaves MODE_OK=0) when
# the read failed or the body carried no `## Mode` line; N/STEP/NEXT_N are then
# left untouched rather than defaulted to a fiction.
read_mode() {
  local tmp rc
  tmp="$BODY_FILE.new"
  dispatch LOOP-READ "$DRY_BODY_STUB" \
    gh issue view "$TRACKER" --repo "$PIPELINE_REPO" --json body --jq .body > "$tmp"
  rc=$?
  MODE_LINE=""
  if [ "$rc" -eq 0 ]; then
    MODE_LINE=$(awk '/^## Mode/{f=1;next} f&&/^`/{print;exit}' "$tmp" 2>/dev/null)
  fi
  if [ "$rc" -ne 0 ] || [ -z "$MODE_LINE" ]; then
    MODE_OK=0
    rm -f "$tmp"
    warn "tracker body read failed or carried no \`## Mode\` line (rc=$rc) — treating this iteration as a stall, not a completed cycle"
    return 1
  fi
  MODE_OK=1
  mv -f "$tmp" "$BODY_FILE" 2>/dev/null || true
  N=$(sed -nE 's/.*cycle ([0-9]+).*/\1/p' <<<"$MODE_LINE"); N=${N:-0}
  STEP=$(sed -nE 's/.*step ([0-9]+|done).*/\1/p' <<<"$MODE_LINE"); STEP=${STEP:-done}
  if [ "$STEP" = done ]; then NEXT_N=$((N + 1)); else NEXT_N=$N; fi
  return 0
}

# charge_resume <reason> — a read that failed cannot be launched past; charge
# it against --max-resumes so the failure is bounded exactly like a stall.
charge_resume() {
  RESUMES=$((RESUMES + 1))
  if [ "$RESUMES" -gt "$MAX_RESUMES" ]; then
    echo "LOOP-STOP reason=resume-cap cycle=$N step=$STEP"
    exit 4
  fi
}

# ---------------------------------------------------------------------------
# Launch shape — mirrors scripts/calibration-run.sh's headless launch.
# ---------------------------------------------------------------------------
# `-u ALLOW_ORCHESTRATOR_EDIT`: the loop session that drives this script
# exports it, and inheriting it would disable the PATH C delegation hook inside
# the cycle being run. CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 makes print mode
# wait indefinitely on dispatched background agents; the default 600 s ceiling
# terminates a headless orchestrator ~10 minutes into its first evaluator
# dispatch (#1306).
build_launch() {
  local cmd
  if [ "$STEP" = done ]; then
    cmd="/pipeline:evolve start --cycles 1"
  else
    cmd="/pipeline:evolve resume"
  fi
  LAUNCH=(env -u ALLOW_ORCHESTRATOR_EDIT "CLAUDE_PLUGIN_ROOT=$CLONE"
          PIPELINE_HEADLESS=true CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0
          timeout "$LOOP_TIMEOUT"
          claude -p "$cmd" --plugin-dir "$CLONE")
  if [ -n "$MODEL" ]; then LAUNCH+=(--model "$MODEL"); fi
  LAUNCH+=(--dangerously-skip-permissions)
}

# ---------------------------------------------------------------------------
# Usage gate — the PROJECTION line is the decision source
# ---------------------------------------------------------------------------
# scripts/evolve-projection.sh flips `proceed` -> `pause-5h` when the PROJECTED
# spend (five+est5 / seven+est7) would cross the threshold, and the skill
# decides on that flipped line. A wrapper deciding on the raw usage-gate line
# would launch straight into a projected pause and burn its budget in minutes.
#
# Returns 0 to proceed, 1 to skip this iteration (gate pause: sleep, re-read
# the `paused` label, re-check). halt-7d exits 3 from here.
check_gate() {
  local gate_line proj
  gate_line="$(dispatch LOOP-READ "$DRY_GATE_STUB" \
    bash "${EVOLVE_LOOP_USAGE_GATE:-$CLONE/scripts/usage-gate.sh}")"
  echo "$gate_line"
  proj="$(dispatch LOOP-READ "$DRY_PROJ_STUB" \
    env PIPELINE_REPO="$PIPELINE_REPO" \
    bash "${EVOLVE_LOOP_PROJECTION:-$CLONE/scripts/evolve-projection.sh}" \
    --tracker "$TRACKER" --gate-line "$gate_line")"
  echo "$proj"

  DECISION=$(sed -nE 's/.*decision=([a-z0-9-]+).*/\1/p' <<<"$proj")
  RESUME_AT=$(sed -nE 's/.*resume_at=([^ ]+).*/\1/p' <<<"$proj")
  SEVEN=$(sed -nE 's/.* seven=([^ ]+).*/\1/p' <<<"$proj")

  case "$DECISION" in
    halt-7d)
      echo "LOOP-STOP reason=halt-7d seven=${SEVEN:---} resume_at=${RESUME_AT:---}"
      echo "evolve-loop: run \`/usage\` for the seven-day reset date; resume with /pipeline:evolve resume"
      exit 3
      ;;
    pause-5h)
      # Launches NOTHING: costs wall-clock only, has no rc of its own, and
      # self-heals when the five-hour window resets. The `paused` label is
      # re-read at the top of every iteration, so the kill switch still works.
      sleep_until_resume "$RESUME_AT" gate
      return 1
      ;;
  esac
  return 0
}

# sleep_until_resume <resume_at> <reason> — clamped BOTH ways, so a malformed
# or far-future resume_at can never hang the wrapper.
sleep_until_resume() {
  local resume_at="${1:---}" reason="$2" secs="" target now
  if [ -n "$resume_at" ] && [ "$resume_at" != "--" ]; then
    target="$(date -u -d "$resume_at" +%s 2>/dev/null)"
    now="$(date -u +%s)"
    if [ -n "$target" ]; then secs=$((target + 300 - now)); fi
  fi
  [ -n "$secs" ] || secs=300
  [ "$secs" -lt 60 ] && secs=60
  [ "$secs" -gt 21600 ] && secs=21600
  echo "LOOP-PAUSE reason=$reason resume_at=$resume_at secs=$secs"
  "${EVOLVE_LOOP_SLEEP_CMD:-sleep}" "$secs"
}

# classify_exit — the ONLY read site for the skill's headless usage-pause
# token. It reads "$LOG" and nothing else, and "$LOG" holds EXACTLY the
# current launch's output (see the LAUNCH_SEQ note below), so a pause token
# from a PREVIOUS launch can never be re-matched.
classify_exit() {
  local pause_line
  pause_line="$(grep -F 'HEADLESS-DEFAULT: usage-pause decision=exit-for-wrapper' "$LOG" 2>/dev/null | tail -1)"
  if [ -n "$pause_line" ]; then
    # `tail -1` makes this parse single-valued by construction, so
    # `date -u -d` is never handed a multi-line value.
    RESUME_AT=$(sed -nE 's/.*resume_at=([^ ]+).*/\1/p' <<<"$pause_line")
    CLASS=pause
    return 0
  fi
  read_mode
  if [ "$MODE_OK" -eq 1 ] && [ "$STEP" = done ]; then CLASS=done; else CLASS=stalled; fi
}

# ---------------------------------------------------------------------------
# Loop
# ---------------------------------------------------------------------------

DECISION=""
RESUME_AT=""
SEVEN=""
CLASS=""
CYCLES_DONE=0
RESUMES=0
PAUSES=0
PENDING_RESUME=0
LAUNCH_SEQ=0
ATTEMPT=0
LOG=""

while :; do
  LABELS="$(read_labels)"
  LABELS_RC=$?
  if [ "$LABELS_RC" -ne 0 ]; then
    warn "tracker labels read failed (rc=$LABELS_RC) — not launching: the \`paused\` kill switch must be readable"
    charge_resume
    continue
  fi
  if grep -qx paused <<<"$LABELS"; then
    echo "LOOP-STOP reason=paused"
    exit 0
  fi

  read_mode || { charge_resume; continue; }
  check_gate || continue

  # A stall is CASHED here, after the gate returned proceed: a stall the gate
  # then explains as a usage pause never consumes a resume.
  if [ "$PENDING_RESUME" -eq 1 ]; then
    PENDING_RESUME=0
    RESUMES=$((RESUMES + 1))
    if [ "$RESUMES" -gt "$MAX_RESUMES" ]; then
      echo "LOOP-STOP reason=resume-cap cycle=$N step=$STEP"
      exit 4
    fi
  fi

  build_launch

  # ONE LOG FILE PER LAUNCH. LAUNCH_SEQ is monotonic for the life of the
  # process and is NEVER reset by any classification, so it is the only
  # component of the name guaranteed to change between two launches: `pause`
  # advances neither NEXT_N (Mode is untouched) nor ATTEMPT (only `stalled`
  # increments, only `done` resets), and two consecutive `done` iterations
  # move neither either. With an invariant name and `tee -a`, classify_exit()
  # would grep an ACCUMULATED file and re-match the previous launch's pause
  # token forever. NEXT_N/ATTEMPT stay in the name for diagnostics.
  LAUNCH_SEQ=$((LAUNCH_SEQ + 1))
  LOG="$LOG_DIR/cycle-$(printf '%02d' "$NEXT_N")-$ATTEMPT-$LAUNCH_SEQ.log"
  dispatch LOOP-LAUNCH "" "${LAUNCH[@]}" 2>&1 | tee "$LOG"

  # --dry-run is TERMINAL: a dry loop whose launch is a printf can never
  # observe a Mode transition, so iterating would spin forever.
  if [ "$DRY" -eq 1 ]; then exit 0; fi

  classify_exit
  case "$CLASS" in
    pause)
      # Neither a cycle nor a resume is consumed — that is the case this
      # wrapper exists to survive — but the branch IS bounded: K consecutive
      # pauses is the ceiling, K+1 launches in the pathological case. Both
      # resets below are what make the cap CONSECUTIVE, not cumulative.
      PAUSES=$((PAUSES + 1))
      if [ "$PAUSES" -gt "$MAX_PAUSES" ]; then
        echo "LOOP-STOP reason=pause-cap pauses=$PAUSES cycle=$N"
        exit 5
      fi
      sleep_until_resume "$RESUME_AT" headless-exit
      continue
      ;;
    done)
      CYCLES_DONE=$((CYCLES_DONE + 1))
      RESUMES=0
      ATTEMPT=0
      PAUSES=0
      if [ "$CYCLES" -gt 0 ] && [ "$CYCLES_DONE" -ge "$CYCLES" ]; then
        echo "LOOP-STOP reason=cycles-complete cycles=$CYCLES_DONE"
        exit 0
      fi
      continue
      ;;
    *)
      PAUSES=0
      PENDING_RESUME=1
      ATTEMPT=$((ATTEMPT + 1))
      continue
      ;;
  esac
done
