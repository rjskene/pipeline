#!/bin/bash
set -uo pipefail
#
# run-retro.sh — per-cycle evolve-loop retro (issue #1272, tracker #1271,
# spec docs/superpowers/specs/2026-09-05-harness-evolve-loop-design.md §4/§7).
#
# Recomputes the #1271 scorecard baseline against the current cycle's
# issues/PRs, renders deltas against the previous retro, harvests operator
# friction signals (denials, HARNESS-FRICTION comments, escapes), gate yield,
# and lists pending / next-cycle verdict candidates.
#
# Usage:
#   bash scripts/run-retro.sh --cycle N [options]         # live (calls gh)
#   bash scripts/run-retro.sh --cycle N --fixture DIR     # fixture mode
#   bash scripts/run-retro.sh --cycle N --post            # post-run mode
#   bash scripts/run-retro.sh --cycle N --write PATH      # full report to PATH
#   bash scripts/run-retro.sh --help
#
# Degradation contract: every row is produced by a helper that renders
# `n/a (<reason>)` on missing substrate rather than failing. `set -uo
# pipefail` (no -e). Exit non-zero ONLY on invalid args (unknown flag,
# missing --cycle, non-integer --cycle).
#
# Fixture seam (`--fixture DIR`) mirrors cost-latency-report.sh --fixture:
# reads tracker.md, rows.json, tool-use.log, usage-gate.jsonl, cycle-<NN>.md,
# issues.json, prs.json from DIR instead of calling gh/git/cost-latency-report.sh.
# See tests/fixtures/run-retro/README.md for the substrate contract.

print_usage() {
  cat <<'USAGE'
Usage: scripts/run-retro.sh --cycle N [options]

Per-cycle evolve-loop retro: recomputes the #1271 scorecard baseline against
this cycle's issues/PRs, renders deltas against the previous retro, harvests
operator-friction signals, and lists pending / next-cycle verdict candidates.

Options:
  --cycle N        Cycle number to report on (required, non-negative integer).
  --post           Post-run mode: harness-mass + friction rows +
                    verdict-candidates only (no cost/latency rows, no deltas,
                    no filesystem writes).
  --tracker NNNN   Tracker issue number (default: 1271).
  --since DATE     ISO-8601 date; bounds the friction / denial window.
  --write PATH     Write the full (untruncated) report to PATH (creates
                    parent directories). stdout stays bounded to 1..60 lines
                    regardless.
  --fixture DIR    Read tracker.md / rows.json / tool-use.log /
                    usage-gate.jsonl / cycle-<NN>.md / issues.json / prs.json
                    from DIR instead of calling gh / git / cost-latency-report.sh.
  --limit N        PR window size passed through to cost-latency-report.sh
                    in live mode (default 50).
  --dump-baseline  Debug: emit only `BASELINE <row>/<label> = <value>` lines.
  --dump-computed  Debug: emit only `COMPUTED <row>/<label> = <value>` lines.
  --help           Print this banner and exit 0.
USAGE
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

CYCLE=""
POST=0
TRACKER="1271"
SINCE=""
WRITE_PATH=""
FIXTURE_DIR=""
LIMIT=50
DUMP_BASELINE=0
DUMP_COMPUTED=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)        print_usage; exit 0 ;;
    --cycle)          CYCLE="${2:-}"; shift 2 ;;
    --cycle=*)        CYCLE="${1#--cycle=}"; shift ;;
    --post)           POST=1; shift ;;
    --tracker)        TRACKER="${2:-}"; shift 2 ;;
    --tracker=*)      TRACKER="${1#--tracker=}"; shift ;;
    --since)          SINCE="${2:-}"; shift 2 ;;
    --since=*)        SINCE="${1#--since=}"; shift ;;
    --write)          WRITE_PATH="${2:-}"; shift 2 ;;
    --write=*)        WRITE_PATH="${1#--write=}"; shift ;;
    --fixture)        FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*)      FIXTURE_DIR="${1#--fixture=}"; shift ;;
    --limit)          LIMIT="${2:-}"; shift 2 ;;
    --limit=*)        LIMIT="${1#--limit=}"; shift ;;
    --dump-baseline)  DUMP_BASELINE=1; shift ;;
    --dump-computed)  DUMP_COMPUTED=1; shift ;;
    *)
      echo "run-retro: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$CYCLE" ]; then
  echo "run-retro: ERROR: --cycle is required" >&2
  exit 1
fi
if ! [[ "$CYCLE" =~ ^[0-9]+$ ]]; then
  echo "run-retro: ERROR: --cycle must be a non-negative integer (got: $CYCLE)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Small string helpers
# ---------------------------------------------------------------------------

norm_ws() { printf '%s' "$1" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }

split_atoms() { printf '%s\n' "$1" | sed -E 's/ · /\n/g; s/, /\n/g; s/ \/ /\n/g'; }

last_atom() { split_atoms "$(norm_ws "$1")" | tail -1; }

norm_row() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/[[:space:]]*\([^()]*\)[[:space:]]*$//')"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  norm_ws "$s"
}

is_numeric() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

clean_num() { awk -v v="$1" 'BEGIN{ if (v==int(v)) printf "%d", v; else printf "%s", v }'; }

ids_json() {
  local list="$1" out="[" first=1 n
  for n in $list; do
    if [ "$first" -eq 1 ]; then out="$out$n"; first=0; else out="$out,$n"; fi
  done
  printf '%s]' "$out"
}

