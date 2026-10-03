# Usage gate (#969) — full detail

> **RED FLAGS — read before acting on any `pause-5h`:**
> 1. **Auto-resume is the DEFAULT on `pause-5h`.** NEVER stop-and-ask the operator "should I resume?" — arm the cron and yield; the cron resumes the campaign on its own.
> 2. **NEVER `ScheduleWakeup`** (or any delay-based one-shot) at `resume_at` — a one-shot is turn-coupled, can fire while still throttled, and is silently superseded by intervening conversation (R2/R3).
> 3. **The ONLY resume mechanism is a recurring `CronCreate` on `13,38 * * * *`** — turn-independent, fires on wall-clock regardless of conversation activity.

**Single source of truth for the usage-aware pause/resume control loop.** `scripts/usage-gate.sh` reads real account usage from the OAuth endpoint behind Claude Code's `/usage` panel and emits ONE deterministic decision line; the script decides, this prose obeys (the `auto-merge-gate.sh` pattern). Call sites below reference this section — no duplicated machinery anywhere. Knobs: `PIPELINE_USAGE_GATE_ENABLED` (default `true`; `false` disables) and `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default `85`, applies to both windows). Spec: `docs/superpowers/specs/2026-06-10-usage-gate-design.md`.

**Invocation (never gate-fatal):**

```bash
GATE_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true)
```

Always relay `$GATE_LINE` in the run log, then branch on its `decision=` token:

- **`decision=proceed` / `decision=skip`** → continue. `skip` ≡ proceed plus an auditable `reason=` (`disabled`, `no-credentials`, `http-<code>`, `fetch-error`, `parse-error`) — the gate is fail-open and NEVER blocks a run on its own failure.
- **`decision=pause-5h`** → the five-hour window is at/over threshold; the outcome is **arm the recurring re-check cron and yield** (the campaign auto-resumes — this is NOT a stop-and-ask). The line's `resume_at=` is `five_hour.resets_at + 5 min` — treated as a **reporting ceiling + blind backstop only**, NOT a resume time (the endpoint over-states recovery; see spec #1016 R1):
  1. Report the remaining slate in ONE line — the issue numbers not yet at `pr-open`/merged.
  2. **Emit the arming spec deterministically, then transcribe it into ONE `CronCreate` call.** Run:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/arm-usage-resume-cron.sh" \
       --resume-command "<the exact /pipeline:fullsend command you are running>" \
       --resume-at <resume_at from this gate line>
     ```

     then make ONE `CronCreate` call with EXACTLY its emitted args. **Do NOT hand-reconstruct the schedule/marker/prompt** — the script now SOURCES those tokens (fixed `13,38 * * * *` cadence, marker `usage-resume re-check`, the fully-assembled **re-check firing contract** prompt, the `resume_at` value, the `/pipeline:fullsend <remaining issue numbers> <original flags>` resume command form, and the "resumed after usage pause; delete the usage-resume cron if present" idempotency note). The cron id does not exist until `CronCreate` returns, so "delete self" means `CronList` → match the marker → `CronDelete`. Report: remaining slate + "worst-case resume by `<resume_at>`" + the cron id.
  3. STOP the turn. Labels untouched; in-flight agents have already drained (the gate runs only BETWEEN waves — pause = do not dispatch the next wave).

  **`ScheduleWakeup` is NEVER the resume mechanism.** Do not arm a `ScheduleWakeup` (or any delay-based one-shot) at `resume_at` — a one-shot can fire while still throttled and is turn-coupled, so intervening conversation silently supersedes it (R2/R3). The recurring `CronCreate` above is the single, turn-independent mechanism.

  **Re-check firing contract** (each cron firing is a deliberately tiny turn): run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"`, relay the line, then branch on its `decision=`:
  - **`proceed`** → `CronList` → match marker `usage-resume re-check` → `CronDelete` self, then fire the resume command.
  - **`pause-5h`** → STOP the turn (one line). The cron PERSISTS; the next firing re-checks. A firing killed by the account cap self-heals — the cron recurs (this resilience is the core win over the one-shot).
  - **`halt-7d`** → `CronList` → `CronDelete` self, then a LOUD report (seven-day %, reset date, exact manual resume command). NEVER auto-resume a seven-day trip.
  - **`skip`** → NEVER resume on `skip` (a paused headless host has an ~hourly-expiring OAuth token; fail-open on `http-401` would resume at ~99%, R4) UNLESS `now ≥ resume_at + 10 min` → treat as `proceed` (R5 blind backstop — never worse than the old one-shot, even when the endpoint is unreadable). Otherwise STOP; the cron persists and the next firing's session refreshes creds.
- **`decision=halt-7d`** → same stop, NO schedule (a seven-day reset can be days away — never auto-resume). Loud report: the seven-day utilization %, the reset date, and the exact manual resume command (`/pipeline:fullsend <remaining issue numbers> <original flags>`).

**On resume** the pre-flight gate re-checks naturally: still over threshold → re-pause/halt again (re-arming the recurring re-check cron). A headless re-check firing with an expired access token degrades fail-open (`skip reason=http-401`); the re-check contract's `skip` branch governs it — the cron persists and the next firing re-checks once the session has refreshed creds, so a stale-token firing never resumes at ~99% (R4).

**Call sites** (each points here; one-line references only):
1. **Pre-flight** — before wave 1 of ANY stage (classify, plan, and execute waves all burn budget).
2. **Top of EVERY wave iteration** — the Step 1b classify/plan waves AND the `### Execute the slate WAVE BY WAVE` loop (before Step 5).
3. **Campaign leg boundary** — `## Campaign mode` (e)3, BESIDE the `usage-surface.sh` advisory (which stays read-only per #725; different substrate, untouched).
