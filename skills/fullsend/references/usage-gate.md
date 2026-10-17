# Usage gate — full detail

> **Rules for `pause-5h`:**
> 1. **Auto-resume is the DEFAULT.** Never stop-and-ask "should I resume?" — arm the cron and yield.
> 2. **NEVER `ScheduleWakeup`** (or any delay-based one-shot) at `resume_at` — it is turn-coupled and can fire while still throttled.
> 3. **The ONLY resume mechanism is a recurring `CronCreate` on `13,38 * * * *`** — turn-independent.

`scripts/usage-gate.sh` reads real account usage (the endpoint behind `/usage`) and emits ONE decision line; the script decides, this prose obeys. Knobs: `PIPELINE_USAGE_GATE_ENABLED` (default `true`) and `PIPELINE_USAGE_GATE_THRESHOLD_PCT` (default `85`, both windows). Spec: `docs/superpowers/specs/2026-06-10-usage-gate-design.md`.

**Invocation (never gate-fatal):**

```bash
GATE_LINE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh" || true)
```

Relay `$GATE_LINE` in the run log, then branch on `decision=`:

- **`decision=proceed` / `decision=skip`** → continue. `skip` carries an auditable `reason=` (`disabled`, `no-credentials`, `http-<code>`, `fetch-error`, `parse-error`); the gate is fail-open.
- **`decision=pause-5h`** → arm the recurring re-check cron and yield (NOT a stop-and-ask). `resume_at=` (`five_hour.resets_at + 5 min`) is a reporting ceiling and blind backstop only, NOT a resume time:
  1. Report the remaining slate (issues not yet `pr-open`/merged) in ONE line.
  2. Emit the arming spec, then make ONE `CronCreate` call with EXACTLY its args:

     ```bash
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/arm-usage-resume-cron.sh" --resume-command "<the exact /pipeline:fullsend command you are running>" --resume-at <resume_at from this gate line>
     ```

     Do NOT hand-reconstruct it: the script sources the `13,38 * * * *` cadence, the marker `usage-resume re-check`, the re-check firing-contract prompt, `resume_at`, and the `/pipeline:fullsend <remaining issue numbers> <original flags>` resume command. "Delete self" means `CronList` → match the marker → `CronDelete`. Report the slate, "worst-case resume by `<resume_at>`" and the cron id.
  3. STOP the turn. Labels untouched; the gate runs only BETWEEN waves.

  **Re-check firing contract** (each firing is a tiny turn): run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/usage-gate.sh"`, relay the line, then:
  - **`proceed`** → `CronList` → match `usage-resume re-check` → `CronDelete` self, then fire the resume command.
  - **`pause-5h`** → STOP; the recurring cron persists and re-checks next firing.
  - **`halt-7d`** → `CronList` → `CronDelete` self, then a LOUD report (seven-day %, reset date, manual resume command). Never auto-resume.
  - **`skip`** → do not resume (an expired token reads `http-401` at ~99% usage) UNLESS `now ≥ resume_at + 10 min` → treat as `proceed`. Otherwise STOP; the cron persists.
- **`decision=halt-7d`** → stop, NO schedule. Loud report: seven-day utilization %, reset date, and the manual resume command (`/pipeline:fullsend <remaining issue numbers> <original flags>`).

**On resume** the pre-flight gate re-checks; still over threshold ⇒ re-pause (re-arm) or halt.

**Call sites:** (1) pre-flight, before wave 1 of any stage; (2) the top of EVERY plan and execute wave (before Step 5); (3) each campaign leg boundary, beside the read-only `usage-surface.sh` advisory.