# parse_atom <atom text> -> sets ATOM_VALUE / ATOM_UNIT / ATOM_LABEL
# (ATOM_VALUE empty means "no numeric token found; atom dropped")
ATOM_VALUE=""; ATOM_UNIT=""; ATOM_LABEL=""
parse_atom() {
  local atom dollar digits suffix matched num mult unit val label
  atom="$(norm_ws "$1")"
  ATOM_VALUE=""; ATOM_UNIT=""; ATOM_LABEL=""
  if [[ "$atom" =~ (≈)?(\$)?([0-9][0-9,.]*)([kKM%]?) ]]; then
    dollar="${BASH_REMATCH[2]}"
    digits="${BASH_REMATCH[3]}"
    suffix="${BASH_REMATCH[4]}"
    matched="${BASH_REMATCH[0]}"
    num="${digits//,/}"
    mult=1
    unit=""
    case "$suffix" in
      k|K) mult=1000 ;;
      M)   mult=1000000 ;;
      %)   unit="%" ;;
    esac
    if [ -n "$dollar" ]; then unit='$'; fi
    val="$(awk -v n="$num" -v m="$mult" 'BEGIN{v=n*m; if (v==int(v)) printf "%d", v; else printf "%s", v}')"
    label="${atom/$matched/}"
    label="$(printf '%s' "$label" | tr -d '`' | tr '[:upper:]' '[:lower:]')"
    label="$(norm_ws "$label")"
    if [ -z "$label" ]; then
      case "$unit" in
        '$') label="usd" ;;
        '%') label="pct" ;;
        *)   label="value" ;;
      esac
    fi
    ATOM_VALUE="$val"
    ATOM_UNIT="$unit"
    ATOM_LABEL="$label"
  fi
}

# ---------------------------------------------------------------------------
# Baseline table parsing + sub-metric decomposition (Task 2)
# ---------------------------------------------------------------------------

declare -a ROW_NAMES=()
declare -a ROW_CELLS=()
TABLE_FOUND=0

parse_baseline_table() {
  local body="$1" line in_table=0 name cell
  ROW_NAMES=(); ROW_CELLS=(); TABLE_FOUND=0
  while IFS= read -r line; do
    if [ "$in_table" -eq 0 ]; then
      if [[ "$line" == "## Scorecard baseline"* ]]; then
        in_table=1
        TABLE_FOUND=1
      fi
      continue
    fi
    if [[ "$line" == "## "* ]]; then
      break
    fi
    if [[ "$line" != "|"*"|"* ]]; then
      continue
    fi
    if [[ "$line" == *"Signal"*"Baseline"* ]]; then
      continue
    fi
    if [[ "$line" =~ ^\|[-[:space:]|]+\|$ ]]; then
      continue
    fi
    name="$(printf '%s' "$line" | awk -F'|' '{print $2}')"
    cell="$(printf '%s' "$line" | awk -F'|' '{print $3}')"
    name="$(norm_ws "$name")"
    cell="$(norm_ws "$cell")"
    ROW_NAMES+=("$name")
    ROW_CELLS+=("$cell")
  done <<< "$body"
}

declare -A BASE_VAL=()
declare -A BASE_UNIT=()

# decompose_cell <normalized row name> <raw cell text>
decompose_cell() {
  local row="$1" cell="$2" any_atom=0 work pre inner post preceding plabel key subatom atom
  work="$cell"
  while [[ "$work" == *"("* ]]; do
    if [[ "$work" =~ ^(.*)\(([^()]*)\)(.*)$ ]]; then
      pre="${BASH_REMATCH[1]}"
      inner="${BASH_REMATCH[2]}"
      post="${BASH_REMATCH[3]}"
    else
      break
    fi
    preceding="$(last_atom "$pre")"
    parse_atom "$preceding"
    plabel="$ATOM_LABEL"
    if [ -n "$ATOM_VALUE" ]; then
      while IFS= read -r subatom; do
        [ -z "$subatom" ] && continue
        parse_atom "$subatom"
        if [ -n "$ATOM_VALUE" ]; then
          key="$row/$plabel $ATOM_LABEL"
          BASE_VAL["$key"]="$ATOM_VALUE"
          BASE_UNIT["$key"]="$ATOM_UNIT"
          any_atom=1
        fi
      done < <(split_atoms "$(norm_ws "$inner")")
    fi
    work="$pre$post"
  done
  work="$(norm_ws "$work")"
  while IFS= read -r atom; do
    [ -z "$atom" ] && continue
    parse_atom "$atom"
    if [ -n "$ATOM_VALUE" ]; then
      key="$row/$ATOM_LABEL"
      BASE_VAL["$key"]="$ATOM_VALUE"
      BASE_UNIT["$key"]="$ATOM_UNIT"
      any_atom=1
    fi
  done < <(split_atoms "$work")
  if [ "$any_atom" -eq 0 ]; then
    BASE_VAL["$row"]="n/a (non-numeric baseline)"
    BASE_UNIT["$row"]=""
  fi
}

DECOMPOSE_ROWS="median path b pr|harness mass|prose-pinning tests|issue-number archaeology in skill bodies|doc/behaviour contradictions"

