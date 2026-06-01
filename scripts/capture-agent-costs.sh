#!/usr/bin/env bash
# capture-agent-costs.sh — retroactive agent token-cost parser (dogfood-only).
#
# Reads the dogfood observability logs and emits one normalized cost record per
# agent invocation to .claude/logs/agent-costs.jsonl (JSON Lines, append-only,
# idempotent by record_key). Gated behind PIPELINE_LOGS_ENABLED.
#
#   HEADLESS pass — .claude/logs/runs.log
#       Each run resolves a Claude Code transcript at
#       ~/.claude/projects/<slug>/<session>.jsonl, where <slug> sanitizes BOTH
#       "/" and "." to "-" (so ".claude" -> "--claude", a DOUBLE dash). The
#       transcript is summed for complete token usage. Missing transcripts are
#       skipped and counted (headless_skipped_missing_transcript, to stderr).
#
#   INLINE pass — .claude/logs/subagents.log
#       Stage + issue are parsed from the free-text description; non-stage lines
#       are skipped. Tokens come from the per-agent JSON sidecar named in col 7
#       (.claude/logs/subagents/<filename>); these are a documented lower-bound
#       (usage_complete=false), never a fabricated cumulative sum.
#
# ===========================================================================
# OUTPUT RECORD SCHEMA (schema_version=1) — #643 CONSUMPTION CONTRACT, STABLE.
#   {
#     schema_version: 1,
#     record_key:   sha1("<source>|<agent_kind>|<session_id>|<issue>|<stage>|<ts_start>"),
#     issue:        <string>,
#     stage:        one of {classify, plan, plan-eval, execute, pr-eval},
#     agent_kind:   "headless" | "inline",
#     agent_type:   skill name (headless) | sidecar subagent_type (inline),
#     session_id:   <string>,
#     model:        <string>,
#     tokens: { input, output, cache_read, cache_creation, total },
#     duration_ms:  (ts_end - ts_start) in ms, 0 when timestamps absent/equal,
#     ts_start:     <iso8601|"">,
#     ts_end:       <iso8601|"">,
#     source:       "retroactive",
#     usage_complete: true (headless) | false (inline lower-bound)
#   }
#   tokens.total = input + output + cache_read + cache_creation.
#
#   record_key is a LOGICAL idempotency key — the same key denotes the same
#   logical agent finish (last-write-wins). Producers dedup on append (the
#   `seen` set below), but a key may legitimately RECUR across appends with
#   revised token totals (e.g. an inline lower-bound later superseded by a
#   complete sum). Therefore any consumer that SUMS token/duration fields MUST
#   first dedup on record_key (group_by(.record_key) | last) — see #698 and
#   scripts/cost-latency-report.sh — or recurring keys are double-counted.
# ===========================================================================
set -uo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$THIS_DIR/_logging.sh"
# shellcheck source=/dev/null
source "$THIS_DIR/_token-usage-lib.sh"

if ! pipeline_logging_enabled; then
  # Loud, machine-detectable skip signal (#790). The stderr line is the human
  # message; the stdout marker is what the tokenomics skill greps for so it can
  # tell an intentional opt-out (PIPELINE_LOGS_ENABLED unset/false by design)
  # from a propagation failure (the skill passed the var but it didn't arrive).
  echo "capture-agent-costs: PIPELINE_LOGS_ENABLED not 'true'; skipping (no writes)." >&2
  echo "capture-agent-costs: SKIP_LOGGING_DISABLED (PIPELINE_LOGS_ENABLED='${PIPELINE_LOGS_ENABLED:-<unset>}')"
  exit 0
fi

# Resolve the consumer logs dir. Honor CLAUDE_PROJECT_DIR (hermetic tests and
# the dogfood runtime both set it); fall back to the worktree root.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$THIS_DIR/.." && pwd)}"
logs_dir="$PROJECT_DIR/.claude/logs"      # INPUT logs (worker-local)
runs_log="$logs_dir/runs.log"
subagents_log="$logs_dir/subagents.log"
sidecar_dir="$logs_dir/subagents"

