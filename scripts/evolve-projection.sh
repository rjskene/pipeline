#!/bin/bash
set -uo pipefail
#
# evolve-projection.sh — usage-gate projection helper (#1287).
#
# The `## Usage gate + projection` fence in skills/evolve/SKILL.md carried
# four awk field references (`$0`, `f[...]` fed by `split($0,...)`). The
# harness rewrites `$0`-`$9` when it loads a skill body, so those lines could
# never reach Bash intact (cycle-1 observed `awk '{sub(/\r$/,"",1281)}'` in
# the sibling pr-eval fence). The projection moved into this script, which the
# harness never rewrites — `$0`/`$1` are safe here — and the fence now keeps
# only `sed -nE` with `\1` backreferences.
#
# CLI: --tracker N [--gate-line "<usage-gate.sh line>"] [--comments-file PATH]
#      [--now ISO8601] [--help]
#
# Contract: prints EXACTLY one line, ALWAYS exits 0 (fail-open — a gate
# helper that aborts would wedge the evolve loop):
#   PROJECTION decision=<tok> est5=<n> est7=<n> five=<n|--> seven=<n|--> resume_at=<ISO8601|-->
#
# EST5/EST7 = median of the last three NON-NEGATIVE per-cycle deltas parsed
# out of the tracker's trusted `- usage:` comments; defaults 30 / 8 when none
# are usable (spec §5). `--comments-file` is a TEST-ONLY seam (local usage
# lines, no gh/network call) — `--tracker` stays the sole production route
# and always goes through filter-trusted-comments.sh. `--now` is a TEST-ONLY
# seam for a deterministic resume_at, mirroring the seam usage-gate.sh:72
# already exposes.
#
# Gate-line parse is percent-aware, matching the fence it replaces
# (skills/evolve/SKILL.md `## Usage gate + projection`, five_hour=
# ([0-9]+)(\.[0-9]+)?%) exactly: five_hour= / seven_day= capture the INTEGER
# part only (84.5% => 84), so the five+est5 / seven+est7 arithmetic never
# sees a non-integer. A `--` sentinel on either percentage, or on resume_at,
# round-trips as the literal `--` — an empty capture is re-emitted as `--` so
# the output always satisfies the PROJECTION grammar below.
#
# If decision=proceed and both percentages are present and either
# five+est5 or seven+est7 exceeds the threshold (default 85), the decision
# flips to pause-5h and resume_at becomes now + 5 hours (`+%FT%TZ`, `--now`
# when given). Any other decision (including one already halt-7d) passes
# through unchanged.

print_usage() {
  cat <<'USAGE'
Usage: evolve-projection.sh --tracker N [--gate-line LINE] [--comments-file PATH] [--now ISO8601] [--help]

  evolve-projection.sh — usage-gate projection helper (#1287).

  Computes EST5/EST7 from the last three usable per-cycle usage deltas and
  prints one PROJECTION line, folding in a proceed -> pause-5h flip when the
  projected utilization would exceed the gate threshold. ALWAYS exits 0.

  --tracker N          Tracker issue number (production route: reads trusted
                        comments via filter-trusted-comments.sh; requires
                        PIPELINE_REPO in the environment).
  --gate-line LINE     A pre-computed usage-gate.sh output line; when absent
                        the script runs usage-gate.sh itself.
  --comments-file PATH TEST-ONLY seam: read usage lines from a local file
                        instead of gh/filter-trusted-comments.sh.
  --now ISO8601        TEST-ONLY seam: injected clock for a deterministic
                        resume_at (mirrors usage-gate.sh --now).
  --help               Print this banner and exit 0.
USAGE
}

TRACKER=""
GATE_LINE=""
COMMENTS_FILE=""
NOW=""

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)          print_usage; exit 0 ;;
    --tracker)          TRACKER="${2:-}"; shift 2 ;;
    --tracker=*)        TRACKER="${1#--tracker=}"; shift ;;
    --gate-line)        GATE_LINE="${2:-}"; shift 2 ;;
    --gate-line=*)      GATE_LINE="${1#--gate-line=}"; shift ;;
    --comments-file)    COMMENTS_FILE="${2:-}"; shift 2 ;;
    --comments-file=*)  COMMENTS_FILE="${1#--comments-file=}"; shift ;;
    --now)              NOW="${2:-}"; shift 2 ;;
    --now=*)            NOW="${1#--now=}"; shift ;;
    *)
      echo "evolve-projection: WARN: unknown arg: $1 (ignored)" >&2
      shift
      ;;
  esac
