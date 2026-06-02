# Anti-patterns

**Do not poll for queue completion with `while ... sleep ... grep` inside Bash tool calls.** This pattern burns context tokens on every poll cycle and ties up the orchestrator for the duration. Use `Bash run_in_background: true` for one-shot completion waits, or `Monitor` for streaming per-event notifications. The queue runner's internal `sleep` polling (inside `run-queue.sh`) is fine — it runs in its own process and does not consume orchestrator context.
