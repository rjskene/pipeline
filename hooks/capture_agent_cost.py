#!/usr/bin/env python3
"""capture_agent_cost.py -- forward agent token-cost capture hook (dogfood-only).

Registered on PostToolUse with an Agent matcher (#660). The SubagentStop/Stop
payloads carry NEITHER `description` NOR `usage`, so the hook never emitted a
record there; PostToolUse(Agent) carries both (description/subagent_type under
tool_input, usage/total_duration_ms under tool_response). (The subagent dispatch
tool in this environment is named "Agent", not "Task".) This is the DURABLE,
ACCURATE forward cost source: it records cumulative token usage at agent
finish, in contrast to the retroactive log-scanning parser in
scripts/capture-agent-costs.sh.

The flat top-level shape (description/usage at the top level) is still accepted
for back-compat; see _normalize_payload.

Gated behind PIPELINE_LOGS_ENABLED=="true" (strict lowercase, mirroring
scripts/_logging.sh). When disabled, the hook writes NOTHING and exits 0.

Output is one JSON Lines record appended to .claude/logs/agent-costs.jsonl,
byte-compatible with the schema_version=1 contract frozen in
scripts/capture-agent-costs.sh. A forward record and a retroactive record for
the same agent differ ONLY in source (forward vs retroactive) and
usage_complete (forward true, retroactive-inline false).

Fail-open: the entire body is wrapped in try/except; exceptions are logged to
.claude/logs/agent-cost-hook-errors.log and the hook ALWAYS exits 0 so it can
never block agent completion.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import sys
import traceback
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from subagent_log_utils import append_locked  # noqa: E402


# Stage/issue normaliser -- mirrors tu_stage_from_description /
# tu_issue_from_description in scripts/_token-usage-lib.sh so both producers
# normalise free-text descriptions identically.

STAGE_PATTERNS = [
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?pr|pr[ -]?eval|finish[ -]?eval[ -]?pr)\b", "pr-eval"),
    (r"\b(eval(uate)?[ -]?(issue[ -]?)?plan|eval[ -]?plan|re[ -]?eval(uate)?[ -]?plan)\b", "plan-eval"),
    (r"\bexecut(e|e[ -]?issue[ -]?plan)\b", "execute"),
    (r"\b(re[ -]?)?plan([ -]?issue)?\b", "plan"),
    (r"\b(re[ -]?)?classif(y|y[ -]?issue)\b", "classify"),
]


def stage_from_description(d):
    # FIRST stage token by string position wins; STAGE_PATTERNS index breaks
    # ties so an overlapping single token ("evaluate plan" -> plan-eval) keeps
    # precedence.
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


def duration_from_timestamps(ts_start, ts_end):
    def parse(t):
        if not t:
            return None
        try:
            return datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))
        except (ValueError, AttributeError):
            return None
    a, b = parse(ts_start), parse(ts_end)
    if a is None or b is None:
        return 0
    delta = (b - a).total_seconds() * 1000.0
    return int(delta) if delta > 0 else 0


def record_key(source, agent_kind, session_id, issue, stage, ts_start):
    raw = "%s|%s|%s|%s|%s|%s" % (source, agent_kind, session_id, issue, stage, ts_start)
    return hashlib.sha1(raw.encode()).hexdigest()


def transcript_sum(path):
    """Sum per-assistant-message token usage over a transcript JSONL.

    Mirrors scripts/capture-agent-costs.sh:transcript_sum so both producers
    parse identically: skip blank/non-JSON/non-dict lines, track min/max
    `timestamp`, accumulate the four `*_tokens` fields from `message.usage`,
    capture the last non-empty `message.model`. Returns zeros on OSError."""
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


_STATE_FILENAME = "agent-cost-orchestrator-state.json"


def _load_state(logs_dir):
    """Map session_id -> last-emitted cumulative tokens. Fail-open to {}."""
    try:
        with open(os.path.join(logs_dir, _STATE_FILENAME)) as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _save_state(logs_dir, state):
    """Atomically persist the per-session cumulative state (tmp + os.replace).

    Stop is single-writer per session, so a tmp+replace is sufficient; it
    avoids torn reads without needing the flock held on agent-costs.jsonl."""
    os.makedirs(logs_dir, exist_ok=True)
    path = os.path.join(logs_dir, _STATE_FILENAME)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh)
    os.replace(tmp, path)


def build_stop_record(payload, logs_dir):
    """Build a schema_version=1 orchestrator record from a Stop payload, or None.

    The Stop payload carries {session_id, transcript_path} but no usage; the
    transcript JSONL carries per-assistant-message `message.usage`. We sum the
    MAIN session transcript (subagent dispatches run in separate transcripts,
    captured independently via PostToolUse(Agent), so the two streams are
    disjoint and never double-count). Attribution is synthetic:
    stage=orchestrator, agent_kind=main, issue='' (unknowable for free-form
    turns)."""
    session_id = payload.get("session_id") or ""
    transcript_path = payload.get("transcript_path")
    if not transcript_path:
        return None

    summ = transcript_sum(transcript_path)

    # Transcript usage is CUMULATIVE and Stop fires at every main-agent turn
    # end. Emit only the per-session DELTA vs the last-emitted cumulative so
    # the downstream SUM over a session's deltas equals the cumulative total
    # and never double-counts. State lives in a sidecar keyed by session_id.
    state = _load_state(logs_dir)
    last = state.get(session_id) or {}
    fields = ("input", "output", "cache_read", "cache_creation")
    tokens = {f: summ[f] - (last.get(f) or 0) for f in fields}
    tokens["total"] = sum(tokens[f] for f in fields)
    if tokens["total"] <= 0:
        return None  # no new tokens since the last fire: emit nothing

    state[session_id] = {f: summ[f] for f in fields}
    _save_state(logs_dir, state)

    ts_start = summ["ts_start"]
    ts_end = summ["ts_end"]
    stage = "orchestrator"
    agent_kind = "main"
    source = "forward"
    issue = ""

    return {
        "schema_version": 1,
        "record_key": record_key(source, agent_kind, session_id, issue, stage, ts_start),
        "issue": issue,
        "stage": stage,
        "agent_kind": agent_kind,
        "agent_type": "orchestrator",
        "session_id": session_id,
        "model": summ["model"],
        "tokens": tokens,
        "duration_ms": duration_from_timestamps(ts_start, ts_end),
        "ts_start": ts_start,
        "ts_end": ts_end,
        "source": source,
        "usage_complete": True,
    }


def _first(payload, *keys):
    for k in keys:
        v = payload.get(k)
        if v is not None and v != "":
            return v
    return None


def _extract_usage(payload):
    """Return the usage dict if the payload carries one anywhere we recognise,
    else None. None means fail-open: emit no record."""
    for key in ("usage", "total_usage", "cumulative_usage"):
        u = payload.get(key)
        if isinstance(u, dict):
            return u
    msg = payload.get("message")
    if isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
        return msg["usage"]
    return None


def _normalize_payload(payload):
    """Map a PostToolUse(Agent) payload into the flat shape build_record expects.

    PostToolUse fires for EVERY tool; only Agent carries subagent cost, so a
    non-Agent PostToolUse payload normalises to None (skip). A payload that is
    already in the flat top-level shape (carrying description/usage at the top
    level, as SubagentStop fixtures and the existing tests do) is returned
    unchanged for back-compat.

    Returns a flat dict for build_record, or None to skip.
    """
    if "tool_name" in payload or "tool_input" in payload or "tool_response" in payload:
        if payload.get("tool_name") != "Agent":
            return None  # PostToolUse for a non-Agent tool: no subagent cost
        tool_input = payload.get("tool_input") or {}
        tool_response = payload.get("tool_response") or {}
        # Wall-clock duration lives at the payload TOP LEVEL as `duration_ms` in
        # the real PostToolUse(Agent) shape; tool_response.total_duration_ms is
        # None/absent there. Source top-level first, fall back to tool_response
        # for back-compat with the synthetic fixture (#660).
        duration = payload.get("duration_ms")
        if duration is None:
            duration = tool_response.get("total_duration_ms")
        return {
            "session_id": payload.get("session_id"),
            "description": tool_input.get("description"),
            "subagent_type": tool_input.get("subagent_type"),
            "usage": tool_response.get("usage"),
            "total_duration_ms": duration,
        }
    return payload  # already flat top-level shape (SubagentStop / back-compat)


def build_record(payload):
    """Return a schema_version=1 forward record dict, or None to skip."""
    session_id = _first(payload, "session_id", "sessionId") or ""
    description = _first(payload, "description", "label", "agent_description") or ""

    stage = stage_from_description(description)
    if not stage:
        return None  # non-pipeline agent: emit nothing
    issue = issue_from_description(description)

    usage = _extract_usage(payload)
    if usage is None:
        return None  # no usage field at all: fail-open to no record

    tokens = {
        "input": usage.get("input_tokens") or 0,
        "output": usage.get("output_tokens") or 0,
        "cache_read": usage.get("cache_read_input_tokens") or 0,
        "cache_creation": usage.get("cache_creation_input_tokens") or 0,
    }
    tokens["total"] = (
        tokens["input"] + tokens["output"]
        + tokens["cache_read"] + tokens["cache_creation"]
    )

    ts_start = _first(payload, "ts_start", "start_time", "started_at") or ""
    ts_end = _first(payload, "ts_end", "end_time", "ended_at", "timestamp") or ""

    total_duration_ms = payload.get("total_duration_ms")
    if isinstance(total_duration_ms, (int, float)) and not isinstance(total_duration_ms, bool):
        duration_ms = int(total_duration_ms)
    else:
        duration_ms = duration_from_timestamps(ts_start, ts_end)

    model = _first(payload, "model") or ""
    agent_type = _first(payload, "subagent_type") or "unknown"
    source = "forward"
    agent_kind = "inline"

    return {
        "schema_version": 1,
        "record_key": record_key(source, agent_kind, session_id, issue, stage, ts_start),
        "issue": issue,
        "stage": stage,
        "agent_kind": agent_kind,
        "agent_type": agent_type,
        "session_id": session_id,
        "model": model,
        "tokens": tokens,
        "duration_ms": duration_ms,
        "ts_start": ts_start,
        "ts_end": ts_end,
        "source": source,
        "usage_complete": True,
    }


def _flag_from_config(project_dir):
    """Read PIPELINE_LOGS_ENABLED from pipeline.config at project_dir.

    pipeline.config is a bash-sourced KEY=value file; we DO NOT shell out to
    `source` it. Extract the flag with a regex, strip surrounding quotes and
    whitespace, ignore comments. Returns the resolved string value, or None if
    the file is absent / unreadable / has no such assignment. Fail-open: any
    error is swallowed (returns None)."""
    try:
        path = os.path.join(project_dir, "pipeline.config")
        with open(path) as fh:
            text = fh.read()
    except (OSError, ValueError):
        return None
    value = None
    for line in text.splitlines():
        m = re.match(r"\s*(?:export\s+)?PIPELINE_LOGS_ENABLED\s*=\s*(.*)$", line)
        if not m:
            continue
        raw = m.group(1)
        # drop a trailing inline comment only when the value is not quoted
        if raw[:1] not in ("'", '"'):
            raw = raw.split("#", 1)[0]
        raw = raw.strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in ("'", '"'):
            raw = raw[1:-1]
        value = raw.strip()
    return value


def _logging_enabled(project_dir):
    """True only when PIPELINE_LOGS_ENABLED resolves to exactly "true".

    Process env wins; pipeline.config at project_dir is the fallback (the var
    is never exported into the Claude Code process env, so without this the
    hook would early-return every time -- #657)."""
    env_val = os.environ.get("PIPELINE_LOGS_ENABLED")
    if env_val is not None:
        return env_val == "true"
    return _flag_from_config(project_dir) == "true"


def main():
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    if not _logging_enabled(project_dir):
        return  # gate off: write nothing

    logs_dir = os.path.join(project_dir, ".claude", "logs")

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            return
        # Stop branch (#662): a payload carrying `transcript_path` and NO
        # `tool_name` is a Stop event for the main orchestrator session. Route
        # it to the transcript-summing orchestrator record builder and bypass
        # the PostToolUse(Agent) normalisation/stage-gate path.
        if payload.get("transcript_path") and "tool_name" not in payload:
            os.makedirs(logs_dir, exist_ok=True)
            rec = build_stop_record(payload, logs_dir)
            if rec is not None:
                append_locked(
                    Path(logs_dir) / "agent-costs.jsonl",
                    json.dumps(rec),
                )
            return
        payload = _normalize_payload(payload)
        if payload is None:
            return  # non-Agent PostToolUse: no subagent cost to capture
        rec = build_record(payload)
        if rec is None:
            return
        os.makedirs(logs_dir, exist_ok=True)
        append_locked(
            Path(logs_dir) / "agent-costs.jsonl",
            json.dumps(rec),
        )
    except Exception:  # noqa: BLE001 -- fail-open: never block agent completion
        try:
            os.makedirs(logs_dir, exist_ok=True)
            with open(os.path.join(logs_dir, "agent-cost-hook-errors.log"), "a") as fh:
                fh.write(traceback.format_exc() + "\n")
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    main()
    sys.exit(0)