done

SELF_DIR="$(dirname "$0")"
NOW="${NOW:-$(date -u +%FT%TZ 2>/dev/null || true)}"

# --- 1. resolve the gate line (default: run usage-gate.sh itself) ----------
if [ -z "$GATE_LINE" ]; then
  GATE_LINE="$(bash "$SELF_DIR/usage-gate.sh" 2>/dev/null || true)"
fi

# --- 2. read usage lines. --comments-file is TEST-ONLY; --tracker is the
#        sole production route (always through filter-trusted-comments.sh) --
if [ -n "$COMMENTS_FILE" ]; then
  COMMENTS="$(cat "$COMMENTS_FILE" 2>/dev/null || true)"
elif [ -n "$TRACKER" ]; then
  COMMENTS="$(bash "$SELF_DIR/filter-trusted-comments.sh" "$TRACKER" 2>/dev/null || true)"
else
  COMMENTS=""
fi

# --- 3. deltas: last 3 non-negative (d5,d7) rows, verbatim from the
#        replaced fence's awk program ------------------------------------
DELTAS="$(printf '%s\n' "$COMMENTS" \
  | awk '/^- usage: start five_hour=/{gsub(/[a-z_]+=/,""); split($0,f," "); d5=f[7]-f[4]; d7=f[8]-f[5]; if(d5>=0&&d7>=0) print d5, d7}' 2>/dev/null \
  | tail -3 || true)"

MED='{v[NR]=$0} END{if(NR==0)print d; else if(NR%2)print v[(NR+1)/2]; else print int((v[NR/2]+v[NR/2+1]+1)/2)}'
EST5="$(awk 'NF{split($0,f," "); print f[1]}' <<<"$DELTAS" | sort -n | awk -v d=30 "$MED" 2>/dev/null || true)"
EST7="$(awk 'NF{split($0,f," "); print f[2]}' <<<"$DELTAS" | sort -n | awk -v d=8 "$MED" 2>/dev/null || true)"
EST5="${EST5:-30}"
EST7="${EST7:-8}"

# --- 4. gate-line parse: percent-aware, group 1 (integer part) only; a `--`
#        sentinel (no digits/no `%`) leaves the capture empty --------------
DECISION="$(sed -nE 's/.*decision=([a-z0-9-]+).*/\1/p' <<<"$GATE_LINE")"
FIVE="$(sed -nE 's/.*five_hour=([0-9]+)(\.[0-9]+)?%.*/\1/p' <<<"$GATE_LINE")"
SEVEN="$(sed -nE 's/.*seven_day=([0-9]+)(\.[0-9]+)?%.*/\1/p' <<<"$GATE_LINE")"
THRESH="$(sed -nE 's/.*threshold=([0-9]+).*/\1/p' <<<"$GATE_LINE")"
THRESH="${THRESH:-85}"
RESUME_AT="$(sed -nE 's/.*resume_at=([^ ]+).*/\1/p' <<<"$GATE_LINE")"

# --- 5. proceed -> pause-5h flip; every other decision passes through -----
if [ "$DECISION" = proceed ] && [ -n "$FIVE" ] && [ -n "$SEVEN" ] \
  && { [ $((FIVE + EST5)) -gt "$THRESH" ] || [ $((SEVEN + EST7)) -gt "$THRESH" ]; }; then
  DECISION=pause-5h
  RESUME_AT="$(date -u -d "$NOW + 5 hours" +%FT%TZ 2>/dev/null || true)"
fi

echo "PROJECTION decision=${DECISION:---} est5=${EST5} est7=${EST7} five=${FIVE:---} seven=${SEVEN:---} resume_at=${RESUME_AT:---}"
exit 0
