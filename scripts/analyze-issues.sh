#!/bin/bash
set -uo pipefail

# Source logging gate helper (best-effort; absence is non-fatal so callers
# that vendor this script standalone still work - gate defaults to off).
_ANALYZE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_ANALYZE_SCRIPT_DIR/_logging.sh" ]; then
  # shellcheck source=/dev/null
  . "$_ANALYZE_SCRIPT_DIR/_logging.sh"
fi
if ! declare -F pipeline_logging_enabled >/dev/null 2>&1; then
  pipeline_logging_enabled() { [ "${PIPELINE_LOGS_ENABLED:-false}" = "true" ]; }
fi
#
# analyze-issues.sh — Stage 1 deterministic shortlist generator backing
# /pipeline:status --analyze (issue #138).
#
# Reads open issues + open trackers via `gh` (or fixture files), emits a
# candidate-shortlist JSON to .claude/logs/analyze-shortlist-<ISO>.json
# with two categories: duplicate_pairs and tracker_fits. Prints the file
# path on stdout. No mutations.
#
# Output JSON contract (stable):
#   {
#     "duplicate_pairs": [
#       {"a": <int>, "b": <int>, "title_jaccard": <float>,
#        "shared_scope": <string>, "body_overlap_chars": <int>}
#     ],
#     "tracker_fits": [
#       {"issue": <int>, "tracker": <int>,
#        "reason": "scope-match"|"body-reference"}
#     ],
#     "missing_label_candidates": [
#       {"issue": <int>, "missing": ["priority"|"path"|"state", ...]}
#     ],
#     "supersession_candidates": [
#       {"issue": <int>,
#        "candidate_prs": [
#          {"pr": <int>, "files_overlap_count": <int>, "scope_match": <bool>}
#        ]}
#     ]
#   }
#
# Usage:
#   bash scripts/analyze-issues.sh                   # live (calls gh)
#   bash scripts/analyze-issues.sh --fixture <dir>   # fixture mode (no gh)
#
# Caps at top 20 duplicate pairs + top 20 tracker fits + top 20 missing-label
# candidates + top 20 supersession candidates (<= 5 candidate_prs each).
#
# The missing-label signal has a configurable age gate
# (PIPELINE_ANALYZE_MIN_AGE_HOURS, default 24h) — issues younger than the
# cutoff are silently suppressed so newly-filed issues are not flagged
# before classify-issue has a chance to run.

# --- locate and source pipeline.config (best-effort; fixture mode tolerates absence) ---
find_config() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/pipeline.config" ]; then
      printf '%s\n' "$dir/pipeline.config"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

CFG="$(find_config || true)"
if [ -n "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi

FIXTURE_DIR="${ANALYZE_GH_FIXTURE:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --fixture)   FIXTURE_DIR="${2:-}"; shift 2 ;;
    --fixture=*) FIXTURE_DIR="${1#--fixture=}"; shift ;;
    *)
      echo "analyze-issues: ERROR: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

PARSE_CHILDREN_SCRIPT="$(dirname "$0")/parse-tracker-children.sh"

# --- temp files ---
ISSUES_FILE=$(mktemp)
NT_TSV=$(mktemp)
TR_INDEX_FILE=$(mktemp)
FITS_RAW=$(mktemp)
CHILD_INDEX_FILE=$(mktemp)
PRS_FILE=$(mktemp)
trap 'rm -f "$ISSUES_FILE" "$NT_TSV" "$TR_INDEX_FILE" "$FITS_RAW" "$CHILD_INDEX_FILE" "$PRS_FILE"' EXIT

# --- source issues JSON ---
if [ -n "$FIXTURE_DIR" ]; then
  if [ ! -f "$FIXTURE_DIR/issues.json" ]; then
    echo "analyze-issues: ERROR: fixture issues.json not found at $FIXTURE_DIR/issues.json" >&2
    exit 1
  fi
  cp "$FIXTURE_DIR/issues.json" "$ISSUES_FILE"