decompose_baseline_table() {
  local i nr
  for ((i = 0; i < ${#ROW_NAMES[@]}; i++)); do
    nr="$(norm_row "${ROW_NAMES[$i]}")"
    case "|$DECOMPOSE_ROWS|" in
      *"|$nr|"*) decompose_cell "$nr" "${ROW_CELLS[$i]}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Cycle-issues parse (Task 2)
# ---------------------------------------------------------------------------

parse_cycle_issues() {  # <body> <N> -> prints space-separated issue numbers
  local body="$1" n="$2" line collecting=0 found_n
  local -a nums=()
  while IFS= read -r line; do
    if [[ "$line" =~ ^Cycle\ ([0-9]+) ]]; then
      found_n="${BASH_REMATCH[1]}"
      if [ "$found_n" = "$n" ]; then
        collecting=1
      else
        if [ "$collecting" -eq 1 ]; then break; fi
        collecting=0
      fi
      continue
    fi
    if [ "$collecting" -eq 1 ]; then
      if [[ "$line" == "## "* ]]; then break; fi
      if [[ "$line" =~ ^-\ *#([0-9]+) ]]; then
        nums+=("${BASH_REMATCH[1]}")
      fi
    fi
  done <<< "$body"
  printf '%s' "${nums[*]:-}"
}

# ---------------------------------------------------------------------------
# File-path resolution (fixture seam vs live)
# ---------------------------------------------------------------------------

TRACKER_FILE=""
ISSUES_FILE=""
PRS_FILE=""
ROWS_FILE=""
TOOLOG=""
USAGE_FILE=""
CALIB_FILE=""

if [ -n "$FIXTURE_DIR" ]; then
  TRACKER_FILE="$FIXTURE_DIR/tracker.md"
  ISSUES_FILE="$FIXTURE_DIR/issues.json"
  PRS_FILE="$FIXTURE_DIR/prs.json"
  ROWS_FILE="$FIXTURE_DIR/rows.json"
  TOOLOG="$FIXTURE_DIR/tool-use.log"
  USAGE_FILE="$FIXTURE_DIR/usage-gate.jsonl"
  CALIB_FILE="$FIXTURE_DIR/calib.txt"
else
  LIVE_TMP="$(mktemp -d)"
  trap 'rm -rf "$LIVE_TMP"' EXIT
  if command -v gh >/dev/null 2>&1 && [ -n "${PIPELINE_REPO:-}" ]; then
    gh issue view "$TRACKER" --repo "$PIPELINE_REPO" --json body --jq .body \
      > "$LIVE_TMP/tracker.md" 2>/dev/null
    gh issue list --repo "$PIPELINE_REPO" --state all \
      --json number,labels,body,comments --limit 300 \
      > "$LIVE_TMP/issues.json" 2>/dev/null
    gh pr list --repo "$PIPELINE_REPO" --state merged \
      --json number,title,headRefName,body,mergedAt,labels,files --limit 300 \
      > "$LIVE_TMP/prs.json" 2>/dev/null
  fi
  ROWS_EXTRA_ARGS=()
  [ -n "$SINCE" ] && ROWS_EXTRA_ARGS+=(--since "$SINCE")
  if [ -x "$REPO_ROOT/scripts/cost-latency-report.sh" ]; then
    bash "$REPO_ROOT/scripts/cost-latency-report.sh" --emit-rows-json \
      --limit "$LIMIT" "${ROWS_EXTRA_ARGS[@]}" > "$LIVE_TMP/rows.json" 2>/dev/null
  fi
  TRACKER_FILE="$LIVE_TMP/tracker.md"
  ISSUES_FILE="$LIVE_TMP/issues.json"
  PRS_FILE="$LIVE_TMP/prs.json"
  ROWS_FILE="$LIVE_TMP/rows.json"
  TOOLOG="$REPO_ROOT/.claude/logs/tool-use.log"
  USAGE_FILE="$REPO_ROOT/.claude/logs/usage-gate.jsonl"
  # Newest calibration block tee'd by scripts/calibration-run.sh --run (#1280).
  CALIB_FILE="$(ls -1t "$REPO_ROOT"/docs/retros/calib/*.txt 2>/dev/null | head -1)"
fi

TRACKER_BODY=""
if [ -f "$TRACKER_FILE" ]; then
  TRACKER_BODY="$(cat "$TRACKER_FILE" 2>/dev/null)"
fi

parse_baseline_table "$TRACKER_BODY"
decompose_baseline_table
if [ "$TABLE_FOUND" -ne 1 ]; then
  BASE_VAL["tracker"]="n/a (tracker body unreadable)"
  BASE_UNIT["tracker"]=""
fi

CUR_ISSUES="$(parse_cycle_issues "$TRACKER_BODY" "$CYCLE")"
CUR_IDS_JSON="$(ids_json "$CUR_ISSUES")"

PREV_ISSUES=""
if [ "$CYCLE" -gt 0 ]; then
  PREV_ISSUES="$(parse_cycle_issues "$TRACKER_BODY" $((CYCLE - 1)))"
fi
PREV_IDS_JSON="$(ids_json "$PREV_ISSUES")"

# ---------------------------------------------------------------------------
# Task 3 — cost / latency rows scoped to the cycle's issues
# ---------------------------------------------------------------------------

declare -A JOIN_COMP_VAL=()
declare -A JOIN_COMP_UNIT=()
declare -A EXTRA_COMP_VAL=()
declare -A EXTRA_COMP_UNIT=()

MISSING_ROW_ISSUES=""

# Task 3a — calibration slate (#1280, spec §8)
#
# scripts/calibration-run.sh --run tees a block of
#   CALIB issue=<n> path=<X> cost=$<usd> wall=<s> verdicts=<a/b> reftest=<pass|fail> unexpected-files=<n>
#   CALIB-TOTAL cost=$<usd> wall=<s> issues=<n> reftest-pass=<n>/<n>
# to docs/retros/calib/<UTC date>.txt. Two retro rows read it: the weak-model
# guarantee (a k/n over the `reftest=` atoms) and the path-B $ median (over the
# `cost=` atoms of the `path=B` rows only — the fixed slate is the ONLY place
# this harness has a per-issue dollar figure, since the rows JSON carries none).
# Degradation contract: a missing / CALIB-row-free file leaves both reasons
# exactly as they render with no calibration substrate at all.
CALIB_WEAK="n/a (no calibration slate; spec §8 cycle-1 deliverable)"
CALIB_USD="n/a (no per-issue cost in rows JSON)"

compute_calib() {
  local f="${1:-}"
  [ -n "$f" ] || return 0
  [ -f "$f" ] || return 0

  local line atom pass=0 total=0 path="" cost="" b_costs=""
  while IFS= read -r line; do
    case "$line" in
      "CALIB issue="*) ;;
      *) continue ;;
    esac
    path=""; cost=""
    for atom in $line; do
      case "$atom" in
        path=*)    path="${atom#path=}" ;;
        cost=*)    cost="${atom#cost=}"; cost="${cost#\$}" ;;
        reftest=*)
          total=$((total + 1))
          [ "${atom#reftest=}" = "pass" ] && pass=$((pass + 1))
          ;;
      esac
    done
    case "$path" in
      B|b) is_numeric "$cost" && b_costs="$b_costs $cost" ;;
    esac
  done < "$f"

  [ "$total" -gt 0 ] && CALIB_WEAK="$pass/$total"

  if [ -n "$b_costs" ]; then
    local med
    med="$(printf '%s\n' $b_costs | sort -n | awk '
      { v[NR] = $1 }
      END {
        if (NR == 0) exit 1
        if (NR % 2) printf "%.2f", v[(NR + 1) / 2]
        else printf "%.2f", (v[NR / 2] + v[NR / 2 + 1]) / 2
      }')"
    if is_numeric "$med"; then CALIB_USD="$(clean_num "$med")"; fi
  fi
}