# OUTPUT log resolves to the MAIN worktree so execute-stage records written
# from inside a linked worktree survive cleanup-worktree.sh prune (#697).
# git --git-common-dir resolves the shared .git from a linked worktree; its
# parent dir is the main worktree root. Fail-open to PROJECT_DIR when not a
# git worktree (hermetic non-git tests, raw consumer dirs).
common_dir="$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$common_dir" ]; then
  case "$common_dir" in
    /*) main_root="$(cd "$(dirname "$common_dir")" && pwd)" ;;
    *)  main_root="$(cd "$PROJECT_DIR/$(dirname "$common_dir")" && pwd)" ;;
  esac
else
  main_root="$PROJECT_DIR"
fi
out_logs_dir="$main_root/.claude/logs"
out="$out_logs_dir/agent-costs.jsonl"
mkdir -p "$logs_dir" "$out_logs_dir"

# All record emission, parsing, idempotency, and counters happen in python so
# JSON construction matches the #643 contract exactly.
python3 - \
  "$runs_log" "$subagents_log" "$sidecar_dir" "$out" "${HOME:-}" <<'PY'
import datetime, hashlib, json, os, re, sys

runs_log, subagents_log, sidecar_dir, out_path, home = sys.argv[1:6]

STAGE_PATTERNS = [
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?pr|pr[ -]?eval|finish[ -]?eval[ -]?pr)\b", "pr-eval"),
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?plan|eval[ -]?plan|re[ -]?eval(uate)?[ -]?plan)\b", "plan-eval"),
    (r"\bexecut(e|e[ -]?issue[ -]?plan)\b", "execute"),
    (r"\b(re[ -]?)?plan([ -]?issue)?\b", "plan"),
    (r"\b(re[ -]?)?classif(y|y[ -]?issue)\b", "classify"),
]
SKILL_STAGE = {
    "plan-issue": "plan",
    "evaluate-issue-plan": "plan-eval",
    "execute-issue-plan": "execute",
    "evaluate-issue-pr": "pr-eval",
}


def stage_from_description(d):
    # For multi-stage labels ("Classify + plan + evaluate #N") the FIRST stage
    # token by string position wins; STAGE_PATTERNS index breaks ties so an
    # overlapping single token ("evaluate plan" -> plan-eval) keeps precedence.
    best = None  # ((start_pos, rank), stage)
    for rank, (pat, stage) in enumerate(STAGE_PATTERNS):
        m = re.search(pat, d, re.IGNORECASE)
        if m is None:
            continue
        key = (m.start(), rank)
        if best is None or key < best[0]:
            best = (key, stage)
    return best[1] if best else ""


def issue_from_description(d):
    for pat in (r"for[ -]?#(\d+)", r"\(issue[ -]?#(\d+)\)", r"\(#(\d+)\)"):
        m = re.search(pat, d, re.IGNORECASE)
        if m:
            return m.group(1)
    m = re.search(r"#(\d+)", d)
    return m.group(1) if m else ""


def worktree_slug(path):
    return re.sub(r"[/.]", "-", path)


def transcript_sum(path):
    inp = out = cr = cc = 0
    ts_start = ts_end = None
    model = ""
    try:
        fh = open(path)
    except OSError:
        return {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0,
                "ts_start": "", "ts_end": "", "model": ""}
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
    return {"input": inp, "output": out, "cache_read": cr, "cache_creation": cc,
            "ts_start": ts_start or "", "ts_end": ts_end or "", "model": model}


def duration_ms(ts_start, ts_end):
    def parse(t):
        if not t:
            return None
        try:
            return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        except ValueError:
            return None
    a, b = parse(ts_start), parse(ts_end)
    if a is None or b is None:
        return 0
    delta = (b - a).total_seconds() * 1000.0
    return int(delta) if delta > 0 else 0


def record_key(source, agent_kind, session_id, issue, stage, ts_start):
    raw = "%s|%s|%s|%s|%s|%s" % (source, agent_kind, session_id, issue, stage, ts_start)
    return hashlib.sha1(raw.encode()).hexdigest()


def make_record(*, issue, stage, agent_kind, agent_type, session_id, model,
                tokens, ts_start, ts_end, usage_complete):
    total = sum(tokens[k] for k in ("input", "output", "cache_read", "cache_creation"))
    source = "retroactive"
    return {
        "schema_version": 1,
        "record_key": record_key(source, agent_kind, session_id, issue, stage, ts_start),
        "issue": issue,
        "stage": stage,
        "agent_kind": agent_kind,
        "agent_type": agent_type,
        "session_id": session_id,
        "model": model,
        "tokens": {
            "input": tokens["input"],
            "output": tokens["output"],
            "cache_read": tokens["cache_read"],
            "cache_creation": tokens["cache_creation"],
            "total": total,
        },
        "duration_ms": duration_ms(ts_start, ts_end),
        "ts_start": ts_start,
        "ts_end": ts_end,
        "source": source,
        "usage_complete": usage_complete,
    }


def kv(fields, key):
    # fields like "session=abc" "issue=12" -> value for key, else "".
    for f in fields:
        if f.startswith(key + "="):
            return f[len(key) + 1:]
    return ""


# existing record_keys for idempotency
seen = set()
if os.path.exists(out_path):
    with open(out_path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                seen.add(json.loads(line)["record_key"])
            except (ValueError, KeyError):
                continue

new_records = []
headless_skipped_missing_transcript = 0

# ---- HEADLESS pass ----
if os.path.exists(runs_log):
    with open(runs_log) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            cols = line.split("\t")
            fields = cols[1:]
            session = kv(fields, "session")
            issue = kv(fields, "issue")
            skill = kv(fields, "skill")
            worktree = kv(fields, "worktree")
            run_model = kv(fields, "model")
            stage = SKILL_STAGE.get(skill, "")
            if not session or not worktree:
                continue
            slug = worktree_slug(worktree)
            transcript = os.path.join(home, ".claude", "projects", slug, session + ".jsonl")
            if not os.path.exists(transcript):
                headless_skipped_missing_transcript += 1
                continue
            summ = transcript_sum(transcript)
            model = run_model if run_model else summ["model"]
            rec = make_record(
                issue=issue, stage=stage, agent_kind="headless", agent_type="skill",
                session_id=session, model=model,
                tokens=summ, ts_start=summ["ts_start"], ts_end=summ["ts_end"],
                usage_complete=True)
            if rec["record_key"] in seen:
                continue
            seen.add(rec["record_key"])
            new_records.append(rec)

# ---- INLINE pass ----
if os.path.exists(subagents_log):
    with open(subagents_log) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            cols = line.split("\t")
            if len(cols) < 7:
                continue
            ts = cols[0]
            session = cols[1]
            description = cols[2]
            fname = cols[6]
            stage = stage_from_description(description)
            if not stage:
                continue
            issue = issue_from_description(description)
            agent_type = "unknown"
            usage = {"input": 0, "output": 0, "cache_read": 0, "cache_creation": 0}
            sidecar = os.path.join(sidecar_dir, fname)
            if os.path.exists(sidecar):
                try:
                    with open(sidecar) as sf:
                        data = json.load(sf)
                    agent_type = data.get("subagent_type", "unknown")
                    u = data.get("usage", {}) or {}
                    usage = {
                        "input": u.get("input_tokens") or 0,
                        "output": u.get("output_tokens") or 0,
                        "cache_read": u.get("cache_read_input_tokens") or 0,
                        "cache_creation": u.get("cache_creation_input_tokens") or 0,
                    }
                except (ValueError, OSError):
                    pass
            rec = make_record(
                issue=issue, stage=stage, agent_kind="inline", agent_type=agent_type,
                session_id=session, model="",
                tokens=usage, ts_start=ts, ts_end=ts,
                usage_complete=False)
            if rec["record_key"] in seen:
                continue
            seen.add(rec["record_key"])
            new_records.append(rec)

with open(out_path, "a") as fh:
    for rec in new_records:
        fh.write(json.dumps(rec) + "\n")

sys.stderr.write(
    "capture-agent-costs: appended %d record(s); "
    "headless_skipped_missing_transcript=%d\n"
    % (len(new_records), headless_skipped_missing_transcript))
PY
