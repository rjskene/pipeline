#!/usr/bin/env bash
# _token-usage-lib.sh — sourceable helpers for retroactive agent token-cost capture.
#
# Functions:
#   tu_transcript_sum <jsonl-path>
#       Print ONE tab-separated line (10 fields):
#         input <TAB> output <TAB> cache_read <TAB> cache_creation <TAB> ts_start
#         <TAB> ts_end <TAB> model <TAB> turns <TAB> ctx_first <TAB> ctx_last
#       Aggregates message.usage.{input,output,cache_read_input,cache_creation_input}_tokens
#       DEDUPED BY message.id (#1443): Claude Code writes one API response as
#       2-3 assistant lines (thinking / text / tool_use) that share message.id,
#       repeating input/cache_read/cache_creation verbatim while output_tokens is
#       progressive. Each bucket is reduced with max() per id (the final count
#       for output; a robust "count once" for the verbatim buckets), then summed
#       across ids. A usage line with no message.id keys on "__noid__<line_no>"
#       so legacy transcripts sum exactly as before and each such line is its
#       own turn. ts_start/ts_end are the min/max top-level "timestamp"; model is
#       the last non-empty message.model; turns is the distinct-id count;
#       ctx_first/ctx_last are cache_read+cache_creation of the FIRST/LAST id
#       (absolute context sizes, never summed). Lines without message.usage and
#       non-JSON lines are tolerated (skipped).
#       Mirrors hooks/capture_agent_cost.py:transcript_sum and
#       scripts/capture-agent-costs.sh:transcript_sum byte-for-byte by contract.
#
#   tu_worktree_slug <abs-worktree-path>
#       Print the Claude Code transcript-dir slug: re.sub(r"[/.]","-",path).
#       Sanitizes BOTH "/" and "." so ".claude" -> "--claude" (DOUBLE dash).
#
#   tu_stage_from_description <description>
#       Map a free-text subagents.log description to a canonical stage
#       (classify|plan|plan-eval|execute|pr-eval), matched case-insensitively in
#       a fixed precedence order. When the precedence table yields no match, a
#       second STRICTLY-FALLBACK table (#1299) is consulted: a PATH C leaf
#       description (target=<dir> + an issue number) -> execute; an
#       orchestrator closing code review (review [#N] code changes | code
#       review) -> pr-eval. Prints empty string when neither table matches.
#
#   tu_issue_from_description <description>
#       Extract the issue number from a free-text description per the enumerated
#       real-world shapes (for #N / (issue #N) / (#N) win; else first #N; the
#       "/ PR #M" and "(PR #M)" groups are the PR, never the issue).
set -uo pipefail

_TU_THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_TU_THIS_DIR/_logging.sh"

tu_transcript_sum() {
  local path="$1"
  python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
ts_start = ts_end = None
model = ""
# Per-message.id aggregation (#1443). `ids` preserves first-sight order so
# ctx_first/ctx_last are the FIRST/LAST response's context size; `per_id` maps
# key -> [input, output, cache_read, cache_creation] reduced with max().
ids = []
per_id = {}
try:
    fh = open(path)
except OSError:
    print("0\t0\t0\t0\t\t\t\t0\t0\t0")
    sys.exit(0)
with fh:
    for line_no, line in enumerate(fh):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict):
            continue
        ts = obj.get("timestamp")
        if ts:
            if ts_start is None or ts < ts_start:
                ts_start = ts
            if ts_end is None or ts > ts_end:
                ts_end = ts
        msg = obj.get("message")
        if not isinstance(msg, dict):
            continue
        usage = msg.get("usage")
        if not isinstance(usage, dict):
            continue
        mid = msg.get("id")
        key = mid or ("__noid__%d" % line_no)
        vals = [
            usage.get("input_tokens") or 0,
            usage.get("output_tokens") or 0,
            usage.get("cache_read_input_tokens") or 0,
            usage.get("cache_creation_input_tokens") or 0,
        ]
        if key in per_id:
            prev = per_id[key]
            per_id[key] = [max(prev[i], vals[i]) for i in range(4)]
        else:
            ids.append(key)
            per_id[key] = vals
        m = msg.get("model")
        if m:
            model = m
inp = sum(per_id[k][0] for k in ids)
out = sum(per_id[k][1] for k in ids)
cr = sum(per_id[k][2] for k in ids)
cc = sum(per_id[k][3] for k in ids)
turns = len(ids)
ctx_first = (per_id[ids[0]][2] + per_id[ids[0]][3]) if ids else 0
ctx_last = (per_id[ids[-1]][2] + per_id[ids[-1]][3]) if ids else 0
print("%d\t%d\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%d" % (
    inp, out, cr, cc, ts_start or "", ts_end or "", model,
    turns, ctx_first, ctx_last))