compute_calib "$CALIB_FILE"

compute_cost_latency() {
  local rows_file="$1"
  local no_substrate="n/a (no rows substrate)"
  local no_match="n/a (no in-cycle rows)"
  local loc="$no_substrate" tokens="$no_substrate" tpl="$no_substrate" minutes="$no_substrate"
  MISSING_ROW_ISSUES=""

  if [ -f "$rows_file" ]; then
    local json
    json="$(jq -n --argjson ids "$CUR_IDS_JSON" --slurpfile rows "$rows_file" '
      def median: sort as $s | ($s|length) as $n |
        if $n == 0 then null
        elif ($n % 2 == 1) then $s[($n-1)/2]
        else ($s[$n/2 - 1] + $s[$n/2]) / 2
        end;
      ($rows[0] // []) as $all
      | [$all[] | select(.issue as $i | $ids | index($i) != null)] as $m
      | {
          found: [$m[].issue],
          loc: ([$m[].loc] | median),
          tokens: ([$m[].tokens_total] | median),
          tpl: ([$m[].tokens_per_loc] | median),
          minutes: ([$m[].duration_ms] | map(./60000) | median)
        }
    ' 2>/dev/null)"

    if [ -n "$json" ]; then
      local found_list rloc rtokens rtpl rminutes n
      found_list="$(printf '%s' "$json" | jq -r '.found | map(tostring) | join(" ")' 2>/dev/null)"
      rloc="$(printf '%s' "$json" | jq -r '.loc // "null"' 2>/dev/null)"
      rtokens="$(printf '%s' "$json" | jq -r '.tokens // "null"' 2>/dev/null)"
      rtpl="$(printf '%s' "$json" | jq -r '.tpl // "null"' 2>/dev/null)"
      rminutes="$(printf '%s' "$json" | jq -r '.minutes // "null"' 2>/dev/null)"
      [ "$rloc" != "null" ] && loc="$(clean_num "$rloc")" || loc="$no_match"
      [ "$rtokens" != "null" ] && tokens="$(clean_num "$rtokens")" || tokens="$no_match"
      [ "$rtpl" != "null" ] && tpl="$(clean_num "$rtpl")" || tpl="$no_match"
      [ "$rminutes" != "null" ] && minutes="$(clean_num "$rminutes")" || minutes="$no_match"
      local missing=""
      for n in $CUR_ISSUES; do
        case " $found_list " in
          *" $n "*) ;;
          *) missing="$missing $n" ;;
        esac
      done
      MISSING_ROW_ISSUES="${missing# }"
    fi
  fi

  JOIN_COMP_VAL["median path b pr/loc"]="$loc";           JOIN_COMP_UNIT["median path b pr/loc"]=""
  JOIN_COMP_VAL["median path b pr/tokens"]="$tokens";      JOIN_COMP_UNIT["median path b pr/tokens"]=""
  JOIN_COMP_VAL["median path b pr/tokens/loc"]="$tpl";     JOIN_COMP_UNIT["median path b pr/tokens/loc"]=""
  JOIN_COMP_VAL["median path b pr/min"]="$minutes";        JOIN_COMP_UNIT["median path b pr/min"]=""
  JOIN_COMP_VAL["median path b pr/usd"]="$CALIB_USD"
  JOIN_COMP_UNIT["median path b pr/usd"]=""
}

