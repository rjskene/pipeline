#!/usr/bin/env bash
# _token-usage-lib.sh — sourceable helpers for retroactive agent token-cost capture.
#
# Functions:
#   tu_transcript_sum <jsonl-path>
#       Print ONE tab-separated line:
#         input <TAB> output <TAB> cache_read <TAB> cache_creation <TAB> ts_start <TAB> ts_end <TAB> model
#       Sums message.usage.{input,output,cache_read_input,cache_creation_input}_tokens
#       over every line that carries message.usage. ts_start/ts_end are the
#       min/max top-level "timestamp"; model is the last non-empty message.model.
#       Lines without message.usage and non-JSON lines are tolerated (skipped).
#
#   tu_worktree_slug <abs-worktree-path>
#       Print the Claude Code transcript-dir slug: re.sub(r"[/.]","-",path).
#       Sanitizes BOTH "/" and "." so ".claude" -> "--claude" (DOUBLE dash).
#
#   tu_stage_from_description <description>
#       Map a free-text subagents.log description to a canonical stage
#       (classify|plan|plan-eval|execute|pr-eval), matched case-insensitively in
#       a fixed precedence order. Prints empty string when no stage matches.
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
inp = out = cr = cc = 0
ts_start = ts_end = None
model = ""
try:
    fh = open(path)
except OSError:
    print("0\t0\t0\t0\t\t\t")
    sys.exit(0)
with fh:
    for line in fh:
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
        inp += usage.get("input_tokens") or 0
        out += usage.get("output_tokens") or 0
        cr += usage.get("cache_read_input_tokens") or 0
        cc += usage.get("cache_creation_input_tokens") or 0
        m = msg.get("model")
        if m:
            model = m
print("%d\t%d\t%d\t%d\t%s\t%s\t%s" % (
    inp, out, cr, cc, ts_start or "", ts_end or "", model))
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
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?plan|eval[ -]?plan|re[ -]?eval(uate)?[ -]?plan)\b", "plan-eval"),
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
print(best[1] if best else "")
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