PY
}

tu_worktree_slug() {
  local path="$1"
  python3 - "$path" <<'PY'
import re, sys
print(re.sub(r"[/.]", "-", sys.argv[1]))
PY
}

tu_stage_from_description() {
  local desc="$1"
  python3 - "$desc" <<'PY'
import re, sys
d = sys.argv[1]
# Precedence-ordered patterns: index is the disambiguation rank (lower wins on
# ties). pr-eval/plan-eval are listed before execute/plan/classify so that a
# single compound token like "evaluate plan" resolves to plan-eval rather than
# the bare "plan" it contains.
patterns = [
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?pr|pr[ -]?eval|finish[ -]?eval[ -]?pr)\b", "pr-eval"),
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?plan|eval[ -]?plan|re[ -]?eval(uate)?[ -]?plan|plan[ -]?eval(uation)?)\b", "plan-eval"),
    (r"\bexecut(e|e[ -]?issue[ -]?plan)\b", "execute"),
    (r"\b(re[ -]?)?plan([ -]?issue)?\b", "plan"),
    (r"\b(re[ -]?)?classif(y|y[ -]?issue)\b", "classify"),
]
# For multi-stage labels ("Classify + plan + evaluate #N") the FIRST stage token
# by string position wins. Rank breaks ties so overlapping single tokens at the
# same position (e.g. "evaluate plan" -> plan-eval, not plan) keep precedence.
best = None  # (start_pos, rank, stage)
for rank, (pat, stage) in enumerate(patterns):
    m = re.search(pat, d, re.IGNORECASE)
    if m is None:
        continue
    key = (m.start(), rank)
    if best is None or key < best[0]:
        best = (key, stage)
if best is not None:
    print(best[1])
    sys.exit(0)
# STRICTLY-FALLBACK table (#1299): consulted ONLY when the main precedence
# table above yields no match. Resolved by table RANK (first entry wins), not
# string position -- both patterns below can match zero-width around the
# description, so a position rule would be meaningless. This makes the
# widening MONOTONE ("" -> stage, never stage -> another stage): a description
# the main table already answers is untouched, so no record_key is re-minted.
STAGE_FALLBACK_PATTERNS = [
    (r"\breview\b(?:\s+#\d+)?\s+code[ -]?changes\b|\bcode[ -]?review\b", "pr-eval"),
    (r"^(?=.*#\d+)(?=.*target=\S)", "execute"),
]
for pat, stage in STAGE_FALLBACK_PATTERNS:
    if re.search(pat, d, re.IGNORECASE):
        print(stage)
        sys.exit(0)
print("")
PY
}

tu_issue_from_description() {
  local desc="$1"
  python3 - "$desc" <<'PY'
import re, sys
d = sys.argv[1]
# Priority groups that explicitly name the issue.
for pat in (r"for[ -]?#(\d+)", r"\(issue[ -]?#(\d+)\)", r"\(#(\d+)\)"):
    m = re.search(pat, d, re.IGNORECASE)
    if m:
        print(m.group(1))
        sys.exit(0)
# Otherwise the FIRST '#N' is the issue (any "/ PR #M" or "(PR #M)" is the PR).
m = re.search(r"#(\d+)", d)
print(m.group(1) if m else "")
PY
}

# tu_role_from_description <description>
#   Maps a free-text agent dispatch description to a role in
#   {red, green, review, single}. Mirrors the inline python
#   role_from_description in scripts/capture-agent-costs.sh and
#   hooks/capture_agent_cost.py (same regex, same convention as
#   tu_stage_from_description / tu_issue_from_description). (#1098, #1299)
#
#   "split-role RED"                 → "red"
#   "split-role GREEN"               → "green"
#   "review [#N] code changes" | "code review" (stage pr-eval) → "review"
#   anything else                    → "single"
tu_role_from_description() {
  local desc="$1"
  python3 - "$desc" <<'PY'
import re, sys
d = sys.argv[1]
if re.search(r"split[- ]role\s+red", d, re.IGNORECASE):
    print("red")
elif re.search(r"split[- ]role\s+green", d, re.IGNORECASE):
    print("green")
elif re.search(r"\breview\b(?:\s+#\d+)?\s+code[ -]?changes\b|\bcode[ -]?review\b", d, re.IGNORECASE):
    print("review")
else:
    print("single")
PY
}
