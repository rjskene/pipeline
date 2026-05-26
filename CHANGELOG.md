# Changelog

## [0.18.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.17.0-rc.1...v0.18.0-rc.1) (2026-05-26)


### Features

* **config:** add PIPELINE_EVAL_ISOLATION + visual-proof vars ([008ee62](https://github.com/rjskene/pipeline/commit/008ee62c37742e2449ca06d9884d39dc79474711))
* **evaluate-issue-pr:** add post-merge screenshot URL rewrite helper ([56eaa66](https://github.com/rjskene/pipeline/commit/56eaa66fc4d4de9a74797c5e0fe2bd5046663b48))
* **evaluator-dispatch:** default browser-eval evaluator to inline Agent dispatch; container path retained behind PIPELINE_EVAL_ISOLATION opt-in ([0c7a27c](https://github.com/rjskene/pipeline/commit/0c7a27c29a95091288d6b80b5a36e60dbddda503))
* **mock-web-eval:** add counter Reset button wired to zero the counter ([62bb856](https://github.com/rjskene/pipeline/commit/62bb856a97cecc5208c910a28f0bd2a0e5315ae7))
* **run-queue:** emit dispatch-inline event with slate-index port broker + migration warning ([36e6799](https://github.com/rjskene/pipeline/commit/36e6799bb9001ca04e02b5a0dd29038df2710461))
* **scripts:** add visual-proof-port-broker.sh ([41da058](https://github.com/rjskene/pipeline/commit/41da058e968b2876e47460492f06416e7b00a8d2))
* **scripts:** add visual-proof-server reaper ([2cd36a2](https://github.com/rjskene/pipeline/commit/2cd36a22d91fe7f539aa008bab6b3074f8888291))
* **spawn-claude:** isolation-gated inline browser-eval dispatch + Playwright-MCP probe ([0a3d71d](https://github.com/rjskene/pipeline/commit/0a3d71d388372dcb4f4fbe03f5ebbbd293bd7617))


### Bug Fixes

* **derive-pr-title:** non-canonical conventional-commit types double-prefix to chore(general): instead of normalizing the type and preserving the scope ([c2cdcd7](https://github.com/rjskene/pipeline/commit/c2cdcd7da4ba8a61c41bedd46972e2bd9d670f4d))
* **derive-pr-title:** normalize non-canonical conventional-commit types ([#507](https://github.com/rjskene/pipeline/issues/507)) ([f2288ff](https://github.com/rjskene/pipeline/commit/f2288ff058751c78ac9143f5570249439dfeed78))
* **evaluate-issue-pr:** autonomous greenlight auto-merge collapses Option A screenshot review window — eval-comment URLs 404 before any human sees them ([c36c381](https://github.com/rjskene/pipeline/commit/c36c381b44eae720eafa11e317458eabe3424797))
* **evaluate-issue-pr:** rewrite screenshot URLs to merge-SHA post auto-merge ([45ff742](https://github.com/rjskene/pipeline/commit/45ff742eed7fc470e6641636df8530f24e8e213d))
* **mock-web-eval:** regression of [#241](https://github.com/rjskene/pipeline/issues/241) — /pipeline:* slash commands again not discoverable inside container ([fd30837](https://github.com/rjskene/pipeline/commit/fd30837f6b39b9e74fe812c40b1709c90540817f))
* **mock-web-eval:** restore /pipeline:* discoverability inside container ([#505](https://github.com/rjskene/pipeline/issues/505)) ([ed7e6d3](https://github.com/rjskene/pipeline/commit/ed7e6d3927a1ac7646b5e965199e88ce5b8d2544))
* **review:** cross-reference [#505](https://github.com/rjskene/pipeline/issues/505) in the [#241](https://github.com/rjskene/pipeline/issues/241) root-cause comment block ([#505](https://github.com/rjskene/pipeline/issues/505)) ([32e447a](https://github.com/rjskene/pipeline/commit/32e447a76751d664dca2d688b9d08681e709b0c4))
* **review:** set exec bit on test-rewrite-eval-screenshot-urls.sh for consistency ([a8a8929](https://github.com/rjskene/pipeline/commit/a8a8929dd26dd874b414a92ef4f044635e3adde8))
* **run-queue:** classify_issue uses gh 'linked:&lt;N&gt;' qualifier which returns unrelated PRs, blocking execute dispatch with container-mode rejection ([2ddd2c6](https://github.com/rjskene/pipeline/commit/2ddd2c61f709010809d26490f7aa48c1a0179d25))
* **run-queue:** do not bump BUCKET_ACTIVE on inline dispatch (allow multi-issue slates) ([6a7170b](https://github.com/rjskene/pipeline/commit/6a7170b08e6d787b845d2c8810a668913730d082))
* **spawn-claude:** empty-MCP file at /tmp/ collides with container mode — host path unreachable inside container, evaluator exits in &lt;1s ([4137c32](https://github.com/rjskene/pipeline/commit/4137c32ffaf5365dca9d2a51cac620406d448506))
* **spawn-claude:** exit 0 early on inline branch instead of falling through ([01f8424](https://github.com/rjskene/pipeline/commit/01f84246ee882d0a74ad7ff827ed7855cfc3175c))
* **spawn-claude:** skip empty-MCP branch under container mode ([#516](https://github.com/rjskene/pipeline/issues/516)) ([ad6c9ce](https://github.com/rjskene/pipeline/commit/ad6c9ce228edd31f135d214361b37547b3415f76))

## [0.17.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.16.0-rc.1...v0.17.0-rc.1) (2026-05-25)


### Features

* **evaluate-issue-pr:** auto-apply manual-merge label on block-* skip ([#489](https://github.com/rjskene/pipeline/issues/489)) ([6116835](https://github.com/rjskene/pipeline/commit/6116835bbc494aa92efc68e0e2a3b3d29cbb6f0c))
* **parse-tracker-children:** add --fallback-mentions scan mode ([4280c83](https://github.com/rjskene/pipeline/commit/4280c8388c68311dd28f2706be3e3ed28adf3534))
* **run-queue:** add evaluator_finished_terminal predicate ([#489](https://github.com/rjskene/pipeline/issues/489)) ([486fe75](https://github.com/rjskene/pipeline/commit/486fe75fc91cb1787d33ede2209b7d3eabb7f8a8))


### Bug Fixes

* **auto-close-trackers:** fall back to body #NNN scan when ## Rollout sequence missing ([4aa28d9](https://github.com/rjskene/pipeline/commit/4aa28d9b28c2660fffb3a72793501220a6db7242))
* **auto-close-trackers:** trackers without '## Rollout sequence' checklist skipped even when all children closed ([a338f7f](https://github.com/rjskene/pipeline/commit/a338f7fb1acd9d524018a0c0f1f0e0fe391eb865))
* **queue-status:** recurring 'could not locate consumer repo' error during queue poll ([3ce8d8d](https://github.com/rjskene/pipeline/commit/3ce8d8db76198644b6ebc0f9c9790549088ed8ff))
* **review:** guard evaluator predicate against gh null PR lookup ([#489](https://github.com/rjskene/pipeline/issues/489)) ([d475265](https://github.com/rjskene/pipeline/commit/d4752654a405e2bfda8f24140d51cd4b45796441))
* **run-queue:** gate evaluator_finished_terminal label arm on Evaluation comment ([cd46b13](https://github.com/rjskene/pipeline/commit/cd46b13e13d5b8ff55588251da6b29adaa16af8e))
* **run-queue:** propagate PIPELINE_PROJECT_ROOT to queue-status poll helper ([1ad1dae](https://github.com/rjskene/pipeline/commit/1ad1daed42015f4f53ec0a3fe556755245e3eb66)), closes [#490](https://github.com/rjskene/pipeline/issues/490)
* **run-queue:** runner hangs after evaluator completes without auto-merge (eval verdict Approved + manual-merge flag) ([dc1308e](https://github.com/rjskene/pipeline/commit/dc1308efa0f2e0b615ade6b2f6dc589b1e10bf29))
* **run-queue:** treat evaluator verdict + manual-merge as terminal ([#489](https://github.com/rjskene/pipeline/issues/489)) ([41aecea](https://github.com/rjskene/pipeline/commit/41aecea8874ce67f19c0546493e6f6740d465c82))

## [0.16.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.15.0-rc.1...v0.16.0-rc.1) (2026-05-25)


### Features

* **release:** switch to merge commits to preserve per-PR CHANGELOG entries ([3ccf15c](https://github.com/rjskene/pipeline/commit/3ccf15c1c7884869e05e09bfc44a823576326c1d))

## [0.15.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.2...v0.15.0-rc.1) (2026-05-25)


### release

* v0.15.0-rc.1 (staging → main) ([#485](https://github.com/rjskene/pipeline/issues/485)) ([dbfc127](https://github.com/rjskene/pipeline/commit/dbfc127f400439d98afa87c10892735afe951ae4))

## [0.14.2](https://github.com/rjskene/pipeline/compare/v0.14.2-rc.1...v0.14.2) (2026-05-24)


### release

* v0.14.2 (staging → main) ([#479](https://github.com/rjskene/pipeline/issues/479)) ([48999e1](https://github.com/rjskene/pipeline/commit/48999e11fea6c7c3daa475cdba6d943f34697107))

## [0.14.2-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.1...v0.14.2-rc.1) (2026-05-24)


### release

* v0.14.2-rc.1 (staging → main) ([#477](https://github.com/rjskene/pipeline/issues/477)) ([727b9be](https://github.com/rjskene/pipeline/commit/727b9bec46ac2f99dae1abdad5f87bf45bad461c))

## [0.14.1](https://github.com/rjskene/pipeline/compare/v0.14.1-rc.2...v0.14.1) (2026-05-24)


### Miscellaneous Chores

* **release:** graduate v0.14.1-rc.2 to v0.14.1 ([702cb34](https://github.com/rjskene/pipeline/commit/702cb34140f00efd20ceca9aa7e8edc1eff53805))

## [0.14.1-rc.2](https://github.com/rjskene/pipeline/compare/v0.14.1-rc.1...v0.14.1-rc.2) (2026-05-24)


### release

* v0.14.1-rc.2 (staging → main) ([#470](https://github.com/rjskene/pipeline/issues/470)) ([6b2a6c8](https://github.com/rjskene/pipeline/commit/6b2a6c89705d93386e52cfdd06fed53db42322f5))

## [0.14.1-rc.1](https://github.com/rjskene/pipeline/compare/v0.14.0...v0.14.1-rc.1) (2026-05-24)


### release

* v0.14.1-rc.1 (staging → main) ([#466](https://github.com/rjskene/pipeline/issues/466)) ([d9a956a](https://github.com/rjskene/pipeline/commit/d9a956aeb168f27a355456f7c18eb353b0828ddc))

## [0.14.0](https://github.com/rjskene/pipeline/compare/v0.14.0-rc.2...v0.14.0) (2026-05-24)


### Miscellaneous Chores

* release v0.14.0 ([6fd9cd9](https://github.com/rjskene/pipeline/commit/6fd9cd9aecc2710c37a04dafbd99b3829f02f8d2))

## [0.14.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.14.0-rc.1...v0.14.0-rc.2) (2026-05-23)


### release

* v0.14.0-rc.2 (staging → main) ([#452](https://github.com/rjskene/pipeline/issues/452)) ([ea30748](https://github.com/rjskene/pipeline/commit/ea30748df5643b4c805d9618d24a84ff98c7a5a3))

## [0.14.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.13.0...v0.14.0-rc.1) (2026-05-23)


### release

* v0.14.0-rc.1 (staging → main) ([#448](https://github.com/rjskene/pipeline/issues/448)) ([e572c62](https://github.com/rjskene/pipeline/commit/e572c62d971b365ddd2efff9ca4e8e383079dc27))

## [0.13.0](https://github.com/rjskene/pipeline/compare/v0.13.0-rc.1...v0.13.0) (2026-05-23)


### Miscellaneous Chores

* **release:** graduate v0.13.0 stable ([#443](https://github.com/rjskene/pipeline/issues/443)) ([efdd001](https://github.com/rjskene/pipeline/commit/efdd001f0b67629d3490605e242a05fd12d64450))

## [0.13.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.12.1-rc.1...v0.13.0-rc.1) (2026-05-23)


### Miscellaneous Chores

* **release:** cut v0.13.0-rc.1 ([#438](https://github.com/rjskene/pipeline/issues/438)) ([a9e72ea](https://github.com/rjskene/pipeline/commit/a9e72ea63899eadee422113cf0fc9f26ba361898))

## [0.12.1-rc.1](https://github.com/rjskene/pipeline/compare/v0.12.0...v0.12.1-rc.1) (2026-05-22)


### Bug Fixes

* **run:** mandate orchestrator reprint status table into assistant reply ([#424](https://github.com/rjskene/pipeline/issues/424)) ([#426](https://github.com/rjskene/pipeline/issues/426)) ([cc79f61](https://github.com/rjskene/pipeline/commit/cc79f61bc2c9de3768e4aead688ae770d518ebc5))

## [0.12.0](https://github.com/rjskene/pipeline/compare/v0.12.0-rc.1...v0.12.0) (2026-05-22)


### Miscellaneous Chores

* **release:** graduate v0.12.0 stable ([#409](https://github.com/rjskene/pipeline/issues/409)) ([a0c6f39](https://github.com/rjskene/pipeline/commit/a0c6f39921a1c2c91d383e214b840c5bef5e7365))

## [0.12.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.11.0-rc.1...v0.12.0-rc.1) (2026-05-22)


### Features

* **docs:** system foundation — docs/process-maps.md (new) + classify-issue SKILL (PATH owner) ([#401](https://github.com/rjskene/pipeline/issues/401)) ([e7376c3](https://github.com/rjskene/pipeline/commit/e7376c3c1a1460243461145223ae3ccd0932e975))

## [0.11.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.10.0...v0.11.0-rc.1) (2026-05-22)


### Miscellaneous Chores

* **release:** cut v0.11.0-rc.1 ([#392](https://github.com/rjskene/pipeline/issues/392)) ([3a49266](https://github.com/rjskene/pipeline/commit/3a4926642c53a2312b0378be1617b7da69a40027))

## [0.10.0](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.4...v0.10.0) (2026-05-21)


### Miscellaneous Chores

* **release:** v0.10.0 — graduate rc series to stable ([#380](https://github.com/rjskene/pipeline/issues/380)) ([e93debd](https://github.com/rjskene/pipeline/commit/e93debd34a07c41dd766a71bcaffa9fcf71a6dce))

## [0.10.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.3...v0.10.0-rc.4) (2026-05-21)


### Miscellaneous Chores

* **release:** v0.10.0-rc.4 — docs polish + path-A fullsend hardening ([#378](https://github.com/rjskene/pipeline/issues/378)) ([5448a1c](https://github.com/rjskene/pipeline/commit/5448a1c4f55e5651d0b68c132dbbb8c1fe30503b))

## [0.10.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.2...v0.10.0-rc.3) (2026-05-21)


### release

* v0.10.0-rc.3 ([#372](https://github.com/rjskene/pipeline/issues/372)) ([6c37159](https://github.com/rjskene/pipeline/commit/6c3715916c5897d4c632dcd0f473331955d0e176))

## [0.10.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.10.0-rc.1...v0.10.0-rc.2) (2026-05-21)


### release

* v0.10.0-rc.2 ([#366](https://github.com/rjskene/pipeline/issues/366)) ([724254a](https://github.com/rjskene/pipeline/commit/724254a81d0629636f92b5381a508b3b8d298c82))

## [0.10.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.9.0...v0.10.0-rc.1) (2026-05-20)


### release

* v0.10.0-rc.1 ([#348](https://github.com/rjskene/pipeline/issues/348)) ([f3b12d4](https://github.com/rjskene/pipeline/commit/f3b12d431da7434dfa5031b55063ce479e2a29c7))

## [0.9.0](https://github.com/rjskene/pipeline/compare/v0.9.0-rc.1...v0.9.0) (2026-05-20)


### Miscellaneous Chores

* graduate v0.9.0 stable ([#334](https://github.com/rjskene/pipeline/issues/334)) ([a0d2761](https://github.com/rjskene/pipeline/commit/a0d2761c9e018c18f8a4cf475f7dcefae74cfea6))

## [0.9.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.8.3...v0.9.0-rc.1) (2026-05-20)


### Miscellaneous Chores

* cut v0.9.0-rc.1 ([#332](https://github.com/rjskene/pipeline/issues/332)) ([f28ed9c](https://github.com/rjskene/pipeline/commit/f28ed9c3216bbcb722b3f6663f3c6187aafc7703))

## [0.8.3](https://github.com/rjskene/pipeline/compare/v0.8.2...v0.8.3) (2026-05-19)


### Miscellaneous Chores

* cut v0.8.3 stable patch — pre-public legacy-identity scrub ([#307](https://github.com/rjskene/pipeline/issues/307)) ([968909e](https://github.com/rjskene/pipeline/commit/968909e114fde5c3d01542c06e98d17f7ee73b87))

## [0.8.2](https://github.com/rjskene/pipeline/compare/v0.8.1...v0.8.2) (2026-05-19)


### Miscellaneous Chores

* cut v0.8.2 stable patch — repo-transfer URL retarget ([#304](https://github.com/rjskene/pipeline/issues/304)) ([55c7afe](https://github.com/rjskene/pipeline/commit/55c7afe97a33b4136a965a1788427467bbb434af))

## [0.8.1](https://github.com/rjskene/pipeline/compare/v0.8.0...v0.8.1) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.1 stable patch — hotfix [#295](https://github.com/rjskene/pipeline/issues/295) enforce-base-branch defense-in-depth ([#301](https://github.com/rjskene/pipeline/issues/301)) ([e2034d9](https://github.com/rjskene/pipeline/commit/e2034d947b122e0796962520eeee12eb018e84e8))

## [0.8.0](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.6...v0.8.0) (2026-05-18)


### Miscellaneous Chores

* graduate v0.8.0-rc.6 to v0.8.0 stable ([#298](https://github.com/rjskene/pipeline/issues/298)) ([f669109](https://github.com/rjskene/pipeline/commit/f66910918241ee84f08e4bcf139432b96ff0b784))

## [0.8.0-rc.6](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.5...v0.8.0-rc.6) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.6 — bundle three staging PRs ([#296](https://github.com/rjskene/pipeline/issues/296)) ([21d883d](https://github.com/rjskene/pipeline/commit/21d883d296bfb0a14df60e3d21134f03eb4bd244))

## [0.8.0-rc.5](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.4...v0.8.0-rc.5) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.5 — bundle five staging PRs ([#284](https://github.com/rjskene/pipeline/issues/284)) ([a1ebfaa](https://github.com/rjskene/pipeline/commit/a1ebfaaa942bac7420165312981bdaf40969e6a2))

## [0.8.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.3...v0.8.0-rc.4) (2026-05-18)


### release

* cut v0.8.0-rc.4 from staging ([#275](https://github.com/rjskene/pipeline/issues/275)) ([b71d590](https://github.com/rjskene/pipeline/commit/b71d590d2e2f6802c98eb622c8e0b9f3f1dd72eb))

## [0.8.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.2...v0.8.0-rc.3) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.3 — mock-web-eval smoke-test wave + doctor/wiring fixes ([#262](https://github.com/rjskene/pipeline/issues/262)) ([5542995](https://github.com/rjskene/pipeline/commit/5542995eb8784f55251b0fbc013edc25580f43c3))

## [0.8.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.8.0-rc.1...v0.8.0-rc.2) (2026-05-18)


### Miscellaneous Chores

* cut v0.8.0-rc.2 — mock-web-eval demonstrator wave + dogfood fixes ([#246](https://github.com/rjskene/pipeline/issues/246)) ([8d87332](https://github.com/rjskene/pipeline/commit/8d8733238b16e1a85d7574344e8c57d65f4e1cb1))

## [0.8.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.7.2...v0.8.0-rc.1) (2026-05-17)


### release

* cut v0.8.0-rc.1 (dev channel) ([#228](https://github.com/rjskene/pipeline/issues/228)) ([4e2ef6f](https://github.com/rjskene/pipeline/commit/4e2ef6f79fd359e27f9dd02a5edb21be74f01c7f))

## [0.7.2](https://github.com/rjskene/pipeline/compare/v0.7.2-rc.1...v0.7.2) (2026-05-17)


### release

* cut v0.7.2 (stable graduation from rc.1) ([#209](https://github.com/rjskene/pipeline/issues/209)) ([0983504](https://github.com/rjskene/pipeline/commit/098350473b7dc013f32b09deb35d0650164bde7e))

## [0.7.2-rc.1](https://github.com/rjskene/pipeline/compare/v0.7.1...v0.7.2-rc.1) (2026-05-17)


### release

* cut v0.7.2-rc.1 (back-sync regression fix) ([#207](https://github.com/rjskene/pipeline/issues/207)) ([df3246e](https://github.com/rjskene/pipeline/commit/df3246ed6ba44437d0c2b3ccd849c729eea0f4de))

## [0.7.1](https://github.com/rjskene/pipeline/compare/v0.7.0...v0.7.1) (2026-05-17)


### release

* cut v0.7.1 (stable graduation from rc.1) ([#203](https://github.com/rjskene/pipeline/issues/203)) ([b961968](https://github.com/rjskene/pipeline/commit/b961968c3b9e7d22e090911dfffd7e5f0b6cfe2b))
* cut v0.7.1-rc.1 (back-sync workflow fix) ([#201](https://github.com/rjskene/pipeline/issues/201)) ([a3dd742](https://github.com/rjskene/pipeline/commit/a3dd7427035031c90aa61ba5eef3fd7fb18efbbd))

## [0.7.0](https://github.com/rjskene/pipeline/compare/v0.7.0-rc.1...v0.7.0) (2026-05-16)


### release

* cut v0.7.0 (stable graduation from rc.1) ([#197](https://github.com/rjskene/pipeline/issues/197)) ([0430feb](https://github.com/rjskene/pipeline/commit/0430febdb899362321df8da0856e700ff649d90d))

## [0.7.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.6.0...v0.7.0-rc.1) (2026-05-16)


### release

* cut v0.7.0-rc.1 ([#195](https://github.com/rjskene/pipeline/issues/195)) ([0fad7c4](https://github.com/rjskene/pipeline/commit/0fad7c41bdbd06c6a5dc7d2f0126b6fca3c8eee3))

## [0.6.0](https://github.com/rjskene/pipeline/compare/v0.6.0-rc.1...v0.6.0) (2026-05-16)


### release

* cut v0.6.0 (stable graduation from rc.1) ([#191](https://github.com/rjskene/pipeline/issues/191)) ([ffba3dd](https://github.com/rjskene/pipeline/commit/ffba3ddea9514734314bf0fd47a643cca9eefb3b))

## [0.6.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.5.0...v0.6.0-rc.1) (2026-05-16)


### release

* cut v0.6.0-rc.1 (consumer_drift drift report for [#187](https://github.com/rjskene/pipeline/issues/187)) ([#189](https://github.com/rjskene/pipeline/issues/189)) ([fc8ac85](https://github.com/rjskene/pipeline/commit/fc8ac854a06655dcf9d69bd5e63ce604f873a22d))

## [0.5.0](https://github.com/rjskene/pipeline/compare/v0.5.0-rc.1...v0.5.0) (2026-05-16)


### release

* cut v0.5.0 (stable graduation from rc.1) ([#185](https://github.com/rjskene/pipeline/issues/185)) ([5500533](https://github.com/rjskene/pipeline/commit/5500533e506c9fc1471fad0b385ebc4727c225eb))

## [0.5.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.4.0...v0.5.0-rc.1) (2026-05-16)


### release

* cut v0.5.0-rc.1 (consumer-install hardening tracker [#178](https://github.com/rjskene/pipeline/issues/178)) ([#183](https://github.com/rjskene/pipeline/issues/183)) ([a30f0e8](https://github.com/rjskene/pipeline/commit/a30f0e83e6598e2966f5721ec5d1671604153bad))

## [0.4.0](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.4...v0.4.0) (2026-05-15)


### release

* cut v0.4.0 (stable graduation) ([f4db262](https://github.com/rjskene/pipeline/commit/f4db26201d9c1800df99307ed01e55f7b9bd0d37))

## [0.4.0-rc.4](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.3...v0.4.0-rc.4) (2026-05-15)


### Miscellaneous Chores

* **release:** cut 0.4.0-rc.4 ([56e3c94](https://github.com/rjskene/pipeline/commit/56e3c940987d566f5808e6ca1c346ed36cdc4bda))

## [0.4.0-rc.3](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.2...v0.4.0-rc.3) (2026-05-15)


### release

* cut v0.4.0-rc.3 (dev channel) ([#162](https://github.com/rjskene/pipeline/issues/162)) ([80b64c6](https://github.com/rjskene/pipeline/commit/80b64c6ab3d8b1f04621d958ecf9fe9a04ac3db9))

## [0.4.0-rc.2](https://github.com/rjskene/pipeline/compare/v0.4.0-rc.1...v0.4.0-rc.2) (2026-05-15)


### release

* cut v0.4.0-rc.2 (dev channel) ([#153](https://github.com/rjskene/pipeline/issues/153)) ([bbb1dc2](https://github.com/rjskene/pipeline/commit/bbb1dc2b08fdbf4e037477998197e3bc71d12d94))

## [0.4.0-rc.1](https://github.com/rjskene/pipeline/compare/v0.3.1...v0.4.0-rc.1) (2026-05-15)


### release

* cut v0.4.0-rc.1 (dev channel) ([#130](https://github.com/rjskene/pipeline/issues/130)) ([b0cef7c](https://github.com/rjskene/pipeline/commit/b0cef7c10d9b7c3c93a009240c98952b526aaa06))

## [0.3.1](https://github.com/rjskene/pipeline/compare/v0.3.0...v0.3.1) (2026-05-14)


### Bug Fixes

* **tests:** exclude CHANGELOG.md from removed-file guard (unbreaks release CI) ([#117](https://github.com/rjskene/pipeline/issues/117)) ([a93c9ca](https://github.com/rjskene/pipeline/commit/a93c9ca8be427892ab0dac599855fd6610ff5579))

## [0.3.0](https://github.com/rjskene/pipeline/compare/v0.2.0...v0.3.0) (2026-05-14)


### Features

* **execute-issue-plan:** detect CI-blocking markers in PR titles and commit subjects ([#109](https://github.com/rjskene/pipeline/issues/109)) ([b0c5176](https://github.com/rjskene/pipeline/commit/b0c5176d17be384243a9996d94f653871d9ed3dd))
* **execute-issue-pr:** CI-fix loop — re-dispatch executor on CI failure with bounded retry budget ([#113](https://github.com/rjskene/pipeline/issues/113)) ([2eb1cf9](https://github.com/rjskene/pipeline/commit/2eb1cf90bb74b932c11b7599a638f78820283bfb)), closes [#52](https://github.com/rjskene/pipeline/issues/52)
* **pipeline:** orchestrator awareness of release-please PRs (autorelease: pending) ([#112](https://github.com/rjskene/pipeline/issues/112)) ([03de881](https://github.com/rjskene/pipeline/commit/03de881664856d1db8fbb7fa56b6bd9c7418866b)), closes [#51](https://github.com/rjskene/pipeline/issues/51)
* **pipeline:** Stop-hook enforces CI-wait on PR eval ([#114](https://github.com/rjskene/pipeline/issues/114)) ([5bd9cca](https://github.com/rjskene/pipeline/commit/5bd9ccac7e9e7171bfd19406357335c6ca1489b6))
* **plugin:** register slash commands via plugin auto-discovery (drop .template suffix) ([#94](https://github.com/rjskene/pipeline/issues/94)) ([e2e074b](https://github.com/rjskene/pipeline/commit/e2e074ba2338382da3012b68b058af7a178b6272))
* **release:** install release-please workflow + config (closes [#104](https://github.com/rjskene/pipeline/issues/104)) ([#106](https://github.com/rjskene/pipeline/issues/106)) ([1f5201b](https://github.com/rjskene/pipeline/commit/1f5201b92c309aa28324b4b6ab8290680638b17e))


### Bug Fixes

* **plugin:** drop hard superpowers dependency from plugin.json (closes [#102](https://github.com/rjskene/pipeline/issues/102)) ([#103](https://github.com/rjskene/pipeline/issues/103)) ([e15ca5b](https://github.com/rjskene/pipeline/commit/e15ca5b44e7a715e1b78949e38b7a918d2bb2734))
* **spawn-claude:** namespace slash invocation to /pipeline:${SKILL} (closes [#100](https://github.com/rjskene/pipeline/issues/100)) ([#101](https://github.com/rjskene/pipeline/issues/101)) ([563764d](https://github.com/rjskene/pipeline/commit/563764d825c81428e1ecff8600bec4f776df89e3))
* **tests:** remove broken test-path-c-args-directive.sh (closes [#88](https://github.com/rjskene/pipeline/issues/88)) ([#105](https://github.com/rjskene/pipeline/issues/105)) ([9827cb1](https://github.com/rjskene/pipeline/commit/9827cb1872914714471673c87295653f18268b1b))
