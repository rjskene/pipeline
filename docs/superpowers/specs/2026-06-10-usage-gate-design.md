# Usage-Aware Pause/Resume (Usage Gate) — Design

**Issue:** #969 (brainstorm → actionable on approval of this spec)
**Date:** 2026-06-10
**Status:** Approved design, pending implementation plan

## Problem

During a fullsend/campaign run the pipeline can blow through the operator's
plan usage limit mid-slate. #725 (`scripts/usage-surface.sh`) shipped the
read-only advisory but deliberately dropped the control loop. This design
revives that control loop: near the limit, stop at a safe checkpoint and
auto-resume after the usage window resets.

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| D1 | Usage signal | **Real account usage** via the OAuth usage endpoint (`https://api.anthropic.com/api/oauth/usage`) — the same data Claude Code's `/usage` panel shows. NOT the local `agent-costs.jsonl` estimate, NOT a website scrape. |
| D2 | Window policy | Gate on BOTH windows at one threshold. `five_hour` trip → pause + **auto-resume** at reset. `seven_day` trip → **halt-and-report only**, never auto-resume (reset can be days away). Both over → halt wins. |
| D3 | Enablement | **On by default (opt-out)** via `PIPELINE_USAGE_GATE_ENABLED=false` kill switch. **Fail-open**: any error (no creds, endpoint change, HTTP failure) = `skip` + warn, never blocks a run. |
| D4 | Architecture | **Script decides.** `scripts/usage-gate.sh` emits a deterministic decision token; SKILL.md prose obeys the token and performs scheduling. Same pattern as `auto-merge-gate.sh`. Golden-file testable. |

## Signal: probe evidence (2026-06-10)

`GET https://api.anthropic.com/api/oauth/usage` with
`Authorization: Bearer <accessToken from ~/.claude/.credentials.json>` and
`anthropic-beta: oauth-2025-04-20` returned HTTP 200:

```json
{
  "five_hour": {"utilization": 20.0, "resets_at": "2026-06-10T20:59:59+00:00"},
  "seven_day": {"utilization": 27.0, "resets_at": "2026-06-15T02:00:00+00:00"},
  "seven_day_sonnet": {"utilization": 0.0, "resets_at": "..."},
  "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 2982.0, "utilization": 59.64, "currency": "USD"}
}
```

Exactly the two numbers the control loop needs — true account-wide
`utilization` (all sessions/devices) and the authoritative `resets_at`
timestamp (no rolling-window guesswork). Works headless (no browser auth).
Caveats: undocumented endpoint (shape may change → fail-open) and the access
token expires ~hourly (refreshed by any running Claude Code session; expiry
→ HTTP 401 → `skip`).

## Component: `scripts/usage-gate.sh` (new)

Pure reader + decision. No writes, no scheduling, no label changes.

**Inputs**

