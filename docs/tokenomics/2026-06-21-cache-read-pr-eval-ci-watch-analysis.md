# Cache-read analysis — pr-eval & CI-watch (2026-06-21)

Investigation note (not a window report). Question that started it: **which stage drives cache_read, and can CI-watching be optimized to reduce it?**

## TL;DR

The "CI-watch burns cache" hypothesis is **mostly already solved or a non-issue**, once you look at the data:

- GitHub CI runs in **median 2.7 min, max 3 min, 0/37 over 5 min** — it **never crosses the 5-min prompt-cache TTL**.
- The only thing that *did* cross the TTL (the local ~9–11 min `$PIPELINE_TEST_CMD` re-run) is **already skipped on a green rollup by #1078**.
- The pipeline is **already** event-driven (`Monitor`, single wake), **not** polling — so there is no per-poll re-read to eliminate.

The remaining real lever is **evaluator resident context size × eval turn count**, which trades against eval quality. Net: low-ROI; spend effort elsewhere (routing leak, shift-left avoidable CI failures).

## Cache-read mechanic

Every API round-trip re-processes the entire conversation prefix. Prompt caching makes that re-read cheap (`cache_read` ≈ 0.1× input), but it still happens **per call**:

```
cache_read ≈ (resident context size) × (number of API round-trips in the session)
```

- **Tool calls are the multiplier.** Each tool-call → result → next message is a new API call → one full re-read. A poll loop is the pathological case (every poll = a wake = a re-read).
- **Thinking is NOT a cache_read driver.** Extended thinking generates *output* tokens; it only enlarges the context that *later* turns re-read (second-order).
- **Cache TTL = 5 min.** A blocking wait longer than 5 min expires the cache; the resume turn is then a cache **miss** — full `input` (1×) + `cache_creation` (1.25×) to rebuild — not cheap `cache_read`.

## Where cache_read concentrates

Totals by stage (reconciled substrate):

```
PAST WEEK (2026-06-14 → 2026-06-21)        ALL-TIME
pr-eval   65.6%  (258.9M)                  execute      47.8%  (3.44B)
execute   19.5%  ( 77.1M)                  orchestrator 29.6%  (2.13B)
plan       7.2%                            pr-eval      16.3%
plan-eval  5.7%                            plan          2.9%
classify   1.8%                            plan-eval     2.2%
                                           classify      0.8%
```

This week was CI-heavy (split-role PRs) so pr-eval led. All-time, execute leads, with the **orchestrator** (main loop re-reading its growing context every turn) a close second.

## Premise corrections (the data)

**GitHub CI duration** — last 37 successful `ci.yml` runs:

```
median 2.7 min · max 3.0 min · >5min = 0 · >10min = 0
```

1. **Polling → Monitor: nothing to do.** Already on `Monitor` (wakes only on `EVENT:`/completion, not at intervals). No periodic re-reads exist.
2. **TTL-expiry from the watch: non-issue.** CI is 2.7 min < 5 min TTL, so a single blocking `gh pr checks --watch` never expires the cache. The model sleeps the whole watch, one resume, no rebuild. The watch is **cheap**.
3. **The 9–11 min figure was the LOCAL suite re-run**, not GitHub CI. That one *did* cross the TTL — and **#1078 already skips it on a green rollup** (`additive-ok-ci-green`), so the TTL-crossing stall is already removed.

So pr-eval's 66% cache_read is **not** the watch, **not** TTL, **not** polling. It is `large eval context × many eval tool calls`: the evaluator loads the big `evaluate-issue-pr` SKILL body + PR diff + plan, then does many tool calls (view, gate scripts, post verdict, merge), each re-reading that whole context at 0.1×. The fail→fix→re-watch loop (e.g. #1089 config-drift) doubles the turn count.

## The one real lever + tradeoffs

Reduce the evaluator's **resident context** and **turn count**. Constraints:

- pr-eval must stay **Opus** (W3 — it is the regression catcher that makes a cheaper-execute default safe). Cannot downgrade.
- Trimming what it reads (PR diff, plan, SKILL body) trades directly against **review quality**.
- `cache_read` is the **cheapest** token class (0.1×). The 66% is volume, not dollars; pr-eval is ~$330/week and much of that is Opus reasoning + `cache_creation`, not the cheap reads.

## Recommendation

- **(a) Shift-left the config-drift failure class** — a pre-PR check at execute-time so the evaluator watches once instead of fail→fix→re-watch. Bounded, low-risk, concrete (kills the #1089-style double-watch). **Recommended.**
- **(b) Slim evaluator resident context** — real but trades against eval quality; measure before cutting.
- **(c) Do nothing on cache** — mostly already optimized; spend effort on the **$131/wk B→D routing leak** instead.

## Related / done

- **#1078** — CI-trust skip of the local suite re-run on green rollup (`additive-ok-ci-green`). Removes the one TTL-crossing stall. **Merged.**
- **#957** — pr-eval already trusts a green rollup to skip its own local re-run (precedent for #1078).
- **Monitor event-wait** — single-wake, not polling. Already in place.
- **#1098** — split-role RED/GREEN role+model not cost-attributed; inline records are point-in-time (no duration span), so concurrency + model-mix are unmeasurable. Same capture-fidelity gap.
