# Tokenomics updates — per-analysis docs

One timestamped doc per `/pipeline:tokenomics` analysis, named
`YYYY-MM-DD-window-<since>-to-<until>.md` (date = analysis date), in the operator-preferred
presentation (see `skills/tokenomics/SKILL.md` → "Preferred presentation"). This is the
human-readable analysis layer; the machine layer is the per-day aggregate store
(`.claude/logs/tokenomics-history.jsonl`, #832) and the dated seed doc
`docs/tokenomics-history-2026-05-29-to-06-02.md`. Dollar figures are lower bounds whenever the
entry's coverage block says so.

Model-mix breakdowns are computed over the reconciled substrate with:

```bash
jq -s '[.[] | select(.ts_start >= "<SINCE>" and (.usage_complete != false))] | group_by(.model)
  | map({model: (.[0].model // "EMPTY"), n: length,
         total_tokens: ([.[] | (.tokens.input//0)+(.tokens.output//0)+(.tokens.cache_creation//0)+(.tokens.cache_read//0)] | add)})
  | sort_by(-.total_tokens)' .claude/logs/agent-costs.jsonl
```