- Env: `PIPELINE_USAGE_GATE_ENABLED` (default `true`),
  `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default `85`, applies to both windows).
- Flags (testability, mirroring `usage-surface.sh`):
  - `--fixture PATH` — canned endpoint JSON response; no network.
  - `--now ISO8601` — injected clock for deterministic `resume_at` math.
  - `--threshold N` — override threshold.
  - `--credentials PATH` — override creds path (default `~/.claude/.credentials.json`).

**Output contract** — exactly ONE line on stdout; **always exit 0** (never
gate-fatal):

```
usage-gate: decision=proceed  five_hour=20% seven_day=27% threshold=85 resume_at=--
usage-gate: decision=pause-5h five_hour=91% seven_day=40% threshold=85 resume_at=2026-06-10T21:04:59Z
usage-gate: decision=halt-7d  five_hour=12% seven_day=93% threshold=85 resume_at=--
usage-gate: decision=skip reason=disabled five_hour=-- seven_day=-- threshold=85 resume_at=--
```

**Decision rules**

1. `PIPELINE_USAGE_GATE_ENABLED=false` → `skip reason=disabled`.
2. Creds file missing/unreadable or token absent → `skip reason=no-credentials`.
3. HTTP non-200 → `skip reason=http-<code>`. Malformed/unparseable body →
   `skip reason=parse-error`. Curl/network failure → `skip reason=fetch-error`.
4. `seven_day.utilization >= threshold` → `halt-7d` (wins over pause-5h).
5. else `five_hour.utilization >= threshold` → `pause-5h`,
   `resume_at = five_hour.resets_at + 5 minutes` (fixed buffer, not a knob).
6. else → `proceed`.

**Security:** the bearer token is never printed, logged, or echoed — held in
a shell variable only; curl errors redirected; tests grep stdout+stderr for
token leakage.

## Integration points (prose changes)

All call sites invoke the script and branch on `decision=`:

1. **`skills/fullsend/SKILL.md`** — pre-flight before wave 1, and at the top
   of EVERY wave iteration (classify, plan, and execute waves all burn
   budget). The gate runs BETWEEN waves, so in-flight agents have already
   drained — "pause" = do not dispatch the next wave. Labels untouched.
2. **`skills/fullsend/SKILL.md` `## Campaign mode`** — leg-boundary check
   alongside the existing `usage-surface.sh` advisory (which is UNTOUCHED —
   different substrate, stays #725 read-only). `/pipeline:campaign` inherits
   by reference.
3. **`skills/status/SKILL.md`** — Step 0 housekeeping relays the gate line
   advisory-only; status is read-only and NEVER pauses or schedules.

**On `pause-5h`:**

- Report the remaining slate in one line.
- Schedule the resume: `delta = resume_at - now`; if `delta <= ~55 min` →
  `ScheduleWakeup(delaySeconds=delta)`; else → `CronCreate` one-shot at
  `resume_at` (absolute time; a five-hour reset can be up to ~5 h away).
- Resume prompt is self-describing and idempotent:
  `/pipeline:fullsend <remaining issue numbers> <original flags>` plus
  "resumed after usage pause; delete the usage-resume cron if present"
  (re-entry re-reads label state, so a blind resume is safe).
- STOP the turn.

**On `halt-7d`:**

- Same stop; NO schedule. Loud report: seven-day utilization %, reset date,
  and the exact manual resume command.

**On resume:** the fullsend pre-flight gate re-checks naturally — still over
threshold → re-pauses or halts again. Headless-resume token expiry is safe:
gate skips fail-open, the run proceeds, and the next wave boundary re-checks
once the session has refreshed creds.

## Configuration (`pipeline.config.example`)

```bash
# --- #969 usage gate: pause near plan limit, auto-resume after reset ---
# Real account usage via the OAuth endpoint behind Claude Code's /usage.
# Opt-out kill switch; fail-open on any error (skip + warn, never blocks).
#PIPELINE_USAGE_GATE_ENABLED="true"        # set false to disable the gate
#PIPELINE_USAGE_GATE_THRESHOLD_PCT="85"    # both windows; 5h→pause+resume, 7d→halt
```

Works for any subscription-auth operator (no `PIPELINE_LOGS_ENABLED`
dependency — this is NOT dogfood-gated). API-key installs have no
`~/.claude/.credentials.json` → permanent graceful `skip reason=no-credentials`.

## Testing (`tests/test-usage-gate.sh`)

Fixture-driven via `--fixture` + `--now` + `--threshold`:

1. Under threshold → `decision=proceed`.
2. `five_hour` over → `decision=pause-5h`, `resume_at` = `resets_at` + 5 min
   (exact arithmetic asserted against `--now`).
3. `seven_day` over → `decision=halt-7d`, `resume_at=--`.
4. BOTH over → `halt-7d` wins.
5. Threshold boundary: utilization == threshold trips (>=).
6. Malformed JSON fixture → `skip reason=parse-error`.
7. Missing creds file → `skip reason=no-credentials`.
8. `PIPELINE_USAGE_GATE_ENABLED=false` → `skip reason=disabled`.
9. Token-leak guard: a fake token planted in a fixture creds file never
   appears in stdout/stderr.
10. Exit code 0 in every case above.

CI has no creds → any live-path execution naturally exercises `skip`.
New `PIPELINE_USAGE_GATE_*` vars are documented in `pipeline.config.example`,
satisfying `check-config-drift.sh` (no allowlist entry needed).

## Issue hygiene

On spec approval: commit this doc, then flip #969 from `brainstorm` to
actionable — retitle to `feat(usage-gate): pause at usage threshold,
cron-resume after 5h reset; halt on 7d`, replace the body with the scoped
actionable shape referencing this spec. No duplicate child issue.

## Out of scope (v1)

- **Mid-wave abort** — the gate only acts at wave/leg boundaries.
- **`extra_usage` credit gating** — the probe shows overage-credit state
  (`is_enabled`, `utilization`); when extra usage is enabled, "near limit"
  means "about to spend credits", and pausing is still the right default.
  Gating on credit utilization is a deferred follow-up signal.
- **Consumer/#722 phase-2 substrate work** — unrelated; this gate already
  works for subscription-auth consumers by construction.
- **Website scrape (B2) / whole-host transcript parsing (B3)** — rejected
  alternatives; see D1.
- **Changes to `usage-surface.sh`** — stays read-only advisory per #725.

## Related

- #969 — the brainstorm this design refines.
- #725 — `usage-surface.sh` read-only advisory (untouched substrate).
- #722 — deferred consumer-path usage substrate (orthogonal).
- `scripts/auto-merge-gate.sh` — the script-decides pattern this follows.
