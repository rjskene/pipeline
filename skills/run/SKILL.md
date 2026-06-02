---
name: run
description: Deprecated alias for /pipeline:status. Usage: /pipeline:run
disable-model-invocation: false
allowed-tools: Read, Bash
---

## Boot

At session start, before running any of the steps below, source the project's `pipeline.config` so the `PIPELINE_*` variables are available for the rest of this skill:

```bash
source "$(pwd)/pipeline.config" 2>/dev/null || source ./pipeline.config
# Self-resolve CLAUDE_PLUGIN_ROOT in case the env var is unset in the Bash subshell.
# Anchor via the plugin cache glob (var-independent — no chicken-and-egg dependence on
# CLAUDE_PLUGIN_ROOT to FIND the resolver). _cpr_dir is the dir prefix; literal source line.
_cpr_dir="${CLAUDE_PLUGIN_ROOT:+${CLAUDE_PLUGIN_ROOT}/}"
_cpr_dir="${_cpr_dir:-$(ls -d ${HOME}/.claude/plugins/cache/claude-pipeline/pipeline/*/ 2>/dev/null | sort -V | tail -1)}"
source "${_cpr_dir}scripts/_resolve-plugin-root.sh" 2>/dev/null || true
```

The bash blocks below reference `PIPELINE_REPO`, `PIPELINE_BASE_BRANCH`, `PIPELINE_TEST_CMD`, `PIPELINE_CONTEXT_FILES`, etc. — they resolve from the sourced config, not from envsubst at install time.

# Deprecated alias

`/pipeline:run` has been renamed to `/pipeline:status`. This skill is a thin deprecated alias that forwards to it unchanged.

Print:

```
/pipeline:run has been renamed to /pipeline:status. Delegating...
```

then forward the original argv verbatim by invoking `Skill(skill: "pipeline:status", args: "<original argv>")` and STOP. Do not duplicate the status flow inline — the delegation is the only supported path. This alias never intercepts `full send` / `full-send` / `fullsend`; autonomous advancement lives in `/pipeline:fullsend`.
