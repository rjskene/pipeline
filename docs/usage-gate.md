# Usage Gate — Auto-Pause & Auto-Resume

The usage gate stops a fullsend/campaign run before it blows through the
operator's plan usage limit, then resumes once the usage window has actually
recovered. It is **on by default** and **fails open** — any error degrades to a
warning, never a blocked run.

The gate is a pure reader + decision (`scripts/usage-gate.sh`): it reads real
account usage and emits one decision line; the skill prose obeys the line and
does the scheduling. Same script-decides pattern as `auto-merge-gate.sh`.

## How it decides

The gate reads real account-wide usage via the OAuth `/usage` endpoint (the
same data Claude Code's `/usage` panel shows — all sessions/devices, not a
local estimate) and emits exactly ONE decision line on stdout:

```
usage-gate: decision=<proceed|pause-5h|halt-7d|skip> five_hour=..% seven_day=..% threshold=85 resume_at=..
```

**Decision precedence** (first match wins):

1. `seven_day >= threshold` → **`halt-7d`** (wins over pause-5h). NO
   auto-resume — a seven-day reset can be days away.
2. else `five_hour >= threshold` → **`pause-5h`** (auto-resume — see below).
3. else → **`proceed`**.

Threshold is a percentage applied to BOTH windows (`PIPELINE_USAGE_GATE_THRESHOLD_PCT`,
default `85`). The boundary trips (`>=`): utilization exactly equal to the
threshold pauses/halts.

## Auto-pause (pause-5h / halt-7d)

When the gate trips, the run stops at a wave/leg boundary — in-flight agents
have already drained, so "pause" means "do not dispatch the next wave". Labels
are untouched; re-entry re-reads label state, so a resume is always safe.

- **`pause-5h`** — the five-hour window is over threshold. The run reports the
  remaining slate and arms auto-resume (see below), then STOPs the turn.
- **`halt-7d`** — the seven-day window is over threshold. Same stop, but NO
  schedule is armed. The report is loud: seven-day utilization %, reset date,
  and the exact manual resume command. A seven-day trip is never auto-resumed.

On `pause-5h` the decision line carries
`resume_at = five_hour.resets_at + 5 min`. Treat this as a **reporting ceiling
and a blind backstop, NOT a literal resume time** — per #1016, the endpoint's
`resets_at` over-states real recovery (observed ≥1h35m pessimistic). The actual
resume is driven empirically by the re-check loop, not by this timestamp.

## Auto-refire (recurring re-check resume)

`pause-5h` resume is driven by a **recurring re-check cron** (fixed ~25-min
off-minute cadence; not a knob), not a one-shot at `resume_at`. The endpoint's
`resets_at` is an unreliable, sometimes hours-pessimistic ceiling, so the gate
resumes empirically — on the first `proceed`, not at a projected time.

Each firing re-runs `usage-gate.sh` and branches on the decision line:

- `proceed` → delete the cron, fire the resume command
  (`/pipeline:fullsend <remaining issues> <original flags>` — idempotent,
  re-reads label state).
- `pause-5h` → stop the turn; the cron persists and the next firing retries.
- `halt-7d` → delete the cron, loud report, stop. Never auto-resume a 7d trip.
- `skip` → stop and let the cron persist (a paused headless host has an
  ~hourly-expiring OAuth token; resuming on a fail-open `skip` would resume at
  ~99%). **Backstop:** if `now >= resume_at + 10 min` and the decision is still
  `skip`, resume anyway — never worse than the old one-shot, even when the
  endpoint is unreadable.

A firing killed by the account cap self-heals: the cron recurs and the next
firing retries. This resilience is the core win over the old one-shot arm.

## Fail-open & configuration

The gate NEVER blocks a run on its own failure. Any error path —
no credentials, HTTP error, network failure, or unparseable body — degrades to
`skip` + a warning and the run proceeds. The script always exits 0 and always
emits exactly one stdout line.

- **Kill switch:** `PIPELINE_USAGE_GATE_ENABLED=false` opts out entirely
  (`skip reason=disabled`).
- **Threshold:** `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default `85`), applied to
  both windows.
- **API-key installs** have no `~/.claude/.credentials.json` → a permanent,
  graceful `skip reason=no-credentials`. The gate is NOT dogfood-gated; it works
  for any subscription-auth operator.

## Design provenance

- `docs/superpowers/specs/2026-06-10-usage-gate-design.md` (#969) — the
  original gate: decision logic, thresholds, fail-open invariant, and the
  decision-line contract.
- `docs/superpowers/specs/2026-06-12-usage-gate-recheck-resume-design.md`
  (#1016) — the recurring re-check resume that supersedes the original
  one-shot arming, plus the decision breadcrumb. Demotes `resets_at` to a
  reporting ceiling / blind backstop.

Implementation: `scripts/usage-gate.sh`.