compute_cost_latency "$ROWS_FILE"

# ---------------------------------------------------------------------------
# Task 4 — harness-mass rows (measured off the working tree; never n/a)
# ---------------------------------------------------------------------------

compute_harness_mass() {
  local skills words scripts scripts_loc hooks hooks_loc tests tests_loc
  local grep_skill grep_claude refs distinct

  skills="$(ls -d "$REPO_ROOT"/skills/*/ 2>/dev/null | wc -l | tr -d ' ')"
  words="$(cat "$REPO_ROOT"/skills/*/SKILL.md "$REPO_ROOT"/agents/*.md 2>/dev/null | wc -w | tr -d ' ')"
  scripts="$(ls "$REPO_ROOT"/scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')"
  scripts_loc="$(cat "$REPO_ROOT"/scripts/*.sh 2>/dev/null | wc -l | tr -d ' ')"
  hooks="$(find "$REPO_ROOT/hooks" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) 2>/dev/null | wc -l | tr -d ' ')"
  hooks_loc="$(find "$REPO_ROOT/hooks" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')"
  tests="$(ls "$REPO_ROOT"/tests/test*.sh 2>/dev/null | wc -l | tr -d ' ')"
  tests_loc="$(cat "$REPO_ROOT"/tests/test*.sh 2>/dev/null | wc -l | tr -d ' ')"
  grep_skill="$(grep -l 'SKILL.md' "$REPO_ROOT"/tests/test*.sh 2>/dev/null | wc -l | tr -d ' ')"
  grep_claude="$(grep -l 'CLAUDE.md' "$REPO_ROOT"/tests/test*.sh 2>/dev/null | wc -l | tr -d ' ')"
  refs="$(grep -ohE '#[0-9]{2,4}' "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
  distinct="$(grep -ohE '#[0-9]{2,4}' "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null | sort -u | wc -l | tr -d ' ')"

  JOIN_COMP_VAL["harness mass/skills"]="${skills:-0}"
  JOIN_COMP_VAL["harness mass/words"]="${words:-0}"
  JOIN_COMP_VAL["harness mass/scripts"]="${scripts:-0}"
  JOIN_COMP_VAL["harness mass/scripts loc"]="${scripts_loc:-0}"
  JOIN_COMP_VAL["harness mass/hooks"]="${hooks:-0}"
  JOIN_COMP_VAL["harness mass/hooks loc"]="${hooks_loc:-0}"
  JOIN_COMP_VAL["harness mass/tests"]="${tests:-0}"
  JOIN_COMP_VAL["harness mass/tests loc"]="${tests_loc:-0}"
  JOIN_COMP_VAL["prose-pinning tests/grep skill.md"]="${grep_skill:-0}"
  JOIN_COMP_VAL["prose-pinning tests/grep claude.md"]="${grep_claude:-0}"
  JOIN_COMP_VAL["issue-number archaeology in skill bodies/refs"]="${refs:-0}"
  JOIN_COMP_VAL["issue-number archaeology in skill bodies/distinct"]="${distinct:-0}"

  local k
  for k in "harness mass/skills" "harness mass/words" "harness mass/scripts" \
           "harness mass/scripts loc" "harness mass/hooks" "harness mass/hooks loc" \
           "harness mass/tests" "harness mass/tests loc" \
           "prose-pinning tests/grep skill.md" "prose-pinning tests/grep claude.md" \
           "issue-number archaeology in skill bodies/refs" \
           "issue-number archaeology in skill bodies/distinct"; do
    JOIN_COMP_UNIT["$k"]=""
  done
}

compute_harness_mass

# ---------------------------------------------------------------------------
# Task 5 — friction, escapes, gate yield, weak-model, usage snapshot
# ---------------------------------------------------------------------------

NO_DECISION_FIELD="n/a (tool-use.log has no decision field; hooks/log-tool-use.sh logs invocations only)"

FRICTION_DENIALS=""
FRICTION_LINES_COUNT=0
declare -a FRICTION_LINES_TEXT=()
FRICTION_HOTFIX=0
FRICTION_MANUAL_MERGE=0
FRICTION_HUMAN=0

