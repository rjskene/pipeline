#!/usr/bin/env bash
# Shared env hygiene for pipeline bash tests. Source this at the top of any
# test that exercises scripts under scripts/ which honor PIPELINE_* env vars.
#
# Why: tests that read PIPELINE_LOGS_ENABLED, PIPELINE_REPO, etc. must own
# their env entirely. When the dogfood repo's own pipeline.config leaks
# into the test process (e.g. via spawn-claude or full-suite runners),
# fixtures can write to REPO_ROOT/.claude/logs/ and collide across runs.
# Sourcing this helper at the top of a test, then calling
# pipeline_test_reset_env, removes that ambient state.
pipeline_test_reset_env() {
  local v
  for v in PIPELINE_LOGS_ENABLED \
           PIPELINE_CI_FIX_LOOP_ENABLED \
           PIPELINE_CI_FIX_RETRY_BUDGET \
           PIPELINE_CI_FIX_LOG_LINES \
           PIPELINE_CI_CHECK_ENABLED \
           PIPELINE_LABELS_HUMAN \
           PIPELINE_REPO \
           PIPELINE_BASE_BRANCH \
           PIPELINE_WORKTREE_PREFIX \
           PIPELINE_WIN_TEMP \
           GH_FAKE_LOG \
           GH_FAKE_STATE \
           RECORDER_LOG \
           CLAUDE_PLUGIN_ROOT \
           PIPELINE_CI_FIX_CONTEXT; do
    unset "$v" 2>/dev/null || true
  done
  while IFS= read -r v; do unset "$v" 2>/dev/null || true; done < <(compgen -v PIPELINE_CI_ 2>/dev/null || true)
}
