# Changelog

## [0.3.0](https://github.com/HTS-COLLAB-ORG/claude-pipeline/compare/v0.2.0...v0.3.0) (2026-05-14)


### Features

* **execute-issue-plan:** detect CI-blocking markers in PR titles and commit subjects ([#109](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/109)) ([b0c5176](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/b0c5176d17be384243a9996d94f653871d9ed3dd))
* **execute-issue-pr:** CI-fix loop — re-dispatch executor on CI failure with bounded retry budget ([#113](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/113)) ([2eb1cf9](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/2eb1cf90bb74b932c11b7599a638f78820283bfb)), closes [#52](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/52)
* **pipeline:** orchestrator awareness of release-please PRs (autorelease: pending) ([#112](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/112)) ([03de881](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/03de881664856d1db8fbb7fa56b6bd9c7418866b)), closes [#51](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/51)
* **pipeline:** Stop-hook enforces CI-wait on PR eval ([#114](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/114)) ([5bd9cca](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/5bd9ccac7e9e7171bfd19406357335c6ca1489b6))
* **plugin:** register slash commands via plugin auto-discovery (drop .template suffix) ([#94](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/94)) ([e2e074b](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/e2e074ba2338382da3012b68b058af7a178b6272))
* **release:** install release-please workflow + config (closes [#104](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/104)) ([#106](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/106)) ([1f5201b](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/1f5201b92c309aa28324b4b6ab8290680638b17e))


### Bug Fixes

* **plugin:** drop hard superpowers dependency from plugin.json (closes [#102](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/102)) ([#103](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/103)) ([e15ca5b](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/e15ca5b44e7a715e1b78949e38b7a918d2bb2734))
* **spawn-claude:** namespace slash invocation to /pipeline:${SKILL} (closes [#100](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/100)) ([#101](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/101)) ([563764d](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/563764d825c81428e1ecff8600bec4f776df89e3))
* **tests:** remove broken test-path-c-args-directive.sh (closes [#88](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/88)) ([#105](https://github.com/HTS-COLLAB-ORG/claude-pipeline/issues/105)) ([9827cb1](https://github.com/HTS-COLLAB-ORG/claude-pipeline/commit/9827cb1872914714471673c87295653f18268b1b))
