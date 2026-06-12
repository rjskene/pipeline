# Usage-Gate Recurring Re-Check Resume + Decision Breadcrumb — Design

**Issue:** #1016 (brainstorm → actionable on approval of this spec)
**Date:** 2026-06-12
**Status:** Approved design, pending implementation plan
**Supersedes:** the `pause-5h` arming prose of
`docs/superpowers/specs/2026-06-10-usage-gate-design.md` (#969). The gate's
decision logic, thresholds, and decision-line contract are NOT changed.

## Problem

The #969 gate arms the pause-5h resume as a ONE-SHOT at
`resume_at = five_hour.resets_at + 5 min`, trusting the endpoint's
`resets_at` as authoritative. Live campaign evidence (work-orchestrator,
2026-06-10/11, four pause events) shows `resets_at` is an **unreliable,
sometimes hours-pessimistic ceiling** — not a resume time.

### Evidence (transcript-verified, fddb2fba campaign session)

| # | Pause (UTC) | 5h% | Endpoint `resume_at` | Cron armed | Observed outcome |
|---|---|---|---|---|---|
| 1 | Jun10 19:52 | 99% | 22:15Z | none — turn died | 11% at 23:56 (#1014 stall) |
| 2 | Jun11 00:44 | 89% | 04:35Z | 04:38, killed 02:56 | **2% at 02:55 — window recovered ≥1h35m before the endpoint's `resets_at`** |
| 3 | Jun11 08:46 | 99% | 12:45Z | 12:47, killed 12:43 | 44% at 13:18 (post-reset) |
| 4 | Jun11 14:07 | 95% | 17:45Z | 17:47, killed 17:46 | 37% at 18:04 (post-reset) |

Findings:

- Every armed cron was **faithful to the gate line** (+2–3 min). The
  arming step was not the bug; the original #1016 "+5h regardless" premise
  and the "fell to 44%/37% far before resume_at" framing are both refuted
  (those readings were post-reset new-window spend).
- The endpoint's `resets_at` over-stated real recovery by ≥1h35m in the
  ONLY pause where anyone sampled early (pause 2). Pauses 3/4 are merely
  unexamined — no early sample exists. There is zero evidence `resets_at`
  was ever exactly right, and one proof it was hours wrong.
- Window semantics are opaque (dynamic capacity-based limits, undocumented
  endpoint), so **projection math is unjustifiable**. The original #1016
  "projected window drain" idea is rejected for the same reason
  `resets_at`-trust is: both model a window whose own API misreports it.
- Forensics required ~1h of transcript archaeology because no decision
  breadcrumb exists (#1014 Q3).

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| R1 | Resume mechanism | **Recurring re-check cron** (~every 25 min, off-minute), resume on first `proceed`. Empirical — no window model. `resets_at` demoted to reporting ceiling + blind backstop. |
| R2 | Arming branches | **Single mechanism.** Drop the `ScheduleWakeup ≤55min` branch — always one recurring `CronCreate`. One tool call, smaller turn-death window; pauses are empirically 2–4h. |
| R3 | Cadence | Fixed ~25 min, off-minute (e.g. `13,38 * * * *`). NOT a knob (precedent: the +5 min buffer in #969). |
| R4 | `skip` during re-check | **Never resume on `skip`.** A paused headless host has an ~hourly-expiring OAuth token; fail-open on `http-401` would resume at ~99%. Cron persists; the next firing's session refreshes creds. |
| R5 | Blind backstop | If `now ≥ resume_at + 10 min` and the decision is still `skip` → resume anyway. Never worse than the old worst-case one-shot, even when the endpoint is unreadable. |
| R6 | Breadcrumb | `usage-gate.sh` appends one JSONL line per invocation to `$PIPELINE_PROJECT_ROOT/.claude/logs/usage-gate.jsonl`, gated by `PIPELINE_LOGS_ENABLED=true` (namespace policy: consumer `.claude/logs/` writes are opt-in). Never fatal, no token material. Satisfies #1014 Q3. |
| R7 | Gate logic | **Untouched.** Decision order, thresholds, decision-line contract, fail-open invariant all unchanged. The breadcrumb is the only new side effect. |

## Component changes

### 1. `scripts/usage-gate.sh` — breadcrumb only

- In `emit()`, before printing the decision line: when
  `PIPELINE_LOGS_ENABLED=true` and `$PIPELINE_PROJECT_ROOT` (or `pwd`)
  resolves, append to `.claude/logs/usage-gate.jsonl`:

  ```json
  {"ts":"<NOW>","decision":"<tok>","reason":"<r|null>","five_hour":"<N%|-->","seven_day":"<N%|-->","threshold":"<N>","resume_at":"<ISO|-->"}
  ```

- Append failure is silently ignored (the always-exit-0 / single-stdout-line
  invariants hold). The token-leak canary grep extends to the log file.
- Over time this dataset adjudicates `resets_at` accuracy empirically.

**Trade-off (accepted):** consumer hosts with logs off (the default) stay
crumb-less — the work-orchestrator incidents would NOT have been captured.
Strict gating wins for namespace-policy consistency; revisit if a consumer
incident recurs undiagnosable.

### 2. `skills/fullsend/SKILL.md` `## Usage gate (#969)` — arming prose

Replace step 2 of the `pause-5h` branch:

- **Arm a recurring re-check cron** (~every 25 min, off-minute) whose
  prompt is the re-check contract below. No `ScheduleWakeup` branch, no
  one-shot. Report: remaining slate (one line) + "worst-case resume by
  `<resume_at>`" + the cron id.
- STOP the turn (unchanged).

### 3. Re-check firing contract (cron prompt — deliberately tiny turn)

The prompt embeds: the gate script path, the marker `usage-resume re-check`
(the cron id does not exist until `CronCreate` returns, so "delete self" =
`CronList` → match the marker → `CronDelete`), `resume_at` from the pausing
gate line, and the existing self-describing resume command
(`/pipeline:fullsend <remaining issues> <original flags>` — unchanged,
idempotent, re-reads label state). Each firing:

1. Run `usage-gate.sh`; relay the line. Branch on `decision=`:
   - `proceed` → `CronDelete` self, then fire the resume command.
   - `pause-5h` → stop the turn (one line). Cron persists.
   - `halt-7d` → `CronDelete` self, loud report (7d %, reset date, manual
     resume command), stop. Never auto-resume a 7d trip.
   - `skip` → if `now ≥ resume_at + 10 min` → treat as `proceed` (R5
     backstop); else stop, cron persists (R4).
2. A firing killed by the account cap self-heals: the cron recurs and the
   next firing retries. This resilience is the core win over the one-shot.

### 4. Out-of-band cleanup

The resume prompt already says "delete the usage-resume cron if present";
that line stays — covers the manual-resume race (operator returns before a
firing). `CronDelete` of an already-deleted cron is a no-op.

## Call sites / unchanged surfaces

- `skills/status/SKILL.md` housekeeping stays advisory-only (relay line,
  never pause/schedule/arm).
- Campaign leg-boundary and wave-top call sites inherit by reference to
  `## Usage gate (#969)` — no per-site edits beyond the section itself.
- `usage-surface.sh` (#725) untouched.

## Testing

Extend `tests/test-usage-gate.sh` (fixture-driven):

1. `PIPELINE_LOGS_ENABLED=true` + fixture → exactly one valid JSONL line
   appended with matching decision/fields; decision line unchanged.
2. `PIPELINE_LOGS_ENABLED` unset/false → no log file created/written.
3. Unwritable logs dir → decision line still emitted, exit 0.
4. Token-leak canary grep covers `usage-gate.jsonl`.
5. All existing decision-line golden assertions pass unmodified (R7).

Prose changes (arming + re-check contract) are skill-text; covered by the
existing skill-contract test substrate where applicable.

No new `PIPELINE_*` vars → no `pipeline.config.example` /
`check-config-drift.sh` changes.

## Issue hygiene

On spec approval:

- Comment the evidence table + findings on #1016; retitle to
  `feat(usage-gate): recurring re-check resume + decision breadcrumb
  (resets_at is an unreliable ceiling)`; replace body with the actionable
  shape referencing this spec; drop `brainstorm` label.
- Cross-comment on #1014: Q3 satisfied here (R6); Q1 (predictive tripping)
  and Q2 (turn-death before arming — pause 1 had zero inference window to
  arm anything; script-side durable arming still open) remain #1014's.

## Out of scope

- **Projected-drain computation** — rejected (semantics unmodelable; see
  Evidence).
- **#1014 Q1** (predictive/threshold-headroom tripping) and **Q2**
  (script-side durable arming) — remain open on #1014.
- **Always-on breadcrumb** (ungated) — rejected for namespace policy;
  revisit on a recurrence that strict gating leaves undiagnosable.
- **Cadence knob** — fixed 25 min; no config surface.

## Related

- #1016 — the brainstorm this design re-premises and refines.
- #1014 — sibling incident brainstorm (Q1/Q2 remain; Q3 satisfied by R6).
- #969 / `docs/superpowers/specs/2026-06-10-usage-gate-design.md` — the
  gate this design amends (arming prose only).
- #725 — `usage-surface.sh` advisory (untouched).
