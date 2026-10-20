# shellcheck shell=bash
# _helper-parallel.sh — sourced by the fullsend wave helpers (#1548). Defines:
#
#   helper_parallel_map <fn> <arg>...
#       Runs `<fn> <arg>` once per arg, each in its own subshell (so globals a
#       per-issue body sets — WT/BR/PR_NUM/REASON — cannot clobber a sibling),
#       at most ${PIPELINE_HELPER_PARALLEL:-4} at a time. A cap that is not a
#       positive integer falls back to 4 with a stderr WARN.
#
# ORDER CONTRACT: each job's stdout/stderr is captured to "$d/<i>.out|err";
# after the last chunk every .out is printed in ARGV order, then every .err.
# Cap 1 runs the same temp-file machinery with chunk size 1, so stdout is
# byte-identical across caps — only wall time differs.
#
# Throttle: start up to <cap> jobs, then `wait` on their PIDs (bash-3.2-safe,
# no `wait -n`). Returns 0.
#
# No top-level side effects — function definition only.

helper_parallel_map() {
  local fn="$1"; shift
  local cap="${PIPELINE_HELPER_PARALLEL:-4}"
  case "$cap" in
    ''|*[!0-9]*) cap="" ;;
    *) [ "$((10#$cap))" -ge 1 ] && cap="$((10#$cap))" || cap="" ;;
  esac
  if [ -z "$cap" ]; then
    echo "WARN: PIPELINE_HELPER_PARALLEL='${PIPELINE_HELPER_PARALLEL:-}' is not a positive integer; using 4" >&2
    cap=4
  fi
  local n=$#
  [ "$n" -gt 0 ] || return 0
  local args=("$@")
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/helper-par.XXXXXX") || return 1
  local i=0 j pids
  while [ "$i" -lt "$n" ]; do
    pids=()
    j=0
    while [ "$j" -lt "$cap" ] && [ "$i" -lt "$n" ]; do
      ( "$fn" "${args[$i]}" ) >"$d/$i.out" 2>"$d/$i.err" &
      pids+=("$!")
      i=$((i + 1)); j=$((j + 1))
    done
    wait "${pids[@]}"
  done
  for ((i = 0; i < n; i++)); do cat "$d/$i.out"; done
  for ((i = 0; i < n; i++)); do cat "$d/$i.err" >&2; done
  rm -rf "$d"
  return 0
}
