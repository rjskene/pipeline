---
name: Bug report
about: Report a defect in pipeline behavior, scripts, or skills
title: ""
labels: ["bug"]
---

<!--
Before filing: `pipeline.config` is gitignored (see line 8 of `.gitignore`) and
host-specific. Path-drift or value-drift bugs that surface only in the live
`pipeline.config` cannot ship in a PR — there is no tracked file to change.

If your bug is "line N of pipeline.config is wrong":
  1. Check whether the same drift exists in `pipeline.config.example` and fix
     that file in your PR if so.
  2. Add a regression-guard test (model: `tests/test-pipeline-config-mock-web-eval-paths.sh`,
     introduced by #357) that scans both `pipeline.config.example` and the
     gitignored `pipeline.config` when present.
  3. The live `pipeline.config` is patched by hand on the operator's host —
     flag this in the issue body so the operator knows to apply the local edit.
-->

## Summary

<!-- One sentence describing the bug. -->

## Reproduction

<!-- Steps to reproduce, smallest failing input, command(s) run. -->

## Expected vs actual

<!-- What you expected to happen vs what happened. -->

## Environment

<!-- Plugin version (`gh api ... | jq .tag_name` or `/pipeline:doctor`), OS,
     `gh` version, whether running from a worktree or main checkout. -->

## Notes

<!-- Anything else: related issues/PRs, links to logs, suspected file(s). -->
