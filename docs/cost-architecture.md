# Cost & Billing Architecture — Analysis & Path-2 Decision

**Date:** 2026-05-31 · **Status:** decision recorded, build queued · **Epic:** #450

This doc captures a full cost/billing analysis of the pipeline and the strategic
decision it forced. It is the durable record behind issues #721, #723, #707,
#725, #648, #724 (all under epic #450).

---

## TL;DR

- The pipeline's real compute cost is **~$15.8k over 17 days (~$900–1000/day list-price-equivalent)** — masked until now by subscription billing.
- **94% of it is `claude -p` worker stages** (execute 74% + pr-eval 20%); **output tokens are the #1 cost driver (37%) and are uncacheable.**
- The **2026-06-15 billing change** meters `claude -p`/Agent-SDK usage on subscription against a tiny separate credit (Max 20x = **$200/mo ≈ 5–8 hours** of load), then bills standard API rates. The subscription subsidy on automated work is going away.
- **Decision: Path 2** — keep work on the subscription's *interactive pool* by running execute+pr-eval as **inline subagents from a human-attended orchestrator**, `claude -p` opt-in. As of #749/#891/#896 this now applies to PATH C as well: C execute/PR-eval fan out inline by default (one `tdd-implementer` per `target=<dir>` leaf in its own per-leaf worktree, reassembled by cherry-pick), with `--spawn` as the opt-in legacy `claude -p` worker transport. Path 1 (API-key, full automation) is the documented later-option.
- **Two parallel workstreams, both required:** migrate to inline (#723/#707) AND drive down tokens (#648/#420/#700).
- **Everything gates on #721** (measurement) — it also produces the execute-concurrency assessment that sizes the migration and feeds the governor.
- **Model-tier lever (shipped, default-off):** a third axis — routing the **execute** stage to cheaper Sonnet
  on the eligible low-blast lane — landed after this analysis. It is gated by the host vars
  `PIPELINE_PATH_B_MODEL_EXECUTE` / `PIPELINE_PATH_D_MODEL_EXECUTE` (+ the `PIPELINE_PATH_B_ELIGIBLE_SCOPE`
  scope knob), with **pr-eval always staying Opus**. Full decision + the ~80% execute-cost ratio in
  [analysis/model-downsampling.md](analysis/model-downsampling.md).

---

## Critical Path

```
#721  tokenomics skill — backfill + 3-dim report + per-day window (--since/--until/--per-day) + per-N/per-LOC columns + durable history snapshot + execute-concurrency assessment
  │     (THE GATE: produces cost numbers, the concurrency ceiling, and the governor's data feed)
  ├─→ #725  usage-governor (opt-in sustained-cap pacing)      ← consumes #721 capture
  ├─→ #723  inline migration (P1, primary architecture)        ← needs concurrency ceiling
  │     └─ #707  feature-based B→D routing (first concrete slice)
  └─→ #648  terser templates (P1)  +  #420  over-eval downsampling   ← run in parallel, path-agnostic

PARKED:  #724  autonomous cron relay → Path-1-only (needs headless orchestrator; incompatible with attended Path 2)
DONE:    #700  PATH D collapse
```

**Recommended sequence:** #721 first (unblocks all) → #648 in parallel (pure win) → #723 decomposition once #721 gives the rate-limit ceiling.

---

## 1. Trigger — the usage-data audit

Auditing `.claude/logs/agent-costs.jsonl` (producer: `hooks/capture_agent_cost.py`,
PostToolUse(Agent)+Stop, #642/#660) found the **execute stage was ~98% blind**: only
2 records, both PATH D *inline* agents in the orchestrator session. All 31 PATH B +
5 PATH C executes run in spawned `claude -p` workers (separate sessions) → captured by
the live hook **zero** times. The hook is PostToolUse(**Agent**); it cannot see
Bash→tmux→`claude -p` workers.

**Fix (dogfood-correct):** the retroactive pass `scripts/capture-agent-costs.sh`
(HEADLESS pass) reads `runs.log` (386 entries) → resolves each worker's transcript at
`~/.claude/projects/<slug>/<session>.jsonl` → sums real worker tokens. Running it
backfilled **execute from 2 → 249 records** spanning the full history #28→#718.

Key correction: **worker transcripts live in `~/.claude/projects/`, OUTSIDE the
worktree** — worktree cleanup does NOT lose them (corrects #697's premise). The only
decay is `~/.claude/projects` rotation → run the backfill periodically (the skill, not
the runtime path). Embedding capture into `spawn-claude.sh` would be a consumer-footprint
change = NOT dogfood; the retroactive repo-local pass is the correct shape.

---

## 2. Cost breakdown — deduped baseline (2026-05-14 → 2026-05-31, ~17 days)

**Dedupe rule (required before totaling):** collapse records by
`(session_id, issue, stage)` keeping the **max-total** record. Removes exact
`record_key` collisions, retroactive-inline lower-bounds overlapping the forward hook,
and N orchestrator cumulative-snapshots → final cumulative. **Preserves genuine
multi-session re-runs** (e.g. #312 executed in 3 distinct sessions = 3 real executes —
the correct reading of #698: re-runs in different sessions are real, only same-session
multi-capture is the double-count). Effect: 1456 → 1120 records, total −3.6% (execute
unaffected = clean).

**Grand total ≈ $15,776** (list-price estimate, Opus: input $15 / output $75 /
cache-write $18.75 / cache-read $1.50 per 1M tokens).

### By session structure
| structure | $ | share |
|---|---|---|
| spawn (`claude -p` workers, headless) | $14,954 | **94.8%** |
| in-session (orchestrator main + inline Agents) | $823 | 5.2% |

> ⚠️ The in-session figure is **undercounted** — inline subagent capture records only
> one turn (see §3), not the full loop. The execute/pr-eval *stage* dominance is real;
> the structure split is not fully trustworthy on the cache buckets.

### By stage
| stage | $ | share |
|---|---|---|
| execute | $11,646 | 73.8% |
| pr-eval | $3,207 | 20.3% |
| orchestrator | $744 | 4.7% |
| plan + plan-eval + classify | ~$179 | 1.1% |

**execute + pr-eval = 94% of spend.** Classify/plan optimization is rounding error.

### By token bucket — token share ≠ cost share
| bucket | tokens | % tokens | $ | % cost |
|---|---|---|---|---|
| output | 78M | 2.2% | $5,865 | **37.2%** |
| cache_creation | 268M | 7.6% | $5,029 | 31.9% |
| cache_read | 3,192M | **90.0%** | $4,788 | 30.4% |
| input | 6M | 0.2% | $95 | 0.6% |

**Output is the #1 cost driver (37%) and is uncacheable** — caching's 90% discount makes
cache_read only the #3 cost bucket despite being 90% of tokens. ⇒ **the highest-leverage
lever is reducing output** (terser commits/verdicts, fewer turns) → #648 is the keystone.

### Per-day trend — outlier *days* dominate
May 29 ($3,669) + May 30 ($4,623) = **$8,292 = 53% of the entire 17-day total**, with
output%-of-cost spiking 21% → 62%. A couple of large execute sessions can dominate a
window — day-level granularity is required, not just per-issue.

---

## 3. Understanding cache_read (the "billions of tokens" puzzle)

cache_read is **not** a session-startup cost — that's `cache_creation` (writing the
context to cache once, billed 1.25× input). **cache_read is the per-turn re-reading of
the already-cached context, billed 0.1× (90% off).**

An agent doesn't make one API call — it makes dozens (read→think→edit→test→…). **Every
call re-sends the whole conversation so far** as its prompt; that re-sent prefix is
served from cache = cache_read. So cache_read = **(agent loop length) × (context size),
at a 90% discount** — it scales with how many tool-calls the agent makes and how big its
context is, NOT with how the session was launched.

Proof: across execute workers, `cache_read ÷ cache_creation ≈ 17–44×` (e.g. #69 = 34×) —
that ratio literally counts the agentic turns. 2.29B cache_read across 223 workers ≈ each
re-reading a ~100–800k context ~30 times. There is no 2.29B-token cache; it's a modest
prefix re-read across the loop.

**Inline-agent undercount:** inline subagent records show ~1000× less cache_read than an
equivalent worker (#709 inline execute = 32k vs worker = ~28M) because the
PostToolUse(Agent) hook captures only a **single turn** (final summary: input=2,
output=1049), not the subagent's full internal loop. So inline cost is structurally
undercounted — an extension of #699. Inline agents do NOT consume less; we only measure
one turn of them.

Resolved per #765: inline forward records are now stamped `usage_complete=false`,
matching the retroactive-inline producer (`scripts/capture-agent-costs.sh`). The token
values are unchanged (still the final-turn snapshot) — the fix is honest provenance, not a
fabricated cumulative: the flag marks the record as a lower-bound so SUM-ming consumers
don't trust it as a complete total. Only cumulative-source forward records (if a future
harness populates `total_usage`/`cumulative_usage`) and the transcript-summed
orchestrator-Stop / headless paths carry `usage_complete=true`.

---

## 4. Billing reality

**Billing follows the AUTH credential, not the invocation mode** — `ANTHROPIC_API_KEY`
bills API regardless of `-p`/interactive; subscription OAuth bills subscription. The
`-p` flag is about I/O mode, not billing — **except** for the 2026-06-15 change:

> Starting **June 15, 2026**, Agent SDK and `claude -p` usage on subscription plans draw
> from a **new monthly Agent SDK credit, separate from interactive usage limits.**

- Credit allotment (USD, no rollover): **Pro $20 / Max 5x $100 / Max 20x $200** per month.
- **Overage** → standard pay-per-token API rates *if usage credits enabled*; else hard-stop
  until next cycle.
- Interactive `claude` usage is **unchanged** — still draws the normal subscription pool.
- Anthropic's stated rationale: the credit is "sized for individual experimentation…
  **production automation should use an API key for predictable pay-as-you-go billing.**"

**Consequence:** at ~$900–1000/day ($27–30k/mo) the **$200 credit is ~5–8 hours of one
day** — irrelevant at pipeline scale. The subscription was masking the real cost; the
~$15.8k/17-day figure is approximately the **go-forward bill** once the grace evaporates.
Token reduction stops being optimization and becomes **existential**.

---

## 5. Strategic fork — Path 1 vs Path 2  →  **Path 2 chosen**

| | **Path 1 — API-key** | **Path 2 — attended subscription (CHOSEN)** |
|---|---|---|
| Billing | pay-per-token API (~$27–30k/mo at current volume) | subscription **interactive pool** for inline work |
| How | accept it's production automation; reduce-to-fit | execute+pr-eval run **inline from a human-attended orchestrator**; `claude -p` opt-in |
| Automation | fully unattended; relay (#724) works | **orchestrator stays human-attended** (relay parked) |
| Ceiling | your wallet | **interactive rate limits** (burst TPM + 5-hour rolling) + cwd-isolation (#31940) |
| Supported? | Anthropic-recommended | undocumented arbitrage; viable while rate limits allow |

**Decision (2026-05-31): Path 2 now, Path 1 as a documented later-option.** Path 2's
arbitrage works because inline subagents from a *genuine* interactive session draw the
interactive pool, not the Agent SDK credit. It's bounded and fights Anthropic's intent,
so it's a "for now" base, not a permanent foundation.

---

## 6. Inline vs `claude -p` — capability parity + constraints

Inline subagents have **full capability parity** with `claude -p` (authoritative, via
docs):
- Own fresh isolated context window; only a summary returns to the parent.
- Can operate on a **different git branch** by `cd`-ing into a pre-created worktree
  (orchestrator on `staging`, subagent in `feature/x`) — the pipeline already does this
  for PATH D.

So migration is **not a capability gap** — it's a **throughput-and-isolation-vs-billing
trade.** What you give up moving inline:
1. **Unattended parallel throughput** — `claude -p` workers are separate processes with no
   shared ceiling; inline shares ONE session's rate limit.
2. **Per-agent cwd isolation** — none in the public Agent SDK (open: anthropics/claude-code
   #31940). Subagents inherit parent cwd; concurrent inline agents `cd`-ing into different
   worktrees can **race** on shared filesystem/git state. (This harness's `isolation:"worktree"`
   gives first-class isolation; public SDK does not.) The pipeline's PATH C fan-out works
   around this with **per-leaf worktrees** (#896): each `target=<dir>` leaf gets its own
   worktree+branch off feature HEAD so leaves never share a git index, reassembled onto the
   feature branch by cherry-pick — see `docs/architecture.md` and `scripts/path-c-split-worktree.sh`.

⇒ **Safe concurrency = min(rate-limit ceiling, cwd-isolation-safe count)** — the tighter binds.

---

## 7. What we can't do

- **Compaction cannot be triggered programmatically.** `/compact` and `/clear` are
  interactive-only; PreCompact/PostCompact hooks are notification-only; no SDK
  session-reset. Auto-compact fires at the limit but timing is uncontrollable.
- The only "automated context reset" is **spawning a fresh context** — which subagents and
  `claude -p` already do per task. The persistent orchestrator can't be auto-cleared.
- **Context hygiene** (lean orchestrator) comes from pushing work into subagents (separate
  windows), terse returns (#648), manual `/compact` at wave boundaries, and `/clear`
  (safe here because orchestrator state lives in GitHub labels).
- The **autonomous cron-relay (#724)** would chain fresh lean orchestrator sessions per
  wave — but that needs a **headless** orchestrator (draws the SDK credit / API), so it's
  **incompatible with Path 2** and parked until/unless Path 1.

---

## 8. Open empirical questions (owned by #721's assessment)

1. **Max execute-weight inline concurrency.** 5–10 concurrent *light* agents
   (classify/plan/plan-eval) already run fine; **execute** is heavier and unknown. At what
   concurrent count does (a) TPM throttling, (b) the sustained rolling cap, or (c)
   cwd-isolation races (#31940) bind first?
2. **Sustained pace.** The 5-hour rolling cap bites regardless of concurrency (it's total
   volume over time) — only **pacing** avoids it. ⇒ the opt-in **usage-governor (#725)**.
3. **Throughput vs `claude -p`.** Does inline deliver enough throughput, or are we forced
   to serialize and run slower than the worker fleet it replaces?

These answers size #723 (migration) and configure #725 (governor), and ultimately decide
whether Path 2 holds or we flip to Path 1.

---

## 9. Model-tier routing — the live execute-cost lever (#868/#950)

The cost analysis above (§2) found **execute = 74% of spend**, and §1 of
[analysis/model-downsampling.md](analysis/model-downsampling.md) showed the post-#748 residual is a
**pure model price-multiplier on cached context**, not an output-token problem. The shipped lever drops
the execute tier to Sonnet (1/5 of Opus across every token bucket ⇒ ~**−80% execute cost** on the eligible
traffic) while keeping the independent evaluator on Opus. As realized in the live routing surface:

- **`PIPELINE_PATH_B_MODEL_EXECUTE` / `PIPELINE_PATH_D_MODEL_EXECUTE`** — per-path Agent `model` enum
  (`sonnet`|`opus`|`haiku`) in the gitignored `pipeline.config`. **Unset/empty ⇒ no `model=` param ⇒
  inherit Opus = current behavior byte-for-byte.** Default-off (commented in `pipeline.config.example`).
- **`PIPELINE_PATH_B_ELIGIBLE_SCOPE`** (default `"low-blast"`) — gates **which** PATH B issues route
  Sonnet. Default restricts the downshift to the low-blast lane via `scripts/path-b-execute-eligible.sh`
  (≤1 source module, ≤6 files, ≤150 added-LOC proxy, no security/migration/auth/concurrency signal);
  `"all"` widens to every non-W2 PATH B issue. High-blast B otherwise **inherits Opus**.
- **PATH D is unconditional Sonnet EXCEPT `needs-browser` → Opus** (#960 — browser/UI execute unmeasured).
- **Invariant: pr-eval is NEVER tier-dropped.** No host var gates the evaluator; the Opus backstop is the
  property that makes a cheaper execute safe (a Sonnet execute defect was caught pre-merge in the pilot —
  see model-downsampling.md §3.3).

Net cost framing: the *eligible low-blast lane's own* dollar savings are thin (the expensive executes are
the high-blast B/C the default gate excludes); the lever's value is **de-risking the lane** and providing a
host-flag kill switch (unset = instant Opus revert, zero code change).

## Issue map

| Issue | Role | Status |
|---|---|---|
| #450 | epic — measure→intervene; two intervention axes | tracker |
| **#721** | tokenomics skill — backfill + 3-dim report + per-day window + per-N/per-LOC columns + history snapshot + concurrency assessment | **the gate** |
| #723 | `claude -p`→inline migration (primary architecture; `claude -p` opt-in) | P1 |
| #707 | feature-based B→D routing (first migration slice) | ready |
| #725 | opt-in usage-governor (sustained-cap pacing) | P2, depends #721 |
| #648 | terser templates (top output-cost lever) | P1 |
| #420 | over-eval downsampling diary | later |
| #700 | PATH D collapse | done |
| #724 | autonomous cron relay | later (Path-1-only, parked) |
| #722 | consumer productization of tokenomics | brainstorm |
| #642/#643/#697/#698/#699 | prior cost instrumentation | various |

## Format axis (#729) — JSON→markdown classification

Child of #648. The format lever (JSON is token-expensive vs markdown) was found
**already realized** across the pipeline; this section is the durable record and
the contract the `test-json-markdown-surface-guard.sh` test enforces.

| Surface | Output | Consumer | Class | Decision |
|---|---|---|---|---|
| ## Classification / ## Implementation Plan / ## Evaluation | markdown | model | model-consumed | already markdown |
| post-plan.sh stdout | prose | operator | model-consumed | no JSON |
| cost-latency-report.sh default / --tokenomics | markdown tables | model/operator | model-consumed | markdown (guarded) |
| *-report.sh --emit-rows-json / --emit-pricing-json | JSON | tests + metrics-snapshot | script-parsed | KEEP JSON |
| metrics-snapshot.sh | JSONL record | timeseries | machine record | KEEP JSON |
| analyze-issues.sh shortlist | JSON (4 keys) | Stage-2 subagent prompt (key-addressed) | effective parse contract | KEEP JSON |
| visual-proof-from-plan {satisfied,unsatisfied} | JSON | evaluate-issue-pr Step 6b (parsed) | machine-parse contract | KEEP JSON |

**Hard line:** never markdown-ify a `--emit-rows-json`/JSONL/key-addressed surface —
those are parsed downstream. The guard test pins both halves: model surfaces stay
JSON-free, machine contracts stay JSON.