else
  if [ -z "${PIPELINE_REPO:-}" ]; then
    echo "analyze-issues: ERROR: PIPELINE_REPO not set" >&2
    exit 1
  fi
  gh issue list \
    --repo "$PIPELINE_REPO" \
    --state open \
    --limit 200 \
    --json number,title,body,labels,createdAt \
    > "$ISSUES_FILE"
fi

# fetch_tracker_body <num> — prefer per-tracker fixture file, else fall back to
# the body already present in issues.json (live mode hits `gh issue view`).
fetch_tracker_body() {
  local num="$1"
  if [ -n "$FIXTURE_DIR" ] && [ -f "$FIXTURE_DIR/issue-$num.json" ]; then
    jq -r '.body // ""' "$FIXTURE_DIR/issue-$num.json"
  elif [ -n "$FIXTURE_DIR" ]; then
    jq -r --argjson n "$num" '.[] | select(.number == $n) | .body // ""' "$ISSUES_FILE"
  else
    gh issue view "$num" --repo "$PIPELINE_REPO" --json body --jq '.body // ""'
  fi
}

# --- enrich: parse scope + stemmed token set per issue ---
# Tokenization: strip `<verb>(<scope>):` prefix, lowercase, split on non-alphanum,
# drop tokens < 3 chars + the stopwords {the,for,and}, stem to first 4 chars.
ENRICHED=$(jq '
  def stopwords: ["the","for","and"];
  def stem4: if length >= 4 then .[0:4] else . end;
  def scope_of:
    (capture("^[a-z]+\\((?<s>[a-z0-9_-]+)\\):") // {s: ""}) | .s;
  def tokenize:
    sub("^[a-z]+\\([^)]+\\):\\s*"; "")
    | ascii_downcase
    | [splits("[^a-z0-9]+")]
    | map(select(length >= 3))
    | map(select(. as $t | stopwords | index($t) | not))
    | map(stem4)
    | unique;
  map({
    number: .number,
    title: .title,
    body: (.body // ""),
    scope: (.title | scope_of),
    tokens: (.title | tokenize),
    is_tracker: (((.labels // []) | map(.name) | index("tracker")) != null)
  })
' "$ISSUES_FILE")

# --- duplicate pairs: TSV across non-tracker issues, then awk for pairs ---
NONTRACKERS=$(printf '%s' "$ENRICHED" | jq '[.[] | select(.is_tracker == false)]')

# TSV columns: number, tokens-csv, scope, body (with literal `\n` placeholder
# for embedded newlines so awk reads one row per line).
printf '%s' "$NONTRACKERS" | jq -r '
  .[]
  | [
      .number,
      (.tokens | join(",")),
      .scope,
      ((.body // "") | gsub("\n"; "\\n") | gsub("\t"; " "))
    ]
  | @tsv
' > "$NT_TSV"

# --- trackers + children index ---
# Built before duplicate-pairs awk so CHILD_INDEX_FILE is available to both
# the awk's same-tracker-siblings filter and the tracker-fits loop below.
TRACKERS=$(printf '%s' "$ENRICHED" | jq '[.[] | select(.is_tracker == true)]')

while IFS= read -r tline; do
  [ -z "$tline" ] && continue
  tnum=$(printf '%s' "$tline" | jq -r '.number' | tr -d '\r')
  tscope=$(printf '%s' "$tline" | jq -r '.scope' | tr -d '\r')  # strip MSYS jq CR (#1165)
  tbody=$(fetch_tracker_body "$tnum")
  children=$(printf '%s\n' "$tbody" | bash "$PARSE_CHILDREN_SCRIPT" - | paste -sd, -)
  printf '%s\t%s\t%s\n' "$tnum" "$tscope" "$children"
done < <(printf '%s' "$TRACKERS" | jq -c '.[]') > "$TR_INDEX_FILE"

# Derive child→tracker index from TR_INDEX_FILE — one row per (child, tracker)
# pair (a child mapped under two trackers, which signals a config bug, produces
# two rows; the two consumers below disagree on which wins — duplicate-pairs awk
# overwrites in ct[], lookup_child_tracker returns the first match — but for the
# well-formed case of one tracker per child, both yield the same answer).
awk -F'\t' '
  {
    tnum = $1
    n = split($3, ch, ",")
    for (i = 1; i <= n; i++) {
      if (ch[i] != "") print ch[i] "\t" tnum
    }
  }
' "$TR_INDEX_FILE" > "$CHILD_INDEX_FILE"

PAIRS_RAW=$(awk -F'\t' -v cif="$CHILD_INDEX_FILE" '
  BEGIN {
    if (cif != "") {
      while ((getline line < cif) > 0) {
        nf = split(line, p, "\t")
        if (nf == 2 && p[1] != "" && p[2] != "") ct[p[1]] = p[2]
      }
      close(cif)
    }
  }
  function lcs_len(a, b,    na, nb, i, j, prev, cur, mx, ca, cb, k) {
    na = length(a); nb = length(b)
    if (na > 4096) { a = substr(a, 1, 4096); na = 4096 }
    if (nb > 4096) { b = substr(b, 1, 4096); nb = 4096 }
    mx = 0
    delete prev
    for (i = 1; i <= na; i++) {
      delete cur
      ca = substr(a, i, 1)
      for (j = 1; j <= nb; j++) {
        cb = substr(b, j, 1)
        if (ca == cb) {
          cur[j] = ((j-1) in prev ? prev[j-1] : 0) + 1
          if (cur[j] > mx) mx = cur[j]
        }
      }
      delete prev
      for (k in cur) prev[k] = cur[k]
    }
    return mx
  }
  function jaccard(a_csv, b_csv,   ai, bi, i, k, n_a, n_b, n_int, n_un, seen) {
    if (a_csv == "" && b_csv == "") return 0
    n_a = split(a_csv, ai, ",")
    n_b = split(b_csv, bi, ",")
    delete seen
    n_int = 0
    for (i = 1; i <= n_a; i++) if (ai[i] != "") seen[ai[i]] = 1
    for (i = 1; i <= n_b; i++) {
      if (bi[i] != "" && (bi[i] in seen) && seen[bi[i]] == 1) {
        n_int++
        seen[bi[i]] = 2
      }
    }
    delete seen
    for (i = 1; i <= n_a; i++) if (ai[i] != "") seen[ai[i]] = 1
    for (i = 1; i <= n_b; i++) if (bi[i] != "") seen[bi[i]] = 1
    n_un = 0
    for (k in seen) n_un++
    if (n_un == 0) return 0
    return n_int / n_un
  }
  {
    cnt = NR
    n[cnt] = $1
    t[cnt] = $2
    s[cnt] = $3
    b[cnt] = $4
  }
  END {
    for (i = 1; i <= cnt; i++) {
      for (j = i+1; j <= cnt; j++) {
        # Same-tracker-siblings exclusion: both numbers indexed in ct[] AND map to same tracker.
        if ((n[i] in ct) && (n[j] in ct) && ct[n[i]] == ct[n[j]]) continue
        ja = jaccard(t[i], t[j])
        shared = (s[i] != "" && s[i] == s[j]) ? s[i] : ""
        keep = 0
        ovl = 0
        if (shared != "") {
          bi = b[i]; bj = b[j]
          gsub(/\\n/, "\n", bi); gsub(/\\n/, "\n", bj)
          ovl = lcs_len(bi, bj)
        }
        if (ja >= 0.35) keep = 1
        else if (shared != "" && ovl > 40) keep = 1
        if (keep) {
          printf "%s\t%s\t%.6f\t%s\t%d\n", n[i], n[j], ja, shared, ovl
        }
      }
    }
  }
' "$NT_TSV")

# Sort: title_jaccard desc, body_overlap_chars desc; cap 20.
PAIRS_SORTED=$(printf '%s\n' "$PAIRS_RAW" | awk 'NF' | sort -t$'\t' -k3,3rg -k5,5rn | awk 'NR<=20')

PAIRS_JSON=$(
  if [ -z "$PAIRS_SORTED" ]; then
    echo '[]'
  else
    printf '%s\n' "$PAIRS_SORTED" \
      | awk -F'\t' 'NF { printf "{\"a\":%s,\"b\":%s,\"title_jaccard\":%s,\"shared_scope\":\"%s\",\"body_overlap_chars\":%s}\n", $1, $2, $3, $4, $5 }' \
      | jq -s '.'
  fi
)

# --- tracker fits ---
# Lookup child→tracker via the unified CHILD_INDEX_FILE built earlier.
# Returns the parent tracker number on stdout (exit 0) or nothing (exit 1).
lookup_child_tracker() {
  local child="$1"
  [ ! -s "$CHILD_INDEX_FILE" ] && return 1
  awk -F'\t' -v c="$child" '$1 == c { print $2; found=1; exit } END { exit (found ? 0 : 1) }' "$CHILD_INDEX_FILE"
}

while IFS= read -r iline; do
  [ -z "$iline" ] && continue
  inum=$(printf '%s' "$iline" | jq -r '.number' | tr -d '\r')
  iscope=$(printf '%s' "$iline" | jq -r '.scope' | tr -d '\r')      # strip MSYS jq CR (#1165)
  ibody=$(printf '%s' "$iline" | jq -r '.body // ""' | tr -d '\r')  # strip MSYS jq CR (#1165)
  # Already-in-rollout: skip every (inum, parent_tracker) pair regardless of which
  # tracker we're scoring against. Equivalent to the previous per-tracker is_child
  # check, expressed via the unified child→tracker index.
  iparent=$(lookup_child_tracker "$inum" || true)
  # tchildren is unused in this loop body — the per-tracker is_child check it
  # used to drive now lives in the unified CHILD_INDEX_FILE lookup above. The
  # field is retained in TR_INDEX_FILE's schema so the file remains the single
  # source of tracker/children info for any downstream consumer.
  while IFS=$'\t' read -r tnum tscope tchildren; do
    [ -z "$tnum" ] && continue
    if [ -n "$iparent" ] && [ "$iparent" = "$tnum" ]; then continue; fi
    reason=""
    if [ -n "$iscope" ] && [ "$iscope" = "$tscope" ]; then
      reason="scope-match"
    elif printf '%s' "$ibody" | grep -qE "#${tnum}([^0-9]|\$)"; then
      reason="body-reference"
    fi
    if [ -n "$reason" ]; then
      printf '%s\t%s\t%s\n' "$inum" "$tnum" "$reason" >> "$FITS_RAW"
    fi
  done < "$TR_INDEX_FILE"
done < <(printf '%s' "$NONTRACKERS" | jq -c '.[]')

# Dedup (issue,tracker) preferring scope-match; sort by issue asc; cap 20.
FITS_JSON=$(
  if [ ! -s "$FITS_RAW" ]; then
    echo '[]'
  else
    awk -F'\t' '
      {
        key = $1 SUBSEP $2
        if (!(key in seen) || $3 == "scope-match") {
          seen[key] = $3
          iss[key] = $1
          trk[key] = $2
        }
      }
      END {
        for (k in seen) printf "%s\t%s\t%s\n", iss[k], trk[k], seen[k]
      }
    ' "$FITS_RAW" \
      | sort -t$'\t' -k1,1n \
      | awk 'NR<=20' \
      | awk -F'\t' 'NF { printf "{\"issue\":%s,\"tracker\":%s,\"reason\":\"%s\"}\n", $1, $2, $3 }' \
      | jq -s '.'
  fi
)

# --- missing-label candidates ---
# Detect issues lacking any of:
#   - priority/P[0-9] label                     (always required)
#   - docs-only, multi-task, or quick-fix path label (required unless brainstorm/later/human/tracker)
#   - any pipeline-stage or classification label (state: surfaced only when nothing
#                                                 else is present; redundant flag,
#                                                 sorted after priority/path)
# Age gate: PIPELINE_ANALYZE_MIN_AGE_HOURS (default 24h). Issues newer than the
# cutoff are silently suppressed so classify-issue gets a chance to run. Issues
# without a createdAt field are treated as age-unknown → suppressed.
MIN_AGE_HOURS="${PIPELINE_ANALYZE_MIN_AGE_HOURS:-24}"
NOW_EPOCH=$(date -u +%s)
CUTOFF_EPOCH=$(( NOW_EPOCH - MIN_AGE_HOURS * 3600 ))
MISSING_JSON=$(jq --argjson cutoff "$CUTOFF_EPOCH" '
  def has_priority(labels): any(labels[]?; .name | test("^priority/P[0-9]$"));
  def has_path(labels):     any(labels[]?; .name == "docs-only" or .name == "multi-task" or .name == "quick-fix");
  def has_state(labels):    any(labels[]?; .name == "brainstorm" or .name == "tracker" or .name == "later" or .name == "human");
  def is_tracker(labels):   any(labels[]?; .name == "tracker");
  def is_exempt(labels):    any(labels[]?; .name == "brainstorm" or .name == "later" or .name == "human");
  def age_ok($cdt):
    # Suppress on uncertainty: missing or unparseable createdAt yields false
    # (no row emitted). The try/catch around fromdateiso8601 ensures one
    # malformed date in upstream data does not abort the whole jq pipeline
    # and silently zero missing_label_candidates for the entire repo.
    ($cdt // "") as $c
    | if $c == "" then false
      else (try (($c | fromdateiso8601) < $cutoff) catch false)
      end;
  [ .[]
    | select(is_tracker(.labels) | not)
    | select(is_exempt(.labels) | not)
    | select(age_ok(.createdAt))
    | . as $i
    | {
        number,
        missing: (
          [ (if has_priority($i.labels) | not then "priority" else empty end),
            (if has_path($i.labels)     | not then "path"     else empty end) ]
          + (if (has_priority($i.labels) | not)
               and (has_path($i.labels) | not)
               and (has_state($i.labels) | not)
             then ["state"] else [] end)
        )
      }
    | select(.missing | length > 0)
    | {issue: .number, missing: .missing}
  ] | .[0:20]
' "$ISSUES_FILE")

# --- supersession candidates ---
# Cross-reference open non-stage issues against recently-merged PRs. A merged PR
# is a supersession candidate for an issue when it merged AFTER the issue was
# filed AND it either touches a file the issue body references (files_overlap)
# or carries the issue's conventional-commit scope (scope_match).
#
# PR source: live mode pulls the last 200 merged PRs; fixture mode reads
# prs.json. Fixtures predating this feature lack prs.json — when absent we skip
# the block silently and emit an empty array (back-compat).
#
# gh returns each file as {"path": "..."}; fixtures may store plain strings.
# The jq below normalizes both shapes to a path-string array.
SUPERSESSION_JSON='[]'
HAVE_PRS=0
if [ -n "$FIXTURE_DIR" ]; then
  if [ -f "$FIXTURE_DIR/prs.json" ]; then
    cp "$FIXTURE_DIR/prs.json" "$PRS_FILE"
    HAVE_PRS=1
  fi
else
  if [ -n "${PIPELINE_REPO:-}" ]; then
    gh pr list \
      --repo "$PIPELINE_REPO" \
      --state merged \
      --json number,mergedAt,files,title,body \
      --limit 200 \
      > "$PRS_FILE"
    HAVE_PRS=1
  fi
fi

if [ "$HAVE_PRS" -eq 1 ]; then
  # Reuse the same is_tracker/is_exempt label-state predicates as the
  # missing-label block so "open non-stage-labelled issue" means the same thing
  # across both signals. body file-path refs are extracted via a fixed regex
  # over the tracked top-level dirs; scope comes from the existing scope_of
  # filter (already materialized on each NONTRACKERS entry as .scope).
  SUPERSESSION_JSON=$(jq -n \
    --slurpfile issues_raw "$ISSUES_FILE" \
    --slurpfile prs_raw "$PRS_FILE" \
    --argjson nontrackers "$NONTRACKERS" '
    def is_tracker(labels): any(labels[]?; .name == "tracker");
    def is_exempt(labels):  any(labels[]?; .name == "brainstorm" or .name == "later" or .name == "human");
    def body_paths:
      [ . | scan("\\b(?:scripts|skills|hooks|tests|docs)/[A-Za-z0-9._/-]+\\.(?:sh|md|py|json)") ]
      | unique;
    # Normalize each PR: files → path-string array, plus parsed mergedAt epoch.
    ($prs_raw[0] // []) as $prs
    | ($prs | map({
        pr: .number,
        merged_epoch: (try (.mergedAt | fromdateiso8601) catch null),
        files: (
          if ((.files // []) | length) == 0 then []
          elif ((.files[0] | type) == "object") then [.files[].path]
          else .files end
        ),
        title: (.title // ""),
        body: (.body // "")
      })) as $prnorm
    # Label-state lookup keyed by issue number, from the raw issues payload.
    | ([ ($issues_raw[0] // [])[] | {key: (.number|tostring), value: .labels} ] | from_entries) as $labelmap
    | [ $nontrackers[]
        | . as $i
        | ($labelmap[($i.number|tostring)] // []) as $labels
        | select(is_tracker($labels) | not)
        | select(is_exempt($labels) | not)
        | ($i.scope // "") as $scope
        | (($i.body // "") | body_paths) as $bpaths
        | (try (($issues_raw[0] // [])[] | select(.number == $i.number) | .createdAt | fromdateiso8601) catch null) as $created_epoch
        | {
            issue: $i.number,
            candidate_prs: (
              [ $prnorm[]
                | select(.merged_epoch != null and $created_epoch != null and .merged_epoch > $created_epoch)
                | . as $pr
                | ([ $bpaths[] | select(. as $p | $pr.files | index($p)) ] | length) as $ovl
                | (
                    ($scope != "")
                    and (
                      ($pr.title | test("^[a-z]+\\(" + $scope + "\\):"))
                      or ($pr.body | contains("scope:" + $scope))
                    )
                  ) as $smatch
                | select($ovl >= 1 or $smatch)
                | {pr: $pr.pr, files_overlap_count: $ovl, scope_match: $smatch}
              ]
              # Cap candidate_prs per issue at 5, best overlap first.
              | sort_by(-.files_overlap_count, (if .scope_match then 0 else 1 end))
              | .[0:5]
            )
          }
        | select(.candidate_prs | length >= 1)
      ]
      # Cap total rows at 20: max files_overlap_count desc, then scope_match desc.
      | sort_by(
          -([.candidate_prs[].files_overlap_count] | max // 0),
          (if any(.candidate_prs[]; .scope_match) then 0 else 1 end)
        )
      | .[0:20]
  ')
fi

# --- assemble + emit ---
# Gate the shortlist output path on PIPELINE_LOGS_ENABLED. When logging is
# off (the consumer default), route to mktemp so we do not leave artifacts
# under .claude/logs/ in consumer repos. The stdout absolute-path contract
# is unchanged; only the source of the path flips.
if pipeline_logging_enabled; then
  mkdir -p .claude/logs
  OUT=".claude/logs/analyze-shortlist-$(date -u +%Y%m%dT%H%M%S%NZ).json"
else
  OUT="$(mktemp -t pipeline-analyze-shortlist-XXXX.json)"
fi
jq -n \
  --argjson pairs        "${PAIRS_JSON:-[]}" \
  --argjson fits         "${FITS_JSON:-[]}" \
  --argjson missing      "${MISSING_JSON:-[]}" \
  --argjson supersession "${SUPERSESSION_JSON:-[]}" \
  '{duplicate_pairs: $pairs, tracker_fits: $fits, missing_label_candidates: $missing, supersession_candidates: $supersession}' > "$OUT"

ABS_OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
printf '%s\n' "$ABS_OUT"
