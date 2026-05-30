#!/usr/bin/env python3
"""capture_agent_cost.py -- forward agent token-cost capture hook (dogfood-only).

Registered on SubagentStop and Stop. This is the DURABLE, ACCURATE forward
cost source: it records cumulative token usage at agent finish, in contrast to
the retroactive log-scanning parser in scripts/capture-agent-costs.sh.

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


def main():
    if os.environ.get("PIPELINE_LOGS_ENABLED") != "true":
        return  # gate off: write nothing

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
    logs_dir = os.path.join(project_dir, ".claude", "logs")

    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
        if not isinstance(payload, dict):
            return
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