compute_friction() {
  local toolog="$1" issues_file="$2" prs_file="$3" since="$4" cnt line

  if [ -f "$toolog" ]; then
    cnt="$(awk -F'\t' -v since="$since" '
      NF>=5 && (since=="" || $1 >= since) && ($2=="denied" || $2=="blocked" || $3=="BLOCKED") { c++ }
      END { print c+0 }
    ' "$toolog")"
    if [ "${cnt:-0}" -gt 0 ]; then
      FRICTION_DENIALS="$cnt"
    else
      FRICTION_DENIALS="$NO_DECISION_FIELD"
    fi
  else
    FRICTION_DENIALS="$NO_DECISION_FIELD"
  fi

  FRICTION_LINES_TEXT=()
  if [ -f "$issues_file" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      FRICTION_LINES_TEXT+=("$line")
    done < <(jq -r --argjson ids "$CUR_IDS_JSON" --arg since "$since" '
      [.[] | select(.number as $n | $ids | index($n) != null) | .comments[]?
        | select(($since == "") or (.createdAt >= $since))
        | .body] | .[]
    ' "$issues_file" 2>/dev/null | grep '^HARNESS-FRICTION:')
  fi
  FRICTION_LINES_COUNT="${#FRICTION_LINES_TEXT[@]}"

  FRICTION_HOTFIX=0
  FRICTION_MANUAL_MERGE=0
  if [ -f "$prs_file" ]; then
    FRICTION_HOTFIX="$(jq -r '[.[] | select((.headRefName // "") | test("^feature/hotfix-"))] | length' "$prs_file" 2>/dev/null)"
    FRICTION_MANUAL_MERGE="$(jq -r '[.[] | select(.labels[]?.name == "manual-merge")] | length' "$prs_file" 2>/dev/null)"
  fi
  FRICTION_HUMAN=0
  if [ -f "$issues_file" ]; then
    FRICTION_HUMAN="$(jq -r '[.[] | select(.labels[]?.name == "human")] | length' "$issues_file" 2>/dev/null)"
  fi

  FRICTION_HOTFIX="${FRICTION_HOTFIX:-0}"
  FRICTION_MANUAL_MERGE="${FRICTION_MANUAL_MERGE:-0}"
  FRICTION_HUMAN="${FRICTION_HUMAN:-0}"

  EXTRA_COMP_VAL["friction/denials"]="$FRICTION_DENIALS";                   EXTRA_COMP_UNIT["friction/denials"]=""
  EXTRA_COMP_VAL["friction/harness-friction-lines"]="$FRICTION_LINES_COUNT"; EXTRA_COMP_UNIT["friction/harness-friction-lines"]=""
  EXTRA_COMP_VAL["friction/compactions"]="n/a (no transcript substrate)";   EXTRA_COMP_UNIT["friction/compactions"]=""
  EXTRA_COMP_VAL["friction/hotfix"]="$FRICTION_HOTFIX";                    EXTRA_COMP_UNIT["friction/hotfix"]=""
  EXTRA_COMP_VAL["friction/manual-merge"]="$FRICTION_MANUAL_MERGE";        EXTRA_COMP_UNIT["friction/manual-merge"]=""
  EXTRA_COMP_VAL["friction/human"]="$FRICTION_HUMAN";                      EXTRA_COMP_UNIT["friction/human"]=""
}

compute_friction "$TOOLOG" "$ISSUES_FILE" "$PRS_FILE" "$SINCE"

GATE_REVISE=0; GATE_PLANS=0; GATE_FLAGGED=0; GATE_EVALS=0

compute_gate_yield() {
  local issues_file="$1" out
  [ -f "$issues_file" ] || return 0
  out="$(jq -r --argjson ids "$CUR_IDS_JSON" '
    [.[] | select(.number as $n | $ids | index($n) != null) | .comments[]?.body] as $bodies
    | ($bodies | map(select(contains("## Plan Evaluation")))) as $plan
    | ($bodies | map(select(contains("## Evaluation") and (contains("## Plan Evaluation")|not)))) as $pr
    | "\(($plan | map(select(contains("Verdict:** Revise"))) | length)) \($plan|length) \(($pr | map(select(contains("Verdict:** Flagged"))) | length)) \($pr|length)"
  ' "$issues_file" 2>/dev/null)"
  [ -z "$out" ] && return 0
  read -r GATE_REVISE GATE_PLANS GATE_FLAGGED GATE_EVALS <<< "$out"
}

compute_gate_yield "$ISSUES_FILE"

USAGE_LINE="n/a (no usage-gate log)"

compute_usage_snapshot() {
  local f="$1" last fh sd th
  [ -f "$f" ] || return 0
  last="$(tail -1 "$f" 2>/dev/null)"
  [ -z "$last" ] && return 0
  fh="$(printf '%s' "$last" | jq -r '.five_hour // "n/a"' 2>/dev/null)"
  sd="$(printf '%s' "$last" | jq -r '.seven_day // "n/a"' 2>/dev/null)"
  th="$(printf '%s' "$last" | jq -r '.threshold // "n/a"' 2>/dev/null)"
  USAGE_LINE="five_hour=$fh seven_day=$sd threshold=$th"
}

compute_usage_snapshot "$USAGE_FILE"

ESCAPES_HOTFIX=0; ESCAPES_REVERT=0; ESCAPES_LATERFIX=0

compute_escapes() {
  local prs_file="$1" prev_ids_json="$2" out
  [ -f "$prs_file" ] || return 0
  out="$(jq -r --argjson ids "$prev_ids_json" '
    def closes: (.body // "") | [scan("Closes #([0-9]+)")] | map(.[0]|tonumber);
    [.[] | . + {closes: closes}] as $prs
    | ($prs | map(select(.closes | any(. as $c | $ids | index($c) != null)))) as $prev_prs
    | ($prev_prs | [.[].files[]?] | unique) as $prev_files
    | ($prs | map(select((.closes | any(. as $c | $ids | index($c) != null)) | not))) as $cur_prs
    | ($cur_prs | map(select((.headRefName // "") | test("^feature/hotfix-")))) as $hotfix
    | ($cur_prs - $hotfix) as $rest1
    | ($rest1 | map(select((.title // "") | test("^revert(\\([a-z0-9_-]+\\))?!?: ")))) as $revert
    | ($rest1 - $revert) as $rest2
    | ($rest2 | map(select(([.files[]?] | any(. as $f | $prev_files | index($f) != null))))) as $laterfix
    | "\($hotfix|length) \($revert|length) \($laterfix|length)"
  ' "$prs_file" 2>/dev/null)"
  [ -z "$out" ] && return 0
  read -r ESCAPES_HOTFIX ESCAPES_REVERT ESCAPES_LATERFIX <<< "$out"
}

compute_escapes "$PRS_FILE" "$PREV_IDS_JSON"

EXTRA_COMP_VAL["escapes/hotfix"]="$ESCAPES_HOTFIX";       EXTRA_COMP_UNIT["escapes/hotfix"]=""
EXTRA_COMP_VAL["escapes/revert"]="$ESCAPES_REVERT";       EXTRA_COMP_UNIT["escapes/revert"]=""
EXTRA_COMP_VAL["escapes/later-fix"]="$ESCAPES_LATERFIX";  EXTRA_COMP_UNIT["escapes/later-fix"]=""

# ---------------------------------------------------------------------------
# Task 6 — deltas, passthrough rows, prev-delta, pending verdicts
# ---------------------------------------------------------------------------

verdict_candidates() {  # <issues_file> <ids_json> -> space-separated issue numbers
  local issues_file="$1" ids_json="$2"
  [ -f "$issues_file" ] || { printf ''; return 0; }
  jq -r --argjson ids "$ids_json" '
    [.[] | select(.number as $n | $ids | index($n) != null)
      | select((.body // "") | contains("Measured by: retro (next cycle)"))
      | .number] | map(tostring) | join(" ")
  ' "$issues_file" 2>/dev/null
}

VERDICT_CANDIDATES="$(verdict_candidates "$ISSUES_FILE" "$CUR_IDS_JSON")"

PENDING_VERDICTS=""
if [ "$CYCLE" -gt 0 ] && [ -n "$PREV_ISSUES" ]; then
  PENDING_VERDICTS="$(verdict_candidates "$ISSUES_FILE" "$PREV_IDS_JSON")"
fi

declare -A PREV_COMP_VAL=()
PREV_RETRO_FOUND=""

resolve_prev_retro_file() {
  local n="$1" prevnn
  if [ "$n" -le 0 ]; then printf ''; return 0; fi
  prevnn="$(printf '%02d' $((n - 1)))"
  if [ -n "$FIXTURE_DIR" ]; then
    printf '%s' "$FIXTURE_DIR/cycle-$prevnn.md"
  else
    printf '%s' "$REPO_ROOT/docs/retros/cycle-$prevnn.md"
  fi
}

load_prev_computed() {
  local f="$1" line rest key val
  [ -n "$f" ] && [ -f "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      "COMPUTED "*)
        rest="${line#COMPUTED }"
        key="${rest%% = *}"
        val="${rest#* = }"
        PREV_COMP_VAL["$key"]="$val"
        ;;
    esac
  done < "$f"
  return 0
}

PREV_RETRO_FILE="$(resolve_prev_retro_file "$CYCLE")"
if load_prev_computed "$PREV_RETRO_FILE"; then
  PREV_RETRO_FOUND=1
fi

# ---------------------------------------------------------------------------
# Report builders
# ---------------------------------------------------------------------------

print_baseline_dump() {
  local key v u
  for key in "${!BASE_VAL[@]}"; do
    v="${BASE_VAL[$key]}"; u="${BASE_UNIT[$key]}"
    if [ -n "$u" ] && is_numeric "$v"; then
      echo "BASELINE $key = $v $u"
    else
      echo "BASELINE $key = $v"
    fi
  done
}

print_computed_dump() {
  local key v u
  for key in "${!JOIN_COMP_VAL[@]}"; do
    v="${JOIN_COMP_VAL[$key]}"; u="${JOIN_COMP_UNIT[$key]}"
    if [ -n "$u" ] && is_numeric "$v"; then
      echo "COMPUTED $key = $v $u"
    else
      echo "COMPUTED $key = $v"
    fi
  done
  for key in "${!EXTRA_COMP_VAL[@]}"; do
    v="${EXTRA_COMP_VAL[$key]}"; u="${EXTRA_COMP_UNIT[$key]}"
    if [ -n "$u" ] && is_numeric "$v"; then
      echo "COMPUTED $key = $v $u"
    else
      echo "COMPUTED $key = $v"
    fi
  done
}

print_post_report() {
  local key v u
  for key in "${!JOIN_COMP_VAL[@]}"; do
    case "$key" in
      "median path b pr/"*) continue ;;
    esac
    v="${JOIN_COMP_VAL[$key]}"; u="${JOIN_COMP_UNIT[$key]}"
    if [ -n "$u" ] && is_numeric "$v"; then echo "COMPUTED $key = $v $u"; else echo "COMPUTED $key = $v"; fi
  done
  for key in "${!EXTRA_COMP_VAL[@]}"; do
    v="${EXTRA_COMP_VAL[$key]}"; u="${EXTRA_COMP_UNIT[$key]}"
    if [ -n "$u" ] && is_numeric "$v"; then echo "COMPUTED $key = $v $u"; else echo "COMPUTED $key = $v"; fi
  done
  echo "verdict-candidates: $VERDICT_CANDIDATES"
}

build_full_report() {
  local key n i rn rc nr matched bval cval bunit cunit diff fl

  echo "cycle-issues: $CUR_ISSUES"
  echo ""

  for key in "${!JOIN_COMP_VAL[@]}"; do
    cval="${JOIN_COMP_VAL[$key]}"
    is_numeric "$cval" || continue
    if [ -n "${BASE_VAL[$key]+x}" ]; then
      bval="${BASE_VAL[$key]}"
      if is_numeric "$bval"; then
        bunit="${BASE_UNIT[$key]}"; cunit="${JOIN_COMP_UNIT[$key]}"
        if [ "$bunit" != "$cunit" ]; then
          echo "delta $key n/a (unit mismatch: $bunit vs $cunit)"
        else
          diff="$(awk -v a="$bval" -v b="$cval" 'BEGIN{d=b-a; if (d==int(d)) printf "%d", d; else printf "%.2f", d}')"
          echo "delta $key $diff (baseline $bval -> computed $cval)"
        fi
      fi
    else
      echo "delta $key n/a (baseline row not found: $key)"
    fi
  done

  for ((i = 0; i < ${#ROW_NAMES[@]}; i++)); do
    rn="${ROW_NAMES[$i]}"; rc="${ROW_CELLS[$i]}"
    nr="$(norm_row "$rn")"
    matched=0
    for key in "${!JOIN_COMP_VAL[@]}"; do
      case "$key" in
        "$nr/"*)
          if is_numeric "${JOIN_COMP_VAL[$key]}" && [ -n "${BASE_VAL[$key]+x}" ]; then
            matched=1
          fi
          ;;
      esac
    done
    if [ "$matched" -eq 0 ]; then
      echo "$rn: $rc"
    fi
  done

  for n in $MISSING_ROW_ISSUES; do
    echo "cost/latency #$n: n/a (outside PR window)"
  done

  echo ""
  echo "friction: denials = $FRICTION_DENIALS"
  echo "friction: harness-friction-lines = $FRICTION_LINES_COUNT"
  for fl in "${FRICTION_LINES_TEXT[@]:-}"; do
    [ -z "$fl" ] && continue
    echo "$fl"
  done
  echo "friction: compactions = n/a (no transcript substrate)"
  echo "friction: hotfix = $FRICTION_HOTFIX"
  echo "friction: manual-merge = $FRICTION_MANUAL_MERGE"
  echo "friction: human = $FRICTION_HUMAN"

  echo ""
  echo "escapes: hotfix = $ESCAPES_HOTFIX"
  echo "escapes: revert = $ESCAPES_REVERT"
  echo "escapes: later-fix = $ESCAPES_LATERFIX"

  echo ""
  echo "gate-yield: Flagged/evals = ${GATE_FLAGGED}/${GATE_EVALS}"
  echo "gate-yield: Revise/plans = ${GATE_REVISE}/${GATE_PLANS}"

  echo ""
  echo "weak-model pass: $CALIB_WEAK"

  echo ""
  echo "usage: $USAGE_LINE"

  echo ""
  if [ -n "$PREV_RETRO_FOUND" ]; then
    for key in "${!JOIN_COMP_VAL[@]}"; do
      is_numeric "${JOIN_COMP_VAL[$key]}" || continue
      if [ -n "${PREV_COMP_VAL[$key]+x}" ] && is_numeric "${PREV_COMP_VAL[$key]}"; then
        diff="$(awk -v a="${PREV_COMP_VAL[$key]}" -v b="${JOIN_COMP_VAL[$key]}" 'BEGIN{d=b-a; if (d==int(d)) printf "%d", d; else printf "%.2f", d}')"
        echo "prev-delta $key $diff (previous ${PREV_COMP_VAL[$key]} -> computed ${JOIN_COMP_VAL[$key]})"
      fi
    done
  else
    echo "prev-delta: n/a (no previous cycle)"
  fi

  if [ -n "$PENDING_VERDICTS" ]; then
    echo ""
    echo "pending-verdicts: $PENDING_VERDICTS"
  fi
}

apply_bound() {
  local text="$1" n
  n="$(printf '%s\n' "$text" | wc -l)"
  if [ "$n" -le 60 ]; then
    printf '%s\n' "$text"
  else
    printf '%s\n' "$text" | head -59
    echo "… (truncated; full report written by --write)"
  fi
}

# ---------------------------------------------------------------------------
# Output mode dispatch
# ---------------------------------------------------------------------------

if [ "$DUMP_BASELINE" -eq 1 ] || [ "$DUMP_COMPUTED" -eq 1 ]; then
  [ "$DUMP_BASELINE" -eq 1 ] && print_baseline_dump
  [ "$DUMP_COMPUTED" -eq 1 ] && print_computed_dump
  exit 0
fi

if [ "$POST" -eq 1 ]; then
  print_post_report
  exit 0
fi

FULL_REPORT="$(build_full_report)"
STDOUT_REPORT="$(apply_bound "$FULL_REPORT")"
printf '%s\n' "$STDOUT_REPORT"

if [ -n "$WRITE_PATH" ]; then
  mkdir -p "$(dirname "$WRITE_PATH")" 2>/dev/null
  printf '%s\n' "$FULL_REPORT" > "$WRITE_PATH"
fi

exit 0
